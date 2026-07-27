import AppKit
import SwiftUI
import TetherKitIPC

/// 菜单栏里的常驻标签：状态图标 + 实时速率。
///
/// 只在会话运行时显示速率文本 —— 空闲时一串 "0K" 只是噪音，图标本身已经把
/// 状态说清楚了。数字用等宽，避免速率跳动时把右边的其它菜单栏项挤来挤去。
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: Design.statusSymbol(for: model.status))
            if model.status.runState == .running {
                Text(speedText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }

    private var speedText: String {
        "↓\(Format.compactBitrate(model.throughput.receiveBitsPerSecond))"
            + " ↑\(Format.compactBitrate(model.throughput.transmitBitsPerSecond))"
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
        speedRow(symbol: "arrow.down", caption: "下行",
                 bitsPerSecond: model.throughput.receiveBitsPerSecond, tint: .blue)
        speedRow(symbol: "arrow.up", caption: "上行",
                 bitsPerSecond: model.throughput.transmitBitsPerSecond, tint: .purple)

        if !status.systemInterface.isEmpty {
            Text("\(status.systemInterface) · "
                 + (model.networkState.hasAddress ? model.networkState.address : "未配置 IP"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var idleHint: some View {
        Text(model.devices.isEmpty
             ? "未检测到设备。用数据线连接手机并开启 USB 网络共享。"
             : "已就绪：\(model.devices.first?.displayName ?? "")。打开主窗口即可连接。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack {
                Button("打开主窗口") {
                    dismiss()
                    presentMainWindow(model, openWindow)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button("退出") {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }

            if status.runState == .running {
                // 会话属于 helper，App 退出不影响它 —— 这一点必须说出来，
                // 否则用户会以为「退出 = 断网」而不敢点。
                Text("退出只是关闭界面，已建立的连接会继续运行。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
