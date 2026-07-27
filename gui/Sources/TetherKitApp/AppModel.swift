import Foundation
import Observation
import SwiftUI
import TetherKitCore
import TetherKitIPC

/// 一次采样得到的瞬时速率。
struct ThroughputSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let receiveBitsPerSecond: Double
    let transmitBitsPerSecond: Double
    let receivePacketsPerSecond: Double
    let transmitPacketsPerSecond: Double

    static let zero = ThroughputSample(timestamp: .distantPast, receiveBitsPerSecond: 0,
                                       transmitBitsPerSecond: 0, receivePacketsPerSecond: 0,
                                       transmitPacketsPerSecond: 0)
}

/// helper 的可达性。界面靠它决定是「显示安装引导」还是「正常工作」。
enum HelperAvailability: Equatable {
    case unknown
    case available(version: String)
    case missing(reason: String)
}

/// 界面的全部状态与动作。
///
/// ★ 为什么所有事都经过 helper，而不是 App 自己调库 ★
///   App 以普通用户身份运行，建 feth 和开 BPF 都要 root，所以会话只能在 helper
///   里跑。设备枚举与环境预检虽然不需要 root，但也统一走 helper —— 会话跑起来后
///   设备已被 helper 独占，App 再去读只会得到不一致的结果。
@Observable
@MainActor
final class AppModel {
    // MARK: - 对界面公开的状态

    private(set) var helperAvailability: HelperAvailability = .unknown
    private(set) var environment: EnvironmentReport?
    private(set) var devices: [DeviceDescriptor] = []
    private(set) var status: SessionStatus = .idle
    private(set) var networkState: NetworkState = .empty
    private(set) var throughput: ThroughputSample = .zero
    private(set) var throughputHistory: [ThroughputSample] = []
    private(set) var logs: [LogEntry] = []
    private(set) var droppedLogCount: UInt64 = 0

    /// 用户在设备列表里选中的那台。为 nil 表示「用找到的第一台」。
    var selectedDeviceID: String?
    /// 会话配置里用户可调的部分。
    var requestedMTU: UInt32 = 1500
    var adoptDeviceMAC: Bool = true
    /// 网络配置表单。
    var networkConfiguration: NetworkConfiguration = .dhcp

    /// 正在等待某个特权操作完成 —— 界面据此禁用按钮并显示进度。
    private(set) var isBusy: Bool = false
    /// 需要弹给用户看的错误。
    var alertMessage: String?

    var logLevelFilter: LogLevel = .info

    // MARK: - 内部

    private let client = HelperClient()
    private var pollingTask: Task<Void, Never>?
    /// 上一次的状态快照，用来做差算速率。
    private var previousStatus: SessionStatus?
    private var sessionStartedAt: Date?

    /// 轮询周期。
    ///
    /// 500 ms 是「看起来实时」与「别把 XPC 往返变成负担」的平衡点：更快对人眼
    /// 已无区别，更慢会让速率曲线看起来一顿一顿的。
    private static let pollInterval: Duration = .milliseconds(500)

    /// 吞吐曲线保留的采样点数。120 点 × 500 ms = 最近 60 秒。
    private static let historyCapacity = 120

    /// 日志面板保留的行数。
    ///
    /// 2000 行足够回溯一整次启动序列加若干分钟运行；再多 SwiftUI 的列表会开始卡。
    private static let logCapacity = 2000

    // MARK: - 生命周期

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - 轮询

    private func refresh() async {
        do {
            let version = try await client.helperVersion()
            helperAvailability = .available(version: version)
        } catch {
            helperAvailability = .missing(reason: error.localizedDescription)
            // 连不上就别再发后续请求了 —— 每一个都会重复同样的失败，
            // 只会把日志刷满。
            return
        }

        if environment == nil {
            environment = try? await client.environment()
        }

        if let fresh = try? await client.sessionStatus() {
            apply(status: fresh)
        }
        if let feed = try? await client.drainFeed() {
            apply(feed: feed)
        }

        // 设备列表只在没跑起来的时候刷：运行中设备已被独占，列表也不该变。
        if status.runState != .running, let fresh = try? await client.listDevices() {
            devices = fresh
            // 用户选中的设备被拔掉后，选择要跟着失效，否则「启动」会按一个
            // 不存在的总线地址去找设备。
            if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
                selectedDeviceID = nil
            }
        }

