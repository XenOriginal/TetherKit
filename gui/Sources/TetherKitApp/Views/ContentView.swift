import SwiftUI
import TetherKitIPC

/// 主界面。
///
/// 布局是单列滚动，从上到下按「用户关心的顺序」排：
///   现在什么状态 → 用哪台设备 → 怎么上网 → 跑得怎么样 → 出了什么事
///
/// 刻意不用 NavigationSplitView 的侧边栏：这个 App 只有一件事可做，
/// 侧边栏只会制造一个空荡荡的导航层级。
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: Design.Spacing.medium) {
                switch model.helperAvailability {
                case .unknown:
                    ProbingCard()
                case .missing(let reason):
                    HelperMissingCard(reason: reason)
                case .available:
                    mainSections
                }
            }
            .padding(Design.Spacing.medium)
        }
        .background(backgroundGradient)
        .animation(.smooth(duration: 0.25), value: model.status.runState)
        .animation(.smooth(duration: 0.25), value: model.helperAvailability)
        .alert("操作失败",
               isPresented: Binding(get: { model.alertMessage != nil },
                                    set: { if !$0 { model.alertMessage = nil } })) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var mainSections: some View {
        StatusHeroCard(model: model)
        EnvironmentWarningCard(environment: model.environment)
        DeviceCard(model: model)
        NetworkCard(model: model)
        ThroughputCard(model: model)
        LogCard(model: model)
    }

    /// 背景用一层随状态变化的极淡渐变。
    ///
    /// 强度刻意压得很低（0.10 / 0.04）：它的作用是让「连上了」这件事在余光里
    /// 也能被感知，而不是抢内容的注意力。
    private var backgroundGradient: some View {
        let accent = Design.accent(for: model.status.runState)
        return LinearGradient(
            colors: [accent.opacity(0.10), accent.opacity(0.04), .clear],
            startPoint: .top,
            endPoint: .bottom)
        .ignoresSafeArea()
    }
}

/// 正在探测 helper 时的占位。
private struct ProbingCard: View {
    var body: some View {
        Card {
            HStack(spacing: Design.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查特权组件……")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Design.Spacing.large)
        }
    }
}

/// helper 没装时的引导。
///
/// 这是新用户最可能撞上的一屏，所以把「为什么需要」和「怎么装」一次说清楚，
/// 并且命令可以一键复制 —— 让用户自己去 README 里翻是最差的体验。
private struct HelperMissingCard: View {
    let reason: String

    private var installCommand: String {
        "sudo \(FileManager.default.currentDirectoryPath)/gui/Scripts/install-helper.sh"
    }

    var body: some View {
        Card(title: "需要先安装特权组件", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Text("创建虚拟网卡和打开数据链路需要管理员权限。TetherKit 把这部分\n"
                     + "放在一个独立的后台组件里，App 本身以普通用户身份运行。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    Text("在终端里执行安装脚本：")
                        .font(.callout)
                    CopyableCommand(command: "sudo ./gui/Scripts/install-helper.sh")
                    Text("脚本会把组件装到 /Library/PrivilegedHelperTools 并注册\n"
                         + "LaunchDaemon。装好后本页会自动恢复，不需要重启 App。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("查看连接失败的详细原因") {
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Design.Spacing.tight)
                }
                .font(.caption)
            }
        }
    }
}

/// 一条可复制的命令。
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                // 2 秒后复原。给的是「已复制」这个确认，不是一个需要用户操作的状态。
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(copied ? "已复制到剪贴板" : "复制命令")
        }
        .padding(Design.Spacing.small)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Design.Radius.control))
    }
}

/// 环境预检不合格时的警告。合格时不显示 —— 一切正常时不该占用户的注意力。
private struct EnvironmentWarningCard: View {
    let environment: EnvironmentReport?

    var body: some View {
        if let environment, !environment.sysctlsOK {
            Card(title: "系统参数需要调整", systemImage: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("下面这些开关会在虚拟网卡**创建时**被快照进去，创建后再改无效，\n"
                         + "因此必须先修正再连接：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(environment.sysctlDetail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Design.Spacing.small)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Design.Radius.control))
                }
            }
        }
    }
}
