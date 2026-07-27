import SwiftUI

/// TetherKit 的图形界面入口。
///
/// App 以**普通用户身份**运行，不需要任何特权。所有需要 root 的事（建虚拟网卡、
/// 开 BPF、配 IP）都交给 tetherkit-helper，每次调用附带一份用户刚确认过的授权
/// 凭据。详见 docs/GUI-ARCHITECTURE.md。
@main
struct TetherKitApplication: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("TetherKit", id: "main") {
            ContentView(model: model)
                .frame(minWidth: Design.Window.minWidth, minHeight: Design.Window.minHeight)
                .task {
                    // 轮询在窗口出现时才开始 —— App 还没显示就发 XPC 只会把
                    // helper 提前拉起来。
                    model.start()
                }
        }
        // 用 Window 而不是 WindowGroup：这是一个「设备连接面板」，开多个窗口
        // 没有意义，反而会让多个实例同时轮询同一个 helper。
        .defaultSize(width: Design.Window.defaultWidth, height: Design.Window.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            // 「新建窗口」对单窗口应用没有意义，去掉免得用户点了没反应。
            CommandGroup(replacing: .newItem) {}
        }
    }
}
