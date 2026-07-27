import SwiftUI
import TetherKitIPC

/// 主界面。
///
/// 布局目标是**默认窗口尺寸下一屏放完，不滚动**：常驻仪表盘要靠滚动才能看全，
/// 等于把「瞟一眼」变成了「翻一遍」。为此分成两栏 ——
///
///   顶部横幅：现在什么状态（全宽，唯一的操作重心）
///   左栏「控制」：用哪台设备 → 怎么上网（连接前用，连上后基本不碰）
///   右栏「观测」：跑得怎么样 → 出了什么事（连上后 90% 的时间只看这边）
///
/// 日志不再折叠：它常驻右栏底部，把剩余高度全部吃掉 —— 窗口越大看到的越多，
/// 而不是留一片空白还要用户手动展开。
///
/// 外层仍留一个 ScrollView 兜底：极端组合（比如把窗口压到最小 + 静态表单 +
/// 系统参数警告同时出现）超出可视区时宁可滚动也不能截断。`basedOnSize` 保证
/// 内容放得下时它完全不参与 —— 不出滚动条也不回弹。
///
/// 刻意不用 NavigationSplitView 的侧边栏：这个 App 只有一件事可做，
/// 侧边栏只会制造一个空荡荡的导航层级。
struct ContentView: View {
    @Bindable var model: AppModel

    /// 卸载是破坏性动作（断开连接、删系统文件），必须先确认。
    @State private var confirmingHelperUninstall = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Group {
                    switch model.helperAvailability {
                    case .unknown:
                        ProbingCard()
                    case .missing(let reason):
                        HelperMissingCard(model: model, reason: reason)
                    case .outdated(let installed, let expected):
                        HelperOutdatedCard(model: model, installed: installed,
                                           expected: expected)
                    case .available:
                        dashboard
                    }
                }
                .padding(Design.Spacing.medium)
                // 撑满可视区：右栏的日志靠这个「多余高度」长到窗口底部。
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
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
        .confirmationDialog("卸载特权组件？", isPresented: $confirmingHelperUninstall) {
            Button("卸载", role: .destructive) {
                Task { await model.uninstallHelper() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(uninstallWarning)
        }
    }

    private var uninstallWarning: String {
        let base = "将注销系统服务并删除 /Library 里的组件文件，之后随时可以重新安装。"
        return model.status.runState == .running
            ? "当前连接会被断开、虚拟网卡销毁。" + base
            : base
    }

    private var dashboard: some View {
        VStack(spacing: Design.Spacing.gutter) {
            StatusHeroCard(model: model)
            EnvironmentWarningCard(environment: model.environment)

            HStack(alignment: .top, spacing: Design.Spacing.gutter) {
                VStack(spacing: Design.Spacing.gutter) {
                    DeviceCard(model: model)
                    NetworkCard(model: model)
                    // Spacer 把管理行压到左栏底部的既有空隙里。放在外层 VStack
                    // 末尾会新增一行整页高度 —— 「一屏放完」的布局刚好被它
                    // 顶破，footer 落到折叠线以下（实测踩过）。
                    Spacer(minLength: 0)
                    helperManagementFooter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack(spacing: Design.Spacing.gutter) {
                    ThroughputCard(model: model)
                    LogCard(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// 左栏底部的特权组件管理行。
    ///
    /// 刻意做得低调（caption + borderless）：卸载是极低频的管理动作，不该
    /// 从正常使用里抢走任何注意力 —— 但它必须存在于主界面，否则组件
    /// 「装得上、删不掉」，只能回终端翻脚本。
    @ViewBuilder
    private var helperManagementFooter: some View {
        if case .available(let version) = model.helperAvailability {
            HStack(spacing: Design.Spacing.small) {
                Text("特权组件 · \(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                Button("卸载特权组件…") { confirmingHelperUninstall = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(model.isBusy)
            }
            .padding(.horizontal, Design.Spacing.tight)
        }
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
/// 这是新用户最可能撞上的一屏，所以把「为什么需要」说清楚之后直接给一个
/// 「安装」按钮 —— 弹一次系统授权框就装好。终端方案降级成折叠里的备选。
private struct HelperMissingCard: View {
    @Bindable var model: AppModel
    let reason: String

    var body: some View {
        Card(title: "需要先安装特权组件", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Text("创建虚拟网卡和打开数据链路需要管理员权限。TetherKit 把这部分\n"
                     + "放在一个独立的后台组件里，App 本身以普通用户身份运行。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HelperInstallSection(
                    model: model,
                    buttonTitle: "安装特权组件",
                    detail: "组件会被装到 /Library/PrivilegedHelperTools 并注册为\n"
                        + "LaunchDaemon。装好后本页自动恢复，不需要重启 App。")

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

/// 装着的 helper 与当前 App 的 XPC 接口对不上。
///
/// 单独一屏而不是复用「没安装」：这两种情况下用户要做的事不一样，而且如果不
/// 明说，症状会表现成调用卡住或直接崩溃 —— 那是最难自查的一类问题。
private struct HelperOutdatedCard: View {
    @Bindable var model: AppModel
    let installed: Int
    let expected: Int

    var body: some View {
        Card(title: "特权组件需要更新", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Text("已安装的特权组件是升级前的版本，与当前 App 的通信接口对不上"
                     + "（组件 v\(installed)，App 需要 v\(expected)）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HelperInstallSection(
                    model: model,
                    buttonTitle: "更新特权组件",
                    detail: "更新会先注销旧版本再装新的，装好后本页自动恢复。")
            }
        }
    }
}

/// 「一键安装」按钮 + 终端备选方案。missing / outdated 两张卡共用。
///
/// 终端方案必须保留而不是彻底删掉：`swift run` 跑的裸可执行文件没有内嵌载荷，
/// 按钮会明确报错引导到脚本；也总有人就是不愿意往 App 弹的框里输密码。
private struct HelperInstallSection: View {
    @Bindable var model: AppModel
    let buttonTitle: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.small) {
                Button {
                    Task { await model.installHelper() }
                } label: {
                    HStack(spacing: Design.Spacing.tight) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(model.isBusy ? "正在安装……" : buttonTitle)
                    }
                    .frame(minWidth: 132)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)

                Text("会弹出系统授权框，需要输入一次管理员密码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("改用终端安装") {
                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    CopyableCommand(command: "sudo ./gui/Scripts/install-helper.sh")
                    Text("在仓库根目录执行，效果与按钮完全相同。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Design.Spacing.tight)
            }
            .font(.caption)
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
