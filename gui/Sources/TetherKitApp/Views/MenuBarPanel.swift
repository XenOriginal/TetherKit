import AppKit
import SwiftUI
import TetherKitIPC

/// 菜单栏里的常驻标签：状态图标 + 实时速率（单行、零抖动、可隐藏）。
///
/// 关键设计决策：macOS 给 MenuBarExtra label 的水平空间有限，SwiftUI 的
/// frame(width:) 约束会被系统裁剪（右侧内容直接消失）。所以这里**不用 frame
/// 定宽**，而是把速率格式化成**固定字符数的字符串**，配合 .monospacedDigit()
/// 让每个值占据完全相同的像素宽度。单个 Text 渲染，不存在嵌套 HStack 被裁的
/// 风险。
///
/// 用户可在菜单栏面板中切换是否显示速率（showSpeedInMenuBar）。
struct MenuBarLabel: View {
    var model: AppModel
    @AppStorage("TetherKitShowMenuBarSpeed") private var showSpeed = true

    /// compactBitrate 最宽输出为 "999.9G"（7 字符），加箭头 "↓" 共 8 字符。
    /// 每个字段统一填充到 8 字符，短值右侧补空格 —— 配合 monospacedDigit，
    /// "↓0K    " 与 "↓999.9G" 的像素宽度完全一致。
    private static let kFieldWidth = 8

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: Design.statusSymbol(for: model.status))
            if showSpeed && model.status.runState == .running {
                Text(speedText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .fixedSize()
            }
        }
    }

    private var speedText: String {
        pad("↓", model.throughput.receiveBitsPerSecond)
          + " "
          + pad("↑", model.throughput.transmitBitsPerSecond)
    }

    /// 把 "箭头+速率" 填充到固定字符数，短值右侧补空格。
    private func pad(_ arrow: String, _ bps: Double) -> String {
        let raw = "\(arrow)\(Format.compactBitrate(bps))"
        return raw.padding(toLength: Self.kFieldWidth, withPad: " ", startingAt: 0)
    }
}

