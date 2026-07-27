import SwiftUI
import TetherKitIPC

/// 设备选择与会话参数。
///
/// 会话跑起来之后整块变成只读 —— 改 MTU 或换设备都需要重连，做成「能改但不生效」
/// 比直接禁用更让人困惑。
struct DeviceCard: View {
    @Bindable var model: AppModel

    private var isLocked: Bool {
        model.status.runState == .running || model.status.runState.isTransitional
    }

    var body: some View {
        Card(title: "USB 设备",
             systemImage: "cable.connector",
             accessory: AnyView(refreshButton)) {
            if model.devices.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    devicePicker
                    Divider()
                    tuningControls
                }
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshDevices() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(isLocked)
        .help(isLocked ? "运行中无法刷新设备列表" : "重新扫描 USB 设备")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有检测到设备", systemImage: "cable.connector.slash")
        } description: {
            // 这三条正是 macOS 上 RNDIS 连不上的全部常见原因，按命中率排序。
            VStack(alignment: .leading, spacing: 4) {
                Text("① 用的是数据线，而不是只能供电的充电线")
                Text("② 手机上已打开「USB 网络共享 / USB tethering」")
                Text("③ 手机已解锁并信任本机")
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            ForEach(model.devices) { device in
                DeviceRow(device: device,
                          isSelected: (model.selectedDevice?.id == device.id),
                          isLocked: isLocked) {
                    model.selectedDeviceID = device.id
                }
            }
        }
    }

    // 长解释一律放进悬停提示：这两个参数一年也调不了一次，说明文字却天天占着
    // 屏幕 —— 界面上只留「什么时候需要动它」这一句。
    private var tuningControls: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Text("MTU")
                    .font(.callout)
                    .frame(width: 92, alignment: .leading)
                // 步进 100 而不是 1：MTU 是要和对端协商的，逐字节微调没有意义，
                // 而 1500 / 1400 / 2000 这样的整数才是用户真正会试的值。
                Stepper(value: $model.requestedMTU, in: 576...2048, step: 100) {
                    Text("\(String(model.requestedMTU)) 字节")
                        .font(.system(.callout, design: .monospaced))
                }
                .disabled(isLocked)
                Spacer()
            }
            Text("超出设备能力时会在协商阶段自动下调"
                 + (model.environment.map { "（本机上限 \($0.fethMaxMTU)）" } ?? "") + "。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("协商阶段以设备汇报的能力为准，填大了会自动下调。"
                      + "上限受系统的 net.link.fake.max_mtu 约束。")

            Toggle(isOn: $model.adoptDeviceMAC) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("采用设备汇报的 MAC 地址")
                    Text("只有排查 MAC 冲突时才需要关掉。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isLocked)
            .help("RNDIS 语义下设备就是这块网卡，对端的 ARP 表与 DHCP 租约都按设备的 MAC 建立。")
            .padding(.top, 2)
        }
    }
}

/// 设备列表里的一行。
private struct DeviceRow: View {
    let device: DeviceDescriptor
    let isSelected: Bool
    let isLocked: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    HStack(spacing: Design.Spacing.tight) {
                        Text(device.summary)
                            .font(.system(.caption, design: .monospaced))
                        if !device.serial.isEmpty {
                            Text("SN \(device.serial)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if device.usedAndroidQuirk {
                    // 这条信息对排障很有用：走了兜底路径说明设备的 CDC 描述符不
                    // 规范，日后若出问题这是第一个该看的线索。
                    StatusBadge(text: "兼容模式", color: .orange)
                        .help("该设备的 CDC 描述符不规范，已按 Android 的惯例推断接口编号")
                }
            }
            .padding(Design.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Design.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.control)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : .clear,
                                  lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }
}
