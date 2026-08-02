import Foundation
import TetherKitIPC

/// 自动连接编排器。
///
/// 双轮询机制：
///   1. 轮询 ADB 设备（adb devices）→ 发现白名单设备时执行 RNDIS 切换
///   2. 轮询 RNDIS 设备（probeDevices）→ 发现时自动连接
///
/// 完整流程：插入设备 → ADB 检测 → 切换 RNDIS → macOS 检测 RNDIS → 自动 connect
///
/// 每个白名单设备有独立的 autoConnectEnabled 开关：
///   - ON：插入时自动执行完整流程
///   - OFF：不自动执行，但可手动操作
@MainActor
final class AutoConnectManager {

    // MARK: - 公开状态

    /// 自动连接的当前状态。
    enum Status: Equatable {
        case idle
        case monitoring
        /// 正在启用 RNDIS。
        case enablingRNDIS(deviceName: String)
        /// 等待 RNDIS 设备出现在 macOS。
        case waitingForRNDIS(deviceName: String)
        /// 正在启动会话。
        case connecting(deviceName: String)
        /// 自动连接成功完成。
        case connected(deviceName: String)
        /// 自动连接失败。
        case failed(deviceName: String, reason: String)
    }

    /// 当前状态。
    private(set) var status: Status = .idle

    /// 自动连接日志（最近 50 条，带时间戳）。
    private(set) var logMessages: [String] = []

    /// 最近一条日志（便捷访问）。
    var recentLog: String { logMessages.last ?? "" }

    // MARK: - 内部状态

    /// 对 AppModel 的弱引用，用于调用 startSession 等方法。
    weak var model: AppModel?

    let adbManager = ADBManager()
    var whitelist = DeviceWhitelist.load()

    /// 监控任务。
    private var monitorTask: Task<Void, Never>?
    /// 是否正在执行自动连接流程（防止并发）。
    private var isConnecting = false
    /// 上一轮检测到的 ADB 设备 serial 列表。
    private var previousADBSnapshots: Set<String> = []
    /// 上一轮检测到的 RNDIS 设备 id 列表。
    private var previousRNDISSnapshots: Set<String> = []

    /// 轮询间隔。
    private static let pollInterval: Duration = .seconds(2)

    /// 日志时间戳格式。
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - 公开方法

    /// 启动周期性设备检测（ADB + RNDIS 双轮询）。
    func startMonitoring() {
        guard monitorTask == nil else { return }
        status = .monitoring
        previousADBSnapshots = []
        previousRNDISSnapshots = []
        log("=== Monitoring started ===")

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// 停止监控。
    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        status = .idle
        log("=== Monitoring stopped ===")
    }

    /// 手动对指定设备执行 RNDIS/MTP 切换（仅执行 ADB 命令）。
    func toggleNetwork(serial: String, enable: Bool) async throws {
        try await adbManager.setNetwork(serial: serial, enable: enable)
    }

    /// ON 按钮：切换到 RNDIS 并强制触发连接。
    ///
    /// ADB 命令失败不阻断（设备可能已处于 RNDIS 模式），
    /// 仍然强制触发连接流程。
    func toggleNetworkAndConnect(serial: String, enable: Bool) async {
        do {
            try await adbManager.setNetwork(serial: serial, enable: enable)
        } catch {
            log("ADB command error (continuing anyway): \(error.localizedDescription)")
        }
        if enable {
            isConnecting = true
            let device = ADBManager.ADBDevice(serial: serial, state: "device", name: "")
            await executeAutoConnect(for: device)
        }
    }

    /// 手动添加设备到白名单。
    func addToWhitelist(serial: String) {
        whitelist.add(serial: serial)
    }

    /// 从白名单中移除设备。
    func removeFromWhitelist(serial: String) {
        whitelist.remove(serial: serial)
    }

    /// 检查设备是否在白名单中。
    func isWhitelisted(serial: String) -> Bool {
        whitelist.contains(serial: serial)
    }

    // MARK: - 核心流程

    /// 双轮询：检测 ADB 设备和 RNDIS 设备。
    ///
    /// 1. 检查 RNDIS 设备 → 发现新设备则直接连接
    /// 2. 检查 ADB 设备 → 发现白名单中 autoConnect=true 的新设备则执行 RNDIS 切换
    private func poll() async {
        // --- Guard 1: isConnecting ---
        guard !isConnecting else {
            return
        }

        // --- Guard 2: model 可用性 ---
        guard let model else {
            log("Poll: model is nil, skipping")
            return
        }

        // --- Guard 3: 会话状态 ---
        let runState = model.status.runState
        if runState == .running {
            log("Poll: session already running (runState=.running), skipping")
            return
        }
        if runState == .starting || runState == .stopping {
            log("Poll: session transitional (runState=\(runState)), skipping")
            return
        }

        // --- 轮询 RNDIS 设备 ---
        let rndisDevices = await model.probeDevices()
        let currentRNDISSnapshots = Set(rndisDevices.map(\.id))
        let isFirstRNDISScan = previousRNDISSnapshots.isEmpty
        let newRNDISDevices = rndisDevices.filter { device in
            isFirstRNDISScan || !previousRNDISSnapshots.contains(device.id)
        }
        previousRNDISSnapshots = currentRNDISSnapshots

        if let target = newRNDISDevices.first {
            log("RNDIS detected: \(target.id), connecting...")
            isConnecting = true
            Task { await connectToDevice(target) }
            return
        }

        // --- 轮询 ADB 设备 ---
        let adbDevices = await adbManager.detectDevices()
        let currentADBSnapshots = Set(adbDevices.map(\.serial))
        let isFirstADBScan = previousADBSnapshots.isEmpty

        let whitelistedSerials = adbDevices
            .filter { whitelist.contains(serial: $0.serial) }
            .map(\.serial)

        let newADBDevices = adbDevices.filter { device in
            device.isReady
                && whitelist.contains(serial: device.serial)
                && whitelist.isAutoConnectEnabled(serial: device.serial)
                && (isFirstADBScan || !previousADBSnapshots.contains(device.serial))
        }
        previousADBSnapshots = currentADBSnapshots

        log("Poll: ADB=\(adbDevices.map(\.serial)) | whitelisted=\(whitelistedSerials) | newAuto=\(newADBDevices.map(\.serial))")

        if let target = newADBDevices.first {
            log("Triggering auto-connect for \(target.serial)...")
            isConnecting = true
            Task { await executeAutoConnect(for: target) }
        }
    }