/// 点开菜单栏项后的小面板。
///
/// 内容按「瞟一眼要知道什么」取舍：状态、速率、网卡与地址，再加两个动作
/// （打开主窗口、退出）。配置、图表、日志一律留在主窗口 —— 面板不是第二个界面。
struct MenuBarPanel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var status: SessionStatus { model.status }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            header

            switch status.runState {
            case .running:
                runningDetails
            case .failed:
                if !status.fatalMessage.isEmpty {
                    Text(status.fatalMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                idleHint
            }

            Divider()
            actions
        }
        .padding(Design.Spacing.medium)
        .frame(width: 280)
        // 与主窗口同理：文案来自全局查表，改语言不会让任何 @Observable 属性
        // 「看起来」变了，得靠显式 identity 强制重建。面板本身会随轮询刷新，
        // 不加这行语言也会在下一个周期跟上 —— 但从面板里改语言时，用户盯着
        // 的就是这块面板，慢半拍会被当成没生效。
        .id(model.languageRevision)
    }

    private var header: some View {
        HStack(spacing: Design.Spacing.tight) {
            Circle()
                .fill(Design.accent(for: status.runState))
                .frame(width: 8, height: 8)
            Text(Design.statusLabel(for: status))
                .font(.headline)
            Spacer()
            if let duration = model.connectedDuration {
                Text(Format.duration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var runningDetails: some View {
        speedRow(symbol: "arrow.down", caption: L(.downstreamShort),
                 bitsPerSecond: model.throughput.receiveBitsPerSecond, tint: .blue)
        speedRow(symbol: "arrow.up", caption: L(.upstreamShort),
                 bitsPerSecond: model.throughput.transmitBitsPerSecond, tint: .purple)

        if !status.systemInterface.isEmpty {
            Divider()

            // IPv4 生效信息
            effectiveInfoSection(
                header: L(.currentlyEffective),
                tint: .blue,
                rows: networkInfoRowsIPv4
            )

            // IPv6 生效信息
            if model.networkStateV6.hasAddress {
                Divider()
                effectiveInfoSection(
                    header: L(.ipv6CurrentlyEffective),
                    tint: .teal,
                    rows: networkInfoRowsV6
                )
            }
        }
    }

    // MARK: - 网络信息辅助

    /// IPv4 当前生效信息的键值对列表。
    private var networkInfoRowsIPv4: [(String, String)] {
        let s = model.networkState
        guard s.hasAddress else { return [] }
        return [
            (L(.ipAddress), s.address),
            (L(.netmask), s.netmask),
            (L(.router), s.router),
            ("DNS", s.dnsServers.isEmpty ? L(.notEffective) : s.dnsServers.joined(separator: L(.listSeparator)))
        ]
    }

    /// IPv6 当前生效信息的键值对列表。
    private var networkInfoRowsV6: [(String, String)] {
        let s = model.networkStateV6
        guard s.hasAddress else { return [] }
        return [
            (L(.ipv6Address), "\(s.address)/\(s.prefixLength)"),
            (L(.router), s.router.isEmpty ? "—" : s.router),
            ("DNS", s.dnsServers.isEmpty ? L(.notEffective) : s.dnsServers.joined(separator: L(.listSeparator)))
        ]
    }

    /// 一段紧凑的网络信息区块：彩色圆点标题 + 两列键值网格。
    private func effectiveInfoSection(header: String, tint: Color,
                                      rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack(spacing: Design.Spacing.tight) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(header).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading,
                 horizontalSpacing: Design.Spacing.medium,
                 verticalSpacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        infoCell(label: row.0, value: row.1)
                        if index + 1 < rows.count {
                            infoCell(label: rows[index + 1].0, value: rows[index + 1].1)
                        } else {
                            Color.clear
                        }
                    }
                    // 每次跳两条（两列一行）
                    if index + 1 < rows.count { }
                }
            }
        }
    }

    /// 单个信息格：标签 + 等宽值，超长截断，悬停看全。
    private func infoCell(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.tight) {
            Text(label).font(.caption2).foregroundStyle(.tertiary).frame(width: 48, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private var idleHint: some View {
        Text(model.devices.isEmpty
             ? L(.menuBarNoDevice)
             : L(.menuBarReady, model.devices.first?.displayName ?? ""))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack {
                Button(L(.openMainWindow)) {
                    dismiss()
                    presentMainWindow(model, openWindow)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                // 仅菜单栏模式下这块面板是唯一入口，语言开关必须在这里也够得到 ——
                // 否则一个看不懂界面的用户，得先知道「要去 App 菜单」才能改语言，
                // 而在这个模式下 App 菜单只有把窗口开出来才看得见。
                languageMenu

                speedToggle

                Button(L(.quit)) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }

            if status.runState == .running {
                // 会话属于 helper，App 退出不影响它 —— 这一点必须说出来，
                // 否则用户会以为「退出 = 断网」而不敢点。
                Text(L(.quitTooltip))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 语言开关。选项写母语名字，不跟随界面语言翻译 —— 见 LanguageMenu 的说明。
    private var languageMenu: some View {
        Menu {
            Picker(L(.languageLabel), selection: Bindable(model).languagePreference) {
                Text(L(.languageSystem)).tag(LanguagePreference.system)
                Text(verbatim: "中文").tag(LanguagePreference.chinese)
                Text(verbatim: "English").tag(LanguagePreference.english)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.languageLabel))
    }

    /// 菜单栏速率显示开关。控制 MenuBarLabel 是否渲染 ↓/↑ 数值；
    /// 状态通过 @AppStorage("TetherKitShowMenuBarSpeed") 持久化，重启不丢失。
    @ViewBuilder
    private var speedToggle: some View {
        @AppStorage("TetherKitShowMenuBarSpeed") var showSpeed = true
        Button {
            showSpeed.toggle()
        } label: {
            Image(systemName: showSpeed ? "eye" : "eye.slash")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(showSpeed ? L(.hideSpeed) : L(.showSpeed))
    }

    private func speedRow(symbol: String, caption: String, bitsPerSecond: Double,
                          tint: Color) -> some View {
        HStack(spacing: Design.Spacing.small) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.bitrate(bitsPerSecond))
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}
