import SwiftUI
import TetherKitIPC

/// 自动连接设置卡片。
///
/// 展示 ADB 状态、已授权设备列表（每个设备一个 toggle 控制自动连接）、
/// 检测到的设备列表（可添加到白名单）。
struct AutoConnectCard: View {
    @Bindable var model: AppModel
    @State private var detectedDevices: [ADBManager.ADBDevice] = []
    @State private var isLoading = false

    var body: some View {
        Card(title: L(.autoConnect), systemImage: "bolt.autostartstop") {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                // ADB 状态行
                adbStatusRow

                Divider()

                // 已授权设备列表
                authorizedDevicesSection

                Divider()

                // 检测到的设备列表
                detectedDevicesSection

                // 刷新按钮
                HStack {
                    Button {
                        Task { await refreshDevices() }
                    } label: {
                        Label(L(.refreshDevices), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!ADBManager.isAvailable || isLoading)

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                // 自动连接状态
                let mgr = model.autoConnectManager
                if mgr.status != .idle && mgr.status != .monitoring {
                    Divider()
                    autoConnectStatusView(mgr.status)
                }
            }
        }
        .task {
            // 自动连接总开关常开：确保 model 引用已设置并启动监控
            model.autoConnectManager.model = model
            model.autoConnectManager.startMonitoring()
            if ADBManager.isAvailable {
                await refreshDevices()
            }
        }
    }

    // MARK: - ADB 状态

    private var adbStatusRow: some View {
        HStack(spacing: Design.Spacing.tight) {
            Circle()
                .fill(ADBManager.isAvailable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(ADBManager.isAvailable ? L(.adbAvailable) : L(.adbUnavailable))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !ADBManager.isAvailable {
                Text(L(.autoConnectNoADBHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 已授权设备

    private var authorizedDevicesSection: some View {
        let mgr = model.autoConnectManager
        let authorized = mgr.whitelist.authorizedSerials.sorted()

        return VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Text(L(.authorizedDevices))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if authorized.isEmpty {
                Text(L(.noDeviceDetected))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Design.Spacing.tight)
            } else {
                ForEach(authorized, id: \.self) { serial in
                    authorizedDeviceRow(serial)
                }
            }
        }
    }

    private func authorizedDeviceRow(_ serial: String) -> some View {
        let whitelist = model.autoConnectManager.whitelist

        return HStack(spacing: Design.Spacing.small) {
            // 自动连接 Toggle
            Toggle(isOn: Binding(
                get: { whitelist.isAutoConnectEnabled(serial: serial) },
                set: { newValue in
                    model.autoConnectManager.whitelist.setAutoConnect(serial: serial, enabled: newValue)
                    // 打开时立即触发自动连接流程（不用等 2 秒轮询）
                    if newValue {
                        Task {
                            await model.autoConnectManager.toggleNetworkAndConnect(serial: serial, enable: true)
                        }
                    }
                }
            )) {
                Text(L(.autoConnect))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(serial)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                model.autoConnectManager.removeFromWhitelist(serial: serial)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L(.removeDevice))
        }
    }

    // MARK: - 检测到的设备

    private var detectedDevicesSection: some View {
        let mgr = model.autoConnectManager

        return VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Text(L(.detectedDevices))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if detectedDevices.isEmpty {
                Text(L(.noDeviceDetected))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Design.Spacing.tight)
            } else {
                ForEach(detectedDevices) { device in
                    detectedDeviceRow(device, whitelist: mgr.whitelist)
                }
            }
        }
    }

    private func detectedDeviceRow(_ device: ADBManager.ADBDevice,
                                   whitelist: DeviceWhitelist) -> some View {
        let isAuthorized = whitelist.contains(serial: device.serial)

        return HStack(spacing: Design.Spacing.small) {
            // 状态圆点
            Circle()
                .fill(device.isReady ? Color.green : Color.orange)
                .frame(width: 5, height: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.serial)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(device.state)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isAuthorized {
                Text(L(.alreadyAdded))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if device.isReady {
                Button {
                    model.autoConnectManager.addToWhitelist(serial: device.serial)
                } label: {
                    Text(L(.addDevice))
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    // MARK: - 刷新设备

    private func refreshDevices() async {
        isLoading = true
        defer { isLoading = false }

        let mgr = model.autoConnectManager
        detectedDevices = await mgr.adbManager.detectDevices()
    }

    // MARK: - 自动连接状态

    private func autoConnectStatusView(_ status: AutoConnectManager.Status) -> some View {
        HStack(spacing: Design.Spacing.tight) {
            switch status {
            case .enablingRNDIS(let name):
                ProgressView().controlSize(.small)
                Text(L(.autoConnectEnabling, name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waitingForRNDIS(let name):
                ProgressView().controlSize(.small)
                Text(L(.autoConnectWaiting, name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connecting(let name):
                ProgressView().controlSize(.small)
                Text(L(.autoConnectConnecting, name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connected(let name):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L(.autoConnectConnected, name))
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let name, let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L(.autoConnectFailed, "\(name): \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            default:
                EmptyView()
            }
        }
    }
}
