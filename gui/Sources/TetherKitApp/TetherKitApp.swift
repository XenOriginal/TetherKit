import AppKit
import SwiftUI

/// TetherKit 的图形界面入口。
///
/// App 以**普通用户身份**运行，不需要任何特权。所有需要 root 的事（建虚拟网卡、
/// 开 BPF、配 IP）都交给 tetherkit-helper，每次调用附带一份用户确认过的授权
/// 凭据。详见 docs/GUI-ARCHITECTURE.md。
///
/// ★ 后台运行模式 ★
///
///   关闭主窗口不退出：App 退到「仅菜单栏」（accessory 激活策略，程序坞图标
///   一并隐藏），菜单栏项继续显示实时速率。会话本来就跑在 helper 里，App 的
///   存在与否都不影响它 —— 但只要 App 活着，用户就有一个随时能看一眼的入口。
///
///   轮询在窗口关闭后**不**停（菜单栏靠它喂数据），只是在「窗口关着且会话
///   没跑」时放慢到 2 秒一次，见 AppModel.pollDelay。
@main
struct TetherKitApplication: App {
    @State private var model = AppModel()

    init() {
        // CI 冒烟与手动补建用的模式：建完 Finder 别名即退，不进 GUI。
        // 恒 exit 0 —— 别名建不上（受管机器之类）不该把流程判失败，结果打给
        // stdout。（brew 的 postinstall 也在沙箱里、写不了 /Applications ——
        // 实测确认 —— 所以正常安装路径靠下面的首次启动自动建立。）
        if CommandLine.arguments.dropFirst().contains("--install-finder-alias") {
            print(FinderAlias.ensure(for: Bundle.main.bundleURL))
            exit(0)
        }
        // 正常启动：后台顺手校一遍 —— 缺了就补，brew upgrade 换了 Cellar
        // 路径后目标漂移也会被重写。
        let bundleURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            FinderAlias.ensure(for: bundleURL)
        }
    }

    var body: some Scene {
        Window("TetherKit", id: "main") {
            MainWindowRoot(model: model)
        }
        // 用 Window 而不是 WindowGroup：这是一个「设备连接面板」，开多个窗口
        // 没有意义，反而会让多个实例同时轮询同一个 helper。
        .defaultSize(width: Design.Window.defaultWidth, height: Design.Window.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            // 「新建窗口」对单窗口应用没有意义，去掉免得用户点了没反应。
            CommandGroup(replacing: .newItem) {}
            // 「检查更新…」放在 App 菜单「关于」下面的惯例位置。
            // 只查不换 —— 原因见 UpdateChecker.swift 的类型注释。
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { await model.checkForUpdates() }
                }
            }
        }

        // 菜单栏常驻项：图标 + 实时速率。
        //
        // 用 .window 风格给一块小面板而不是一列菜单 —— 速率、地址这些信息是要
        // 「看」的，不是要「选」的，菜单条目装不下。
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 主窗口的根视图：内容 + 生命周期钩子 + 「擅自复活」拦截。
///
/// ★ 为什么需要拦截 ★
///
///   实测（打包版，macOS 26）：App 处于仅菜单栏模式时点菜单栏图标，SwiftUI 会在
///   面板打开的同时**擅自重建整个 Window 场景** —— 主窗口毫无来由地冒回来，把
///   面板压在底下。这不走 `applicationShouldHandleReopen`（插桩确认从未被调用，
///   SwiftUI 生命周期不转发它），所以没有干净的委托口子可堵。
///
///   对策是在结果端把关：窗口每次出现时问 AppModel「这次展示是我们自己要求的
///   吗」。只有两种合法来源 —— App 启动、用户点了「打开主窗口」—— 两处都会先在
///   模型上登记。没登记过的出现就是擅自复活，当场 dismiss，激活策略保持
///   accessory 不动。
///
///   代价：在仅菜单栏模式下双击访达里的 App 图标不会弹出主窗口（那次重建同样
///   会被拦掉）。这是权衡后的结果 —— 菜单栏是唯一入口的模式下，「点图标面板被
///   窗口顶掉」每天都会发生，而访达双击是罕见路径，面板里的「打开主窗口」随时
///   可用。
private struct MainWindowRoot: View {
    var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: Design.Window.minWidth, minHeight: Design.Window.minHeight)
            .task {
                // 轮询在这里启动（幂等）。窗口关闭后它继续跑 ——
                // 这正是菜单栏能实时更新的前提。
                model.start()
            }
            .onAppear {
                guard model.isWindowPresentationExpected() else {
                    dismissWindow(id: "main")
                    return
                }
                model.windowDidAppear()
                // 窗口在，程序坞图标就该在（从菜单栏重新打开时恢复它）。
                NSApp.setActivationPolicy(.regular)
            }
            .onDisappear {
                model.windowDidDisappear()
                // 关掉窗口就退到「仅菜单栏」：常驻小工具挂着一个没有窗口的
                // 程序坞图标只会让人想去点它。轮询与会话都不受影响。
                NSApp.setActivationPolicy(.accessory)
            }
    }
}

/// 从「仅菜单栏」的后台模式回到前台并显示主窗口。
///
/// 顺序是刻意的：先在模型上登记（否则 MainWindowRoot 的拦截会把窗口当成擅自
/// 复活关掉）；激活策略必须在 openWindow **之前**改回 .regular，否则新窗口可能
/// 落到别的应用后面；最后再 activate 把焦点抢过来。
@MainActor
func presentMainWindow(_ model: AppModel, _ openWindow: OpenWindowAction) {
    model.expectWindowPresentation()
    NSApp.setActivationPolicy(.regular)
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}
