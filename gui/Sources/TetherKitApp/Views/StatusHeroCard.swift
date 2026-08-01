import SwiftUI
import TetherKitIPC

/// 主状态卡：整个界面的视觉与操作重心。
///
/// 一屏之内回答四个问题：现在通不通、通到哪张网卡、什么 IP、要不要断开。
/// 其余细节都往下面的卡片里放 —— 用户九成的时间只看这一块。
struct StatusHeroCard: View {
    @Bindable var model: AppModel

    private var accent: Color { Design.accent(for: model.status.runState) }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Design.Spacing.large) {
                StatusRing(status: model.status, accent: accent)

                // 不能用 Spacer 隔开地址行：整页布局靠「多余高度归两栏」工作，
                // 卡片里一根 Spacer 就会把横幅无限撑高。
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    headline
                    subline
                    addressLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                actionButton
            }
        }
    }

    private var headline: some View {
        HStack(spacing: Design.Spacing.small) {
            Text(Design.statusLabel(for: model.status))
                .font(.system(.title2, design: .rounded).weight(.semibold))

            if model.status.runState == .running {
                StatusBadge(text: L(model.status.linkUp ? .linkUp : .linkDown),
                            color: model.status.linkUp ? .green : .orange)
            }
            if model.status.paused {
                StatusBadge(text: L(.transferPaused), color: .orange)
            }
        }
    }

    @ViewBuilder
    private var subline: some View {
        if model.status.runState == .failed, !model.status.fatalMessage.isEmpty {
            Text(model.status.fatalMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if !model.status.deviceDescription.isEmpty {
            Text(deviceSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let device = model.selectedDevice {
            Text(L(.pendingDevice, device.displayName))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(L(.noRNDISDeviceDetected))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceSummary: String {
        var parts: [String] = []
        if !model.status.vendorDescription.isEmpty {
            parts.append(model.status.vendorDescription)
        }
        parts.append(model.status.deviceDescription)
        if model.status.mtu > 0 {
            parts.append("MTU \(model.status.mtu)")
        }
        if model.status.linkSpeedMbps > 0 {
            parts.append("\(model.status.linkSpeedMbps) Mbps")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var addressLine: some View {
        if model.status.runState == .running || model.status.runState == .starting {
            HStack(spacing: Design.Spacing.large) {
                inlineMetric(L(.interfaceLabel), model.status.systemInterface.isEmpty
                    ? L(.interfaceCreating) : model.status.systemInterface)
                inlineMetric(L(.ipAddress), model.networkState.hasAddress
                    ? model.networkState.address : L(.notConfigured))
                if let duration = model.connectedDuration {
                    inlineMetric(L(.statusConnected), Format.duration(duration))
                }
            }
        }
    }

    private func inlineMetric(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let isRunning = model.status.runState == .running
        let isTransitional = model.status.runState.isTransitional

        Button {
            Task {
                if isRunning {
                    await model.stopSession()
                } else {
                    await model.startSession()
                }
            }
        } label: {
            HStack(spacing: Design.Spacing.tight) {
                if isTransitional || model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                }
                Text(L(isRunning ? .disconnect : .connect))
            }
            .frame(minWidth: 76)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(isRunning ? .red : .accentColor)
        // 没有设备时不让点「连接」—— 点了必然失败，不如直接说明白。
        .disabled(model.isBusy || isTransitional || (!isRunning && model.devices.isEmpty))
        .help(model.devices.isEmpty && !isRunning ? L(.connectDisabledHint) : "")
    }
}

/// 状态圆环。
///
/// ★ CPU 关键 ★
///
/// 旧实现让 `breathing` 用 `.repeatForever` 在**整段会话**里持续脉冲 —— 只要
/// 会话在跑（isActive = true），SwiftUI 的渲染循环就以 60fps 永远空转，这是
/// connect 后主进程 CPU 居高不下（实测 ~40%）的真正根因。降轮询频率、砍图表
/// 重绘都治不到它，因为它们都挂在 1Hz 的轮询上，而这段动画完全独立于轮询。
///
/// 新方案：运行中**完全静止**，靠链路指示徽标 + 实时吞吐图表表达「在干活」，
/// 不再为无信息量的动画烧 CPU；只有「过渡态」（starting/stopping，通常几秒）
/// 才跑一段旋转弧，用 Timer 驱动而不是 .repeatForever —— 后者在 SwiftUI 中
/// 无法可靠停止，会导致渲染循环持续 60fps 空转。
private struct StatusRing: View {
    let status: SessionStatus
    let accent: Color

    @State private var rotation: Double = 0
    @State private var spinning = false
    @State private var spinTimer: Timer?

    private var isActive: Bool { status.runState == .running && status.linkUp }
    private var isWorking: Bool { status.runState.isTransitional }

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(isActive ? 0.16 : 0.12))
                .frame(width: 64, height: 64)

            Circle()
                .stroke(accent.opacity(0.25), lineWidth: 3)
                .frame(width: 64, height: 64)

            // 过渡态用一段旋转的弧表示「正在进行中，进度不可知」；运行中显示整圈。
            Circle()
                .trim(from: 0, to: isWorking ? 0.25 : (isActive ? 1.0 : 0.0))
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(isWorking ? rotation : -90))

            Image(systemName: Design.statusSymbol(for: status))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: 72, height: 72)
        .onAppear { updateAnimationState() }
        .onChange(of: status.runState) { _, _ in updateAnimationState() }
        .onChange(of: status.linkUp) { _, _ in updateAnimationState() }
        .onDisappear {
            // 视图消失时必须停掉 timer，否则 Timer 在后台继续 fire 空转 CPU
            stopSpinTimer()
        }
    }

    /// 只在「过渡态」启动旋转，离开过渡态立即停止；运行中保持静止。
    ///
    /// 用 Timer 驱动旋转而不是 .repeatForever：
    ///   - Timer 在 spinning=false 时精确停止，不会残留渲染循环
    ///   - 每次 tick 只触发一次 SwiftUI redraw，而不是 60fps continuous
    ///   - 视图消失时 onDisappear 保证 timer 被清理
    private func updateAnimationState() {
        if isWorking {
            guard !spinning else { return }
            spinning = true
            // 每 1.1 秒旋转一圈，用 withAnimation 让过渡平滑
            spinTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.linear(duration: 1.1)) {
                        rotation += 360
                    }
                }
            }
            // 立即开始第一次旋转
            withAnimation(.linear(duration: 1.1)) {
                rotation += 360
            }
        } else {
            stopSpinTimer()
            spinning = false
            // 一次性动画把 rotation 收回 0，渲染循环得以 idle。
            withAnimation(.default) { rotation = 0 }
        }
    }

    private func stopSpinTimer() {
        spinTimer?.invalidate()
        spinTimer = nil
    }
}
