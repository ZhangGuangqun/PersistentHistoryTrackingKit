//
//  PersistentHistoryTrackingKit.swift
//
//
//  Created by Yang Xu on 2022/2/11
//  Copyright © 2022 Yang Xu. All rights reserved.
//
//  Follow me on Twitter: @fatbobman
//  My Blog: https://www.fatbobman.com
//  微信公共号: 肘子的Swift记事本
//

import CoreData
import Foundation
import AsyncAlgorithms

// swiftlint:disable line_length

public final class PersistentHistoryTrackingKit {
    /// 日志显示等级，从0-2级。0 关闭 2 最详尽
    public var logLevel: Int

    /// 清除策略
    var strategy: TransactionPurgePolicy

    /// 当前 transaction 的 author
    let currentAuthor: String

    /// 全部的 authors （包括app group当中所有使用同一数据库的成员以及用于批量操作的author）
    let allAuthors: [String]

    /// 是否合并由 NSPersistentCloudContainer 导入的网络数据
    /// 如果你直接在 NSPersistentCloudContainer 上使用 Persistent History Tracking ，可以直接使用默认值 false，此时，NSPersistentCloudContainer 将自动处理合并事宜
    /// 此选项通常用于 NSPersistentContainer 之上，将另一个 CloudContainer 导入的数据合并到当前的 container 的 viewContext 中。
    let includingCloudKitMirroring: Bool

    /// 用于批量操作的 authors
    ///
    /// 由于批量操作的 author 只会生成 transaction，并不会对其他 author 产生的 transaction 进行合并和清除。
    /// 仅此此类 auhtors 最好可以单独标注出来，这样其他的 authors 在清除时将不会为其保留不必要的 transaction。
    /// 即使不单独设置，当遗留的 transaction 满足 maximumDuration 后，仍会被自动清除。
    let batchAuthors: [String]

    /// 需要被合并的上下文，通常是视图上下文。可以有多个
    let contexts: [NSManagedObjectContext]

    /// transaction 最长可以保存的时间（秒）。如果在该时间内仍无法获取到全部的 author 更新时间戳，
    /// 将返回从当前时间减去该秒数的日期 Date().addingTimeInterval(-1 * abs(maximumDuration))
    let maximumDuration: TimeInterval

    /// 在 UserDefaults 中保存时间戳 Key 的前缀。
    let uniqueString: String

    /// 日志管理器
    let logger: PersistentHistoryTrackingKitLoggerProtocol

    /// 获取需要处理的 transaction
    let fetcher: Fetcher

    /// 合并transaction到指定的托管对象上下文中（contexts）
    let merger: Merger

    /// transaction清除器，清除可确认的已被所有authors合并的transaction
    let cleaner: Cleaner

    /// 时间戳管理器，过去并更新合并事件戳
    let timestampManager: TransactionTimestampManager

    /// 处理持久化历史跟踪事件的任务。可以通过start开启，stop停止。
    var transactionProcessingTasks = [Task<Void, Never>]()

    /// 持久化存储协调器，用于缩小通知返回
    private let coordinator: NSPersistentStoreCoordinator
    /// 专职处理transaction的托管对象上下文
    private let backgroundContext: NSManagedObjectContext
    
    /// 处理 persistent store 发生改变后，提供给外部的回调
    private let storeChangeCallback: (([NSPersistentHistoryTransaction], NSManagedObjectContext) -> Void)?