        if !status.systemInterface.isEmpty {
            networkState = (try? await client.queryNetwork(interface: status.systemInterface))
                ?? .empty
        } else {
            networkState = .empty
        }
    }


    private func apply(status fresh: SessionStatus) {
        defer {
            previousStatus = fresh
            status = fresh
        }

        // 记录/清除连接时刻，用于显示已连接时长。
        if fresh.runState == .running, sessionStartedAt == nil {
            sessionStartedAt = Date()
        } else if fresh.runState != .running, fresh.runState != .stopping {
            sessionStartedAt = nil
        }

        guard let previous = previousStatus,
              fresh.runState == .running,
              fresh.monotonicNanos > previous.monotonicNanos else {
            if fresh.runState != .running {
                throughput = .zero
            }
            return
        }

        // 分母用库那边的单调时钟差，而不是我们的轮询周期 —— 两次拉取之间的
        // 真实间隔会被调度拉长，用固定周期当分母会把速率算高。
        let seconds = Double(fresh.monotonicNanos - previous.monotonicNanos) / 1_000_000_000
        guard seconds > 0 else { return }

        let sample = ThroughputSample(
            timestamp: Date(),
            receiveBitsPerSecond: Double(fresh.rxBytes &- previous.rxBytes) * 8 / seconds,
            transmitBitsPerSecond: Double(fresh.txBytes &- previous.txBytes) * 8 / seconds,
            receivePacketsPerSecond: Double(fresh.rxFrames &- previous.rxFrames) / seconds,
            transmitPacketsPerSecond: Double(fresh.txFrames &- previous.txFrames) / seconds)

        throughput = sample
        throughputHistory.append(sample)
        if throughputHistory.count > Self.historyCapacity {
            throughputHistory.removeFirst(throughputHistory.count - Self.historyCapacity)
        }
    }

    private func apply(feed: HelperFeed) {
        if !feed.logs.isEmpty {
            logs.append(contentsOf: feed.logs)
            if logs.count > Self.logCapacity {
                logs.removeFirst(logs.count - Self.logCapacity)
            }
        }
        droppedLogCount += feed.droppedLogs
    }

    // MARK: - 动作

    /// 已连接时长；未连接时为 nil。
    var connectedDuration: TimeInterval? {
        sessionStartedAt.map { Date().timeIntervalSince($0) }
    }

    var selectedDevice: DeviceDescriptor? {
        if let selectedDeviceID {
            return devices.first { $0.id == selectedDeviceID }
        }
        return devices.first
    }

    var filteredLogs: [LogEntry] {
        logs.filter { $0.level >= logLevelFilter }
    }

    /// 启动会话。会弹一次系统授权框。
    func startSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // 每次特权操作都单独取一次凭据。不缓存是刻意的：缓存等于在 App 进程里
        // 留一张长期有效的通行证，而重新弹框的代价只是一次 Touch ID。
        guard let authorization = await requestAuthorization() else { return }

        var configuration = SessionConfiguration(mtu: requestedMTU,
                                                 adoptDeviceMAC: adoptDeviceMAC)
        // 指定总线 + 地址而不是 VID/PID：同型号两台设备 VID/PID 完全一样，
        // 只有总线地址能区分。
        if let device = selectedDevice {
            configuration.busNumber = device.busNumber
            configuration.deviceAddress = device.deviceAddress
        }

        do {
            throughputHistory.removeAll()
            try await client.startSession(authorization: authorization,
                                          configuration: configuration)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 停止会话。
    func stopSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard let authorization = await requestAuthorization() else { return }
        do {
            try await client.stopSession(authorization: authorization)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 下发网络配置。
    func applyNetworkConfiguration() async {
        guard !isBusy else { return }
        let interface = status.systemInterface
        guard !interface.isEmpty else {
            alertMessage = "虚拟网卡还没创建，请先连接设备"
            return
        }
        if let message = NetworkValidator.validationMessage(for: networkConfiguration) {
            alertMessage = message
            return
        }

        isBusy = true
        defer { isBusy = false }

        guard let authorization = await requestAuthorization() else { return }
        do {
            try await client.applyNetwork(authorization: authorization, interface: interface,
                                          configuration: networkConfiguration)
            // 立刻回读一次，让界面马上反映真实生效的地址，而不用等下一个轮询周期。
            networkState = (try? await client.queryNetwork(interface: interface)) ?? .empty
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 手动刷新设备列表。
    func refreshDevices() async {
        devices = (try? await client.listDevices()) ?? []
    }

    func clearLogs() {
        logs.removeAll()
        droppedLogCount = 0
    }

    /// 弹系统授权框。用户取消时返回 nil，且**不**当作错误弹提示 ——
    /// 取消是正常操作，再弹一个「已取消」的框只会烦人。
    private func requestAuthorization() async -> Data? {
        do {
            return try AuthorizationBroker.requestAuthorization()
        } catch AuthorizationBroker.Failure.userCancelled {
            return nil
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }
}