    /// 对指定 ADB 设备执行完整的自动连接序列。
    ///
    /// isConnecting 已由调用方（poll 或 toggleNetworkAndConnect）设置。
    private func executeAutoConnect(for device: ADBManager.ADBDevice) async {
        defer { isConnecting = false }

        log("executeAutoConnect started for \(device.serial)")

        let serial = device.serial
        var resolvedName = device.name.isEmpty ? device.serial : device.name

        // Step 0: 获取设备名
        if device.name.isEmpty {
            resolvedName = await adbManager.fetchDeviceName(serial: serial)
            if resolvedName.isEmpty { resolvedName = serial }
        }

        // Step 1: 尝试启用 RNDIS（失败不阻断：设备可能已处于 RNDIS 模式）
        log("Step 1: Enabling RNDIS on \(resolvedName)...")
        status = .enablingRNDIS(deviceName: resolvedName)
        do {
            try await adbManager.setNetwork(serial: serial, enable: true)
            log("RNDIS enabled successfully")
        } catch {
            log("RNDIS enable error (may already be active): \(error.localizedDescription)")
        }

        // Step 2: 等待 RNDIS 设备出现在 macOS
        log("Step 2: Waiting for RNDIS device...")
        status = .waitingForRNDIS(deviceName: resolvedName)
        let rndisDevice = await waitForRNDISDevice()
        guard let rndisDevice else {
            log("RNDIS device not found within timeout")
            status = .failed(deviceName: resolvedName, reason: "RNDIS device not detected")
            return
        }

        // Step 3: 启动 TetherKit 会话
        log("Step 3: Connecting to \(rndisDevice.id)...")
        await connectToDevice(rndisDevice)
    }

    /// 连接到指定的 RNDIS 设备。
    ///
    /// 由 poll() 或 executeAutoConnect() 调用时，isConnecting 已由调用方设置。
    private func connectToDevice(_ device: DeviceDescriptor) async {
        defer { isConnecting = false }

        let deviceName = device.product.isEmpty ? device.id : device.product

        guard let model else {
            status = .failed(deviceName: deviceName, reason: "Model not available")
            return
        }

        // 如果会话已在运行或正在启动，跳过（避免 "A session is already running" 弹窗）
        // RNDIS 驱动可能在 probeDevices 检测到设备时已自动启动会话
        if model.status.runState == .running || model.status.runState == .starting {
            log("Session already active for \(deviceName), skipping startSession")
            status = .connected(deviceName: deviceName)
            return
        }

        log("Starting session for \(deviceName)...")
        status = .connecting(deviceName: deviceName)

        model.selectedDeviceID = device.id
        await model.startSession()

        // startSession() 通过 IPC 发送请求后立即返回，
        // 但辅助进程（rndis-ctl）需要时间初始化（通常 5-8 秒）。
        // 轮询等待 runState 变化，最多 10 秒。
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let rs = model.status.runState
            if rs == .running || rs == .starting {
                log("Connected to \(deviceName)")
                status = .connected(deviceName: deviceName)
                return
            }
            if rs == .failed {
                // 会话失败，不设 .failed 状态（轮询会重试），
                // 只记录日志并等待辅助进程可能的后续初始化
                log("Session start reported failure, waiting for recovery...")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // 超时：检查最终状态
        let finalState = model.status.runState
        if finalState == .running || finalState == .starting {
            log("Connected to \(deviceName)")
            status = .connected(deviceName: deviceName)
        } else {
            // 超时失败，不设 .failed 状态（避免 UI 警告），轮询会重试
            log("Session start timed out for \(deviceName), will retry")
        }
    }

    /// 等待 RNDIS 设备出现（轮询 helper.listDevices）。
    private func waitForRNDISDevice() async -> DeviceDescriptor? {
        guard let model else { return nil }

        let deadline = ContinuousClock.now + .seconds(10)
        var attempts = 0
        while ContinuousClock.now < deadline {
            attempts += 1
            let devices = await model.probeDevices()
            if let first = devices.first {
                log("RNDIS device found: \(first.id)")
                return first
            }
            try? await Task.sleep(for: .seconds(1))
        }
        log("waitForRNDIS: timed out after \(attempts) attempts")
        return nil
    }

    // MARK: - 日志

    private func log(_ message: String) {
        let ts = Self.timestampFormatter.string(from: Date())
        let entry = "[\(ts)] \(message)"
        logMessages.append(entry)
        if logMessages.count > 50 { logMessages.removeFirst() }
        // 同时注入到主日志面板
        model?.injectLog("[AutoConnect] \(message)")
    }
}