    /// 创建处理 Transaction 的任务。
    ///
    /// 通过将持久化历史跟踪记录的通知转换成异步序列，实现了逐个处理的机制。
    func createTransactionProcessingTask() -> Task<Void, Never> {
        Task {
            sendMessage(type: .info, level: 1, message: "Persistent History Track Kit Start")
            // 响应 notification
            let publisher = NotificationCenter.default.publisher(
                for: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
            for await _ in publisher.values.buffer(policy: .unbounded) where !Task.isCancelled {
                sendMessage(type: .info,
                            level: 2,
                            message: "Get a `NSPersistentStoreRemoteChange` notification")

                // fetch
                let transactions = fetchTransactions(
                    for: currentAuthor,
                    since: timestampManager,
                    by: fetcher,
                    logger: sendMessage
                )
                
                // callback
                if storeChangeCallback != nil {
                    storeChangeCallback!(transactions, self.backgroundContext)
                }

                // merge
                mergeTransactionsInContexts(
                    transactions: transactions,
                    by: merger,
                    timestampManager: timestampManager,
                    logger: sendMessage
                )

                // clean
                cleanTransactions(
                    beforeDate: timestampManager,
                    allAuthors: allAuthors,
                    batchAuthors: batchAuthors,
                    by: cleaner,
                    logger: sendMessage
                )
            }
            sendMessage(type: .info, level: 1, message: "Persistent History Track Kit Stop")
        }
    }

    /// get all new transactions since the last merge date
    func fetchTransactions(
        for currentAuthor: String,
        since lastTimestampManager: TransactionTimestampManagerProtocol,
        by fetcher: TransactionFetcherProtocol,
        logger: Logger?
    ) -> [NSPersistentHistoryTransaction] {
        let lastTimestamp = lastTimestampManager
            .getLastHistoryTransactionTimestamp(for: currentAuthor) ?? Date.distantPast
        logger?(.info, 2,
                "The last history transaction timestamp for \(allAuthors) is \(Self.dateFormatter.string(from: lastTimestamp))")
        var transactions = [NSPersistentHistoryTransaction]()
        do {
            transactions = try fetcher.fetchTransactions(from: lastTimestamp)
            let changesCount = transactions
                .map { $0.changes?.count ?? 0 }
                .reduce(0, +)
            let message = "There are \(transactions.count) transactions with \(changesCount) changes related to `\(currentAuthor)` in the query"
            logger?(.info, 2, message)
        } catch {
            logger?(.error, 1, "Fetch transaction error: \(error.localizedDescription)")
        }
        return transactions
    }

    /// merge transactions in contexts
    func mergeTransactionsInContexts(
        transactions: [NSPersistentHistoryTransaction],
        by merger: TransactionMergerProtocol,
        timestampManager: TransactionTimestampManagerProtocol,
        logger: Logger?
    ) {
        guard let lastTimestamp = transactions.last?.timestamp else { return }
        merger(merge: transactions, into: contexts)
        timestampManager.updateLastHistoryTransactionTimestamp(for: currentAuthor, to: lastTimestamp)
        let message = "merge \(transactions.count) transactions, update `\(currentAuthor)`'s timestamp to \(Self.dateFormatter.string(from: lastTimestamp))"
        logger?(.info, 2, message)
    }

    /// clean up all transactions that has been merged by all contexts
    func cleanTransactions(
        beforeDate timestampManager: TransactionTimestampManagerProtocol,
        allAuthors: [String],
        batchAuthors: [String],
        by cleaner: TransactionCleanerProtocol,
        logger: Logger?
    ) {
        guard strategy.allowedToClean() else { return }
        let cleanTimestamp = timestampManager.getLastCommonTransactionTimestamp(in: allAuthors, exclude: batchAuthors)
        do {
            try cleaner.cleanTransaction(before: cleanTimestamp)
            logger?(.info, 2, "Delete transaction success")
        } catch {
            logger?(.error, 1, "Delete transaction error: \(error.localizedDescription)")
        }
    }

    typealias Logger = (PersistentHistoryTrackingKitLogType, Int, String) -> Void

    /// 发送日志
    func sendMessage(type: PersistentHistoryTrackingKitLogType, level: Int, message: String) {
        guard level <= logLevel else { return }
        logger.log(type: type, message: message)
    }

    init(logLevel: Int,
         strategy: TransactionCleanStrategy,
         currentAuthor: String,
         allAuthors: [String],
         includingCloudKitMirroring: Bool,
         batchAuthors: [String],
         viewContext: NSManagedObjectContext,
         contexts: [NSManagedObjectContext],
         userDefaults: UserDefaults,
         maximumDuration: TimeInterval,
         uniqueString: String,
         logger: PersistentHistoryTrackingKitLoggerProtocol,
         autoStart: Bool,
         storeChangeCallback: (([NSPersistentHistoryTransaction], NSManagedObjectContext) -> Void)?
    ) {
        self.logLevel = logLevel
        self.currentAuthor = currentAuthor
        self.allAuthors = allAuthors
        self.includingCloudKitMirroring = includingCloudKitMirroring
        self.batchAuthors = batchAuthors
        self.contexts = contexts
        self.maximumDuration = maximumDuration
        self.uniqueString = uniqueString
        self.logger = logger
        self.storeChangeCallback = storeChangeCallback

        // 检查 viewContext 是否为视图上下文
        guard viewContext.concurrencyType == .mainQueueConcurrencyType else {
            fatalError("`viewContext` must be a view context ( concurrencyType == .mainQueueConcurrencyType)")
        }

        guard let coordinator = viewContext.persistentStoreCoordinator else {
            fatalError("`viewContext` must have a persistentStoreCoordinator available")
        }

        let backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundContext.persistentStoreCoordinator = coordinator

        switch strategy {
        case .none:
            self.strategy = TransactionCleanStrategyNone()
        case .byDuration:
            self.strategy = TransactionCleanStrategyByDuration(strategy: strategy)
        case .byNotification:
            self.strategy = TransactionCleanStrategyByNotification(strategy: strategy)
        }

        self.fetcher = Fetcher(
            backgroundContext: backgroundContext,
            currentAuthor: currentAuthor,
            allAuthors: allAuthors,
            includingCloudKitMirroring: includingCloudKitMirroring
        )

        self.merger = Merger()
        self.cleaner = Cleaner(backgroundContext: backgroundContext, authors: allAuthors)
        self.timestampManager = TransactionTimestampManager(userDefaults: userDefaults, maximumDuration: maximumDuration, uniqueString: uniqueString)
        self.coordinator = coordinator
        self.backgroundContext = backgroundContext

        if autoStart {
            start()
        }
    }

    deinit {
        stop()
    }
}

public extension PersistentHistoryTrackingKit {
    /// 启动处理任务
    func start() {
        guard transactionProcessingTasks.isEmpty else {
            return
        }
        transactionProcessingTasks.append(createTransactionProcessingTask())
    }

