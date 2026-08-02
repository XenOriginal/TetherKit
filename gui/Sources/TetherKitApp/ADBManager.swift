import Foundation

/// ADB（Android Debug Bridge）设备检测与命令执行。
///
/// 职责：
///   1. 检测系统是否安装了 adb（启动时探测一次）；
///   2. 枚举当前通过 USB 连接的 Android 设备；
///   3. 对指定设备执行 ADB 命令（启用/禁用 RNDIS 网络功能）。
///
/// adb 必须在 PATH 中，或位于 Homebrew 的标准安装路径。
/// 命令执行有超时保护，防止设备无响应时永久阻塞。
@MainActor
final class ADBManager {

    // MARK: - 设备模型

    /// 检测到的 ADB 设备。
    struct ADBDevice: Identifiable, Equatable {
        /// ADB serial number —— USB 设备的稳定标识。
        var id: String { serial }
        let serial: String
        /// 设备状态："device"（已授权）、"offline"（离线）、"unauthorized"（未授权）。
        let state: String
        /// 设备产品名（如 "Pixel 7"），可能为空。
        var name: String

        /// 设备是否已授权且可用。
        var isReady: Bool { state == "device" }
    }

    // MARK: - ADB 路径探测

    /// adb 可执行文件的路径。首次探测后缓存。
    private static var cachedADBPath: String?

    /// 系统是否安装了 adb。
    static var isAvailable: Bool {
        findADBPath() != nil
    }

    /// 获取 adb 路径（带缓存）。
    static func findADBPath() -> String? {
        if let cached = cachedADBPath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let candidates = [
            "/opt/homebrew/bin/adb",       // Apple Silicon Homebrew
            "/usr/local/bin/adb",          // Intel Homebrew
            "/usr/bin/adb",                // 系统路径
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedADBPath = path
                return path
            }
        }
        // 回退到 which（慢，但覆盖自定义 PATH）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["adb"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0,
               let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
               let path = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                cachedADBPath = path
                return path
            }
        } catch {}
        return nil
    }

    // MARK: - 设备检测

    /// 枚举当前通过 USB 连接的 ADB 设备。
    ///
    /// 解析 `adb devices` 输出，格式：
    /// ```
    /// List of devices attached
    /// ABCD1234    device
    /// EFGH5678    unauthorized
    /// ```
    func detectDevices() async -> [ADBDevice] {
        guard let adbPath = Self.findADBPath() else { return [] }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: adbPath)
                task.arguments = ["devices"]
                task.standardOutput = Pipe()
                task.standardError = FileHandle.nullDevice

                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {
                    continuation.resume(returning: [])
                    return
                }

                guard task.terminationStatus == 0,
                      let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
                      let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: [])
                    return
                }

                continuation.resume(returning: Self.parseDevicesOutput(output))
            }
        }
    }

    /// 解析 `adb devices` 输出为设备列表。
    nonisolated static func parseDevicesOutput(_ output: String) -> [ADBDevice] {
        var devices: [ADBDevice] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") {
                continue
            }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            let serial = parts[0].trimmingCharacters(in: .whitespaces)
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !serial.isEmpty else { continue }

            devices.append(ADBDevice(serial: serial, state: state, name: ""))
        }

        return devices
    }

    // MARK: - 设备信息

    /// 获取设备的产品名（通过 `adb getprop`）。
    ///
    /// 3 秒硬超时：设备名获取是锦上添花，不该阻塞主流程。
    func fetchDeviceName(serial: String) async -> String {
        guard let adbPath = Self.findADBPath() else { return "" }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: adbPath)
                task.arguments = ["-s", serial, "shell", "getprop", "ro.product.model"]
                task.standardOutput = Pipe()
                task.standardError = FileHandle.nullDevice

                do {
                    try task.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }

                // 3 秒硬超时
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if task.isRunning { task.terminate() }
                }
                task.waitUntilExit()

                guard task.terminationStatus == 0,
                      let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
                      let name = String(data: data, encoding: .utf8)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: name)
            }
        }
    }

    // MARK: - RNDIS / MTP 模式切换

    /// 执行 `adb -s <serial> shell svc usb setFunctions <rndis|mtp>`。
    ///
    /// - Parameters:
    ///   - serial: 目标设备的 ADB serial number。
    ///   - enable: `true` → 切换到 RNDIS（开启网络）；`false` → 切换到 MTP（关闭网络）。
    /// - Throws: ADB 命令执行失败、超时或设备未授权时抛出错误。
    ///
    /// 超时保护：10 秒。通过 `task.terminate()` 杀掉进程，
    /// `terminationHandler` 中 `terminationReason == .uncaughtSignal` 判断超时，
    /// 确保 `continuation` 只被 resume 一次，避免双重 resume 崩溃。
    func setNetwork(serial: String, enable: Bool) async throws {
        guard let adbPath = Self.findADBPath() else { throw ADBError.adbNotFound }
        let functionArg = enable ? "rndis" : "mtp"

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adbPath)
            task.arguments = ["-s", serial, "shell", "svc", "usb", "setFunctions", functionArg]
            task.standardOutput = Pipe()
            task.standardError = Pipe()

            task.terminationHandler = { process in
                // task.terminate() 发送 SIGTERM → terminationReason == .uncaughtSignal → 超时
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ADBError.timeout)
                    return
                }
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = (process.standardError as? Pipe)?
                        .fileHandleForReading.readDataToEndOfFile() ?? Data()
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                    continuation.resume(throwing: ADBError.commandFailed(errMsg))
                }
            }

            do {
                try task.run()
                // 10 秒超时：直接杀进程，让 terminationHandler 处理
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if task.isRunning { task.terminate() }
                }
            } catch {
                continuation.resume(throwing: ADBError.launchFailed(error))
            }
        }
    }

    /// 启用设备的 RNDIS 网络功能。等价于 `setNetwork(serial:enable:true)`。
    func enableRNDIS(serial: String) async throws {
        try await setNetwork(serial: serial, enable: true)
    }

    /// 关闭设备的 RNDIS 网络功能，切换回 MTP。等价于 `setNetwork(serial:enable:false)`。
    func disableRNDIS(serial: String) async throws {
        try await setNetwork(serial: serial, enable: false)
    }

    // MARK: - 错误类型

    enum ADBError: LocalizedError {
        case adbNotFound
        case commandFailed(String)
        case timeout
        case launchFailed(Error)

        var errorDescription: String? {
            switch self {
            case .adbNotFound:
                return "adb not found. Please install Android Platform Tools."
            case .commandFailed(let msg):
                let detail = msg.isEmpty ? "unknown error (exit code non-zero)" : msg
                return "ADB command failed: \(detail)"
            case .timeout:
                return "ADB command timed out"
            case .launchFailed(let err):
                return "Failed to launch adb: \(err.localizedDescription)"
            }
        }
    }
}
