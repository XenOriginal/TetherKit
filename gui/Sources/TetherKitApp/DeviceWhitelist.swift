import Foundation

/// 自动连接白名单：用户预先授权的设备集合。
///
/// 每个设备有独立的 autoConnectEnabled 开关：
///   - 已授权且 autoConnect=true → 插入时自动执行 RNDIS 切换 + connect
///   - 已授权且 autoConnect=false → 不自动执行，但可在 UI 手动操作
///
/// 通过 UserDefaults 持久化，重启不丢失。
struct DeviceWhitelist: Codable {

    /// 单个设备的授权信息。
    struct DeviceEntry: Codable, Equatable {
        let serial: String
        /// 是否启用自动连接（插入时自动切换 RNDIS + connect）。
        var autoConnectEnabled: Bool
    }

    /// 已授权设备列表。
    var entries: [DeviceEntry]

    /// 已授权设备的 serial number 集合（便捷访问）。
    var authorizedSerials: Set<String> {
        Set(entries.map(\.serial))
    }

    // MARK: - 查询

    /// 检查指定 serial 是否已授权。
    func contains(serial: String) -> Bool {
        entries.contains { $0.serial == serial }
    }

    /// 检查指定设备是否启用了自动连接。
    func isAutoConnectEnabled(serial: String) -> Bool {
        entries.first { $0.serial == serial }?.autoConnectEnabled ?? false
    }

    // MARK: - 修改

    /// 添加设备到白名单，默认启用自动连接。
    mutating func add(serial: String) {
        if !entries.contains(where: { $0.serial == serial }) {
            entries.append(DeviceEntry(serial: serial, autoConnectEnabled: true))
            save()
        }
    }

    /// 从白名单中移除设备。
    mutating func remove(serial: String) {
        entries.removeAll { $0.serial == serial }
        save()
    }

    /// 切换设备的自动连接开关。
    mutating func toggleAutoConnect(serial: String) {
        guard let index = entries.firstIndex(where: { $0.serial == serial }) else { return }
        entries[index].autoConnectEnabled.toggle()
        save()
    }

    /// 设置设备的自动连接状态。
    mutating func setAutoConnect(serial: String, enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.serial == serial }) else { return }
        entries[index].autoConnectEnabled = enabled
        save()
    }

    /// 切换设备的授权状态（有则移除，无则添加）。
    mutating func toggle(serial: String) {
        if contains(serial: serial) {
            remove(serial: serial)
        } else {
            add(serial: serial)
        }
    }

    // MARK: - 持久化

    private static let storageKey = "TetherKitAutoConnectWhitelist"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func load() -> DeviceWhitelist {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let whitelist = try? JSONDecoder().decode(DeviceWhitelist.self, from: data) else {
            return .empty
        }
        return whitelist
    }

    static let empty = DeviceWhitelist(entries: [])
}