    /// 停止处理任务
    func stop() {
        transactionProcessingTasks.forEach {
            $0.cancel()
        }
        transactionProcessingTasks.removeAll()
    }
}

extension PersistentHistoryTrackingKit {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

public extension PersistentHistoryTrackingKit {
    /// 创建一个可独立运行的 transaction 清除器
    ///
    /// 通常使用该清除器时，cleanStrategy 应设置为 .none
    /// 在 PersistentHistoryTrackKit 中使用 cleanerBuilder() 来生成该实例。该清理器的配置继承于 Kit 实例
    ///
    ///     let kit = PersistentHistoryTrackKit(.....)
    ///     let cleaner = kit().cleanerBuilder
    ///
    ///     cleaner() //在需要执行清理的地方运行
    ///
    /// 比如每次app进入后台时，执行清理任务。
    func cleanerBuilder() -> PersistentHistoryTrackingKitManualCleaner {
        PersistentHistoryTrackingKitManualCleaner(
            clear: cleaner,
            timestampManager: timestampManager,
            logger: logger,
            logLevel: logLevel,
            authors: allAuthors
        )
    }
}

public extension PersistentHistoryTrackingKit {
    /// 使用viewContext的初始化器
    convenience init(viewContext: NSManagedObjectContext,
                     contexts: [NSManagedObjectContext]? = nil,
                     currentAuthor: String,
                     allAuthors: [String],
                     includingCloudKitMirroring: Bool = false,
                     batchAuthors: [String] = [],
                     userDefaults: UserDefaults,
                     cleanStrategy: TransactionCleanStrategy = .byNotification(times: 1),
                     maximumDuration: TimeInterval = 60 * 60 * 24 * 7,
                     uniqueString: String = "PersistentHistoryTrackingKit.lastToken.",
                     logger: PersistentHistoryTrackingKitLoggerProtocol? = nil,
                     logLevel: Int = 1,
                     autoStart: Bool = true,
                     storeChangeCallback: (([NSPersistentHistoryTransaction], NSManagedObjectContext) -> Void)? = nil) {
        let contexts = contexts ?? [viewContext]
        let logger = logger ?? DefaultLogger()
        self.init(logLevel: logLevel,
                  strategy: cleanStrategy,
                  currentAuthor: currentAuthor,
                  allAuthors: allAuthors,
                  includingCloudKitMirroring: includingCloudKitMirroring,
                  batchAuthors: batchAuthors,
                  viewContext: viewContext,
                  contexts: contexts,
                  userDefaults: userDefaults,
                  maximumDuration: maximumDuration,
                  uniqueString: uniqueString,
                  logger: logger,
                  autoStart: autoStart,
                  storeChangeCallback: storeChangeCallback)
    }

    /// 使用NSPersistentContainer的初始化器
    convenience init(container: NSPersistentContainer,
                     contexts: [NSManagedObjectContext]? = nil,
                     currentAuthor: String,
                     allAuthors: [String],
                     includingCloudKitMirroring: Bool = false,
                     batchAuthors: [String] = [],
                     userDefaults: UserDefaults,
                     cleanStrategy: TransactionCleanStrategy = .byNotification(times: 1),
                     maximumDuration: TimeInterval = 60 * 60 * 24 * 7,
                     uniqueString: String = "PersistentHistoryTrackingKit.lastToken.",
                     logger: PersistentHistoryTrackingKitLoggerProtocol? = nil,
                     logLevel: Int = 1,
                     autoStart: Bool = true,
                     storeChangeCallback: (([NSPersistentHistoryTransaction], NSManagedObjectContext) -> Void)? = nil){
        let viewContext = container.viewContext
        let contexts = contexts ?? [viewContext]
        let logger = logger ?? DefaultLogger()
        self.init(logLevel: logLevel,
                  strategy: cleanStrategy,
                  currentAuthor: currentAuthor,
                  allAuthors: allAuthors,
                  includingCloudKitMirroring: includingCloudKitMirroring,
                  batchAuthors: batchAuthors,
                  viewContext: viewContext,
                  contexts: contexts,
                  userDefaults: userDefaults,
                  maximumDuration: maximumDuration,
                  uniqueString: uniqueString,
                  logger: logger,
                  autoStart: autoStart,
                  storeChangeCallback: storeChangeCallback)
    }
}

extension Notification:@unchecked Sendable {}
