import Foundation
import Observation
import ServiceManagement
import SwiftUI
import TetherKitCore
import TetherKitIPC

/// 一次采样得到的瞬时速率。
struct ThroughputSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let receiveBitsPerSecond: Double
    let transmitBitsPerSecond: Double
    let receivePacketsPerSecond: Double
    let transmitPacketsPerSecond: Double

    static let zero = ThroughputSample(timestamp: .distantPast, receiveBitsPerSecond: 0,
                                       transmitBitsPerSecond: 0, receivePacketsPerSecond: 0,
                                       transmitPacketsPerSecond: 0)
}

/// 连续重复的日志折叠成一条。
///
/// 周期性路径（比如每 2 秒一次的设备枚举）会把同一句话刷成一整列，淹没真正
/// 有信息量的行；折叠成「一行 ×N」承载同样的信息。id 取首条的 —— 重复只更新
/// 计数与时间戳，行的身份不变，列表不用整行重建。
struct CollapsedLogEntry: Identifiable {
    let first: LogEntry
    private(set) var latest: LogEntry
    private(set) var count: Int = 1

    init(_ entry: LogEntry) {
        first = entry
        latest = entry
    }

    var id: UUID { first.id }

    /// 时间戳以外完全相同才算重复 —— 消息里带着变化的值（地址、计数）就该分行。
    func matches(_ entry: LogEntry) -> Bool {
        entry.level == first.level && entry.thread == first.thread
            && entry.message == first.message
    }

    mutating func absorb(_ entry: LogEntry) {
        latest = entry
        count += 1
    }
}

/// helper 的可达性。界面靠它决定是「显示安装引导」还是「正常工作」。
enum HelperAvailability: Equatable {
    case unknown
    case available(version: String)
    case missing(reason: String)
    /// 装着的 helper 比当前 App 旧（或新），XPC 接口对不上。
    ///
    /// 单独一个状态而不是并进 missing：这两种情况的解决办法不一样，
    /// 一个是「去装」，一个是「去重装」，提示文案必须能区分。
    case outdated(installed: Int, expected: Int)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 装着的特权组件与 App 自带的那份不是同一个版本。
///
/// ★ 与 `HelperAvailability.outdated` 的分工 ★
///   那个说的是**协议对不上**：方法签名都不一致了，再调下去要么卡住要么崩，
///   所以必须挡在安装引导页上。这个说的是**协议仍兼容、版本却不一样** ——
///   组件照常能用，只是它里面还是升级前的那份 libtetherkit，新版修的问题在
///   真正干活的那一侧一个都没修（`brew upgrade` 只换 .app，动不了
///   /Library/PrivilegedHelperTools）。
///
///   所以它不拦路，只在管理行里点亮一个「更新特权组件」。协议号不变的版本
///   （0.1.4 → 0.1.5 这种）以前完全没有提示，用户唯一能察觉的迹象是
///   「更新说明里写着修好的毛病还在」。
struct HelperVersionMismatch: Equatable {
    /// 装着的那份，只取版本号（如 `"0.1.3"`）。
    let installed: String
    /// App 自带的那份 —— 点了按钮之后会装上去的版本。
    let expected: String
}

/// 手动「检查更新」的结果，驱动一个弹窗。
enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(UpdateChecker.Release)
    case failed(String)
    /// 开发构建（`swift run` 的裸可执行文件）没有版本号，没法比。
    case unavailable
}

/// 让用户输入管理员密码的弹窗状态。
///
/// 只在「钥匙串里没有可用密码」或「存的密码已经失效（用户改了管理员密码）」时
/// 出现 —— 正常情况下自动加载钥匙串，根本不会看到它。凭据由 Security 服务器校验，
/// 这里只负责把用户现输的密码交出去。
struct CredentialPromptState: Identifiable {
    let id = UUID()
    /// 标题。
    let title: String
    /// 说明文字：首次是「请输入密码以便下次自动加载」，重试是「密码不正确」。
    let message: String
}

/// 界面的全部状态与动作。
///
/// ★ 为什么所有事都经过 helper，而不是 App 自己调库 ★
///   App 以普通用户身份运行，建 feth 和开 BPF 都要 root，所以会话只能在 helper
///   里跑。设备枚举与环境预检虽然不需要 root，但也统一走 helper —— 会话跑起来后
///   设备已被 helper 独占，App 再去读只会得到不一致的结果。
@Observable
@MainActor
final class AppModel {
    // MARK: - 对界面公开的状态

    private(set) var helperAvailability: HelperAvailability = .unknown
    /// 装着的组件与 App 版本对不上时的两个版本号；一致（或还没探到）为 nil。
    private(set) var helperVersionMismatch: HelperVersionMismatch?
    private(set) var environment: EnvironmentReport?

    /// App 自身版本号（来自 TetherKitLibrary.versionInfo），供界面底部显示。
    var appVersion: String { TetherKitLibrary.versionInfo.version }

    /// GitHub 仓库地址与当前 commit 短哈希，供界面右下角显示。
    ///
    /// 构建产物（build-gui.sh 组装的 .app）：CFBundleVersion 格式为
    ///   `{YYYYMMDD}-BETA-{REPO}-{COMMIT}`，从中提取最后一段即为短哈希。
    /// 开发构建（swift run）：回退到 git 动态查询，再不行显示 "dev"。
    static let githubRepoURL = "github.com/XenOriginal/TetherKit"
    var appBuildInfo: String {
        if let buildStamp = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           !buildStamp.isEmpty && buildStamp != "__TETHERKIT_BUILD__" {
            // 构建戳格式：20260801-BETA-XenOriginal/TetherKit-3e4eacd
            // 取最后一段（commit 短哈希）
            let shortHash = buildStamp.components(separatedBy: "-").last ?? buildStamp
            return "\(Self.githubRepoURL) · \(shortHash)"
        }
        // 开发构建：尝试动态读 git
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", Bundle.main.resourcePath ?? ".", "rev-parse", "--short", "HEAD"]
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0,
               let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
               let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hash.isEmpty {
                return "\(Self.githubRepoURL) · \(hash)"
            }
        } catch { /* git 不可用，静默降级 */ }
        return "\(Self.githubRepoURL) · dev"
    }
    private(set) var devices: [DeviceDescriptor] = []
    private(set) var status: SessionStatus = .idle
    private(set) var networkState: NetworkState = .empty
    private(set) var networkStateV6: NetworkStateV6 = .empty

    /// 网络配置节流用的状态：上次查询时刻与上次查询的接口名。
    ///
    /// `queryNetwork` 走 XPC（helper 内部是 ioctl + SCDynamicStore，单次不贵，
    /// 但跟着 500 ms 状态轮询每周期查两次就是没必要的 XPC 往返）。接口没变、
    /// 又没到 `Self.networkQueryInterval` 时就沿用上次结果，把这两类查询降频。
    private var lastNetworkQueryAt: Date = .distantPast
    private var lastNetworkInterfaceQueried: String = ""
    private(set) var throughput: ThroughputSample = .zero
    private(set) var throughputHistory: [ThroughputSample] = []
    private(set) var logs: [LogEntry] = []
    private(set) var droppedLogCount: UInt64 = 0

    /// 注入自定义日志到主日志面板（供 AutoConnectManager 等内部模块使用）。
    func injectLog(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(level: level, timestamp: Date(), thread: "auto-connect",
                             message: message)
        logs.append(entry)
        if logs.count > Self.logCapacity {
            logs.removeFirst(logs.count - Self.logCapacity)
        }
        if level >= logLevelFilter {
            if let last = cachedFilteredLogs.last, last.matches(entry) {
                cachedFilteredLogs[cachedFilteredLogs.count - 1].absorb(entry)
            } else {
                cachedFilteredLogs.append(CollapsedLogEntry(entry))
            }
        }
    }

    /// 缓存版的 filteredLogs。
    ///
    /// 原始 filteredLogs 是 O(n) 计算属性（n ≤ 2000），在 SwiftUI 每次 body 重算时
    /// 都执行一遍。活跃转发时状态每秒变 6+ 次（吞吐/计数器/日志），每个依赖
    /// filteredLogs 的视图都会触发全量扫描 —— 实测是 GUI CPU 38%+ 的主要来源之一。
    ///
    /// 改为在 apply(feed:) 里增量更新缓存，这里直接返回，O(1)。
    private(set) var cachedFilteredLogs: [CollapsedLogEntry] = []

    /// 用户在设备列表里选中的那台。为 nil 表示「用找到的第一台」。
    var selectedDeviceID: String?
    /// 会话配置里用户可调的部分。
    var requestedMTU: UInt32 = 1500
    var adoptDeviceMAC: Bool = true
    /// 网络配置表单（IPv4）。
    var networkConfiguration: NetworkConfiguration = .dhcp
    /// 网络配置表单（IPv6）。
    var networkConfigurationV6: NetworkConfigurationV6 = .automatic

    /// 自动应用：手机通过 RNDIS 连接后自动按已保存的配置获取 IP 地址。
    ///
    /// 经 @AppStorage 持久化，重启不丢失。默认开启 —— 大多数用户连上就想上网，
    /// 多点一次 Apply 只是额外摩擦。
    /// @ObservationIgnored 是必须的：@Observable 宏会追踪所有存储属性，
    /// 而 @AppStorage 自己也会合成一个 _autoApplyEnabled 存储属性，两者冲突。
    @ObservationIgnored
    @AppStorage("TetherKitAutoApply") var autoApplyEnabled = true

    /// 开机自启：App 登录时自动启动，方便随时连接设备。
    ///
    /// 经 @AppStorage 持久化；真正的登录项注册/注销通过 SMAppService 完成。
    /// 启动时在 syncLoginItemState() 中校准，防止系统侧与本地偏好不一致
    /// （比如用户在「系统设置 → 登录项」里手动改过）。
    @ObservationIgnored
    @AppStorage("TetherKitLoginItem") var loginItemEnabled = false

    /// 自动连接：检测到已授权的 ADB 设备时自动启用 RNDIS 并建立连接。
    ///
    /// 经 @AppStorage 持久化。默认关闭 —— 此功能依赖 adb，且会自动触发连接，
    /// 只在用户明确需要时开启。
    @ObservationIgnored
    @AppStorage("TetherKitAutoConnect") var autoConnectEnabled = true

    /// 自动连接管理器。持有 ADB 检测、白名单与自动连接编排逻辑。
    let autoConnectManager = AutoConnectManager()

    /// 当前会话是否已执行过自动应用（防止每次轮询都重复触发）。
    private var autoAppliedForCurrentSession = false

    /// 本次启动是否已尝试过 helper 自动升级（防止每次轮询都重复触发）。
    private var helperAutoUpgradeAttempted = false

    /// 界面语言偏好。改它会**同时**做三件事：切 Swift 侧的文案表、把语言推给
    /// libtetherkit（否则日志卡里会混进另一种语言）、再推给 helper（它以 root
    /// 跑在 launchd 下，看不到用户的语言偏好）。
    ///
    /// `didSet` 里顺带把 `languageRevision` 加一 —— 文案是从全局表里查的，
    /// SwiftUI 无从得知它变了，得靠这个值把视图树整个重建一次。
    var languagePreference: LanguagePreference = .system {
        didSet {
            guard languagePreference != oldValue else { return }
            applyLanguage(languagePreference)
        }
    }

    /// 语言换了多少次。视图根上挂 `.id(model.languageRevision)`，靠它触发重建。
    private(set) var languageRevision = 0

    /// 正在等待某个特权操作完成 —— 界面据此禁用按钮并显示进度。
    private(set) var isBusy: Bool = false
    /// 正在自动升级 helper（启动时检测到版本不一致，无需用户手动点更新）。
    private(set) var isAutoUpgradingHelper: Bool = false
    /// 需要弹给用户看的错误。
    var alertMessage: String?

    /// 已知的新版本。驱动管理行里的「有新版」提示；nil = 没有或没查过。
    private(set) var availableUpdate: UpdateChecker.Release?
    /// 手动「检查更新」的结果弹窗。视图关掉弹窗时置回 nil。
    var updateCheckResult: UpdateCheckResult?

    var logLevelFilter: LogLevel = .info

    // MARK: - 内部

    private let client = HelperClient()
    private var pollingTask: Task<Void, Never>?
    /// 心跳任务：每 3 秒向 helper 发一次心跳，让 helper 确认 GUI 还活着。
    /// helper 在连续 10 秒未收到心跳时会自动断开连接并退出。
    private var heartbeatTask: Task<Void, Never>?
    /// 上一次的状态快照，用来做差算速率。
    private var previousStatus: SessionStatus?
    /// 上一次的设备列表快照，用于检测设备插拔变化。
    private var previousDeviceCount: Int = 0
    private var sessionStartedAt: Date?
    /// 上次枚举设备的时刻。用单调时钟，避免系统时间被调整时算出负的间隔。
    private var lastDeviceRefresh: ContinuousClock.Instant?

    /// 会话进入 idle 状态的时刻。用于实现「空闲稳定后停止设备枚举」，
    /// 消除 macOS 菜单栏 USB 图标闪烁。非 idle 时为 nil。
    private var sessionBecameIdleAt: ContinuousClock.Instant?

    /// 会话进入 failed 状态的时刻。用于实现自动错误恢复：failed 超过一定时间
    /// 后自动重置状态，允许用户重新连接，而不需要手动重启 App。
    private var sessionFailedAt: ContinuousClock.Instant?

    /// 主窗口当前是否可见。只影响轮询节奏；程序坞图标策略在视图层处理。
    private var isWindowVisible = true

    /// 最近一次「明确要求显示主窗口」的时刻。初始值 = 现在，因为 App 启动本身
    /// 就是一次合法的窗口展示。
    private var windowPresentationRequestedAt = ContinuousClock.now

    /// 缓存的授权令牌。为 nil 表示下次特权操作需要弹框。
    ///
    /// 不自己记过期时间：系统的 timeout 由授权数据库控制（可能被管理员改），
    /// 我们自己算一份只会和系统不一致。以 helper 的复核结果为准更可靠。
    private var cachedAuthorization: AuthorizationToken?

    /// 当前是否正在向用户索要密码（驱动 ContentView 的 sheet）。
    ///
    /// 与 `alertMessage` 一样走 `var`（而非 `private(set)`）：`.sheet(item:)` 在
    /// 用户取消/提交后需要把绑定写回 nil 来关闭弹窗，需要可写绑定。
    var credentialPrompt: CredentialPromptState?

    /// 密码框里当前输入的明文。弹窗关闭即清空，不在内存里久留。
    var credentialPassword: String = ""

    /// 提交中 / 取消中：防止重复点击与「提交后又取消」的竞态。
    var credentialSubmitting = false
    var credentialCancelling = false

    /// 密码输入框的异步等待点。用户提交或取消时 `resume`。
    private var credentialContinuation: CheckedContinuation<String?, Never>?

    /// 系统授权框里显示的说明。
    ///
    /// 不写这一句的话框里只有「TetherKit 想要进行更改」，用户无从判断该不该批准。
    /// 用计算属性而不是 `static let`：`static let` 只在类型第一次被用到时求值
    /// 一次，用户之后切换语言就再也不会更新了。
    private static var authorizationPrompt: String { L(.authPromptSession) }

    /// 安装特权组件时授权框里的说明。单独一句 —— 这次批准的是「往系统目录里
    /// 装东西」，和上面的日常操作不是一回事，文案必须说实话。
    private static var helperInstallPrompt: String { L(.authPromptInstall) }

    /// 卸载特权组件时授权框里的说明。
    private static var helperUninstallPrompt: String { L(.authPromptUninstall) }

    /// 轮询周期（窗口可见、且会话在跑或在起停时）。
    ///
    /// 1 秒是「看起来实时」与「别把 XPC 往返变成负担」的平衡点：吞吐速率由库内
    /// 单调时钟差分计算，与轮询间隔无关，所以降频不影响数值准确性；而对人眼来说
    /// 1 Hz 的速率刷新已经完全够用，2 Hz 毫无可感知差别，却把 App + helper 的
    /// 每周期 XPC 负载砍掉一半。
    private static let pollInterval: Duration = .seconds(1)

    /// 纯后台待机（窗口关着、会话没跑）时的轮询间隔。
    ///
    /// 拉到 4 秒：后台时没人盯着实时速率，状态轮询的唯一产出是 helper 探活与
    /// 设备扫描，没人需要它们每两秒一次。省下的 XPC 往返也直接降低 helper 负载。
    private static let backgroundPollInterval: Duration = .seconds(4)

    /// 网络配置（IP/网关/DNS）的轮询间隔（秒）。
    ///
    /// 这些信息在会话运行期间基本不变，没必要跟着状态轮询一起每周期查两次 XPC。
    /// 降到 2 秒就足够「看起来实时」，并把 helper 上这两类查询的频次砍到约四分之一。
    private static let networkQueryIntervalSeconds: TimeInterval = 2

    /// 设备枚举的最小间隔。
    ///
    /// 比状态轮询慢得多，因为枚举要 libusb_open 去读字符串描述符。2 秒的插拔
    /// 响应延迟用户基本感觉不到，而开销降到了原来的四分之一。
    private static let deviceRefreshInterval: Duration = .seconds(2)

    /// 空闲稳定等待时间：会话进入 idle 后经过此时间且设备列表非空，
    /// 即视为「已稳定」，停止 libusb_open/close 枚举以消除 macOS 菜单栏
    /// "USB 连接到虚拟机" 图标反复闪烁。
    ///
    /// 8 秒足够覆盖正常的状态转换抖动（starting → running → stopping → idle），
    /// 同时让用户在拔插设备后最多等 8 秒就能看到列表更新。
    private static let idleDeviceSettleDuration: Duration = .seconds(8)

    /// 自动错误恢复等待时间：会话进入 failed 后经过此时间，自动重置状态
    /// 允许用户重新连接。避免用户看到错误后必须手动操作才能恢复。
    ///
    /// 5 秒足够用户看到错误信息，又不会让界面长时间停留在错误状态。
    private static let autoRecoveryDuration: Duration = .seconds(5)

    /// 吞吐曲线保留的采样点数。60 点 × 1 s = 最近 60 秒。
    ///
    /// 从 120 降到 60：Swift Charts 的 ForEach + monotone 插值渲染成本与数据点数
    /// 近似线性，减半能显著降低活跃转发时的 GUI CPU（实测 Charts 重绘是
    /// 38%+ 的主要贡献者之一）。60 秒的滚动窗口对「看抖动和趋势」完全够用。
    private static let historyCapacity = 60

    /// 日志面板保留的行数。
    ///
    /// 2000 行足够回溯一整次启动序列加若干分钟运行；再多 SwiftUI 的列表会开始卡。
    private static let logCapacity = 2000

    // MARK: - 生命周期

    /// 应用一个语言偏好：本进程 → libtetherkit → helper，一处都不能漏。
    ///
    /// UserDefaults 只在这里写，读在 `restoreLanguagePreference()` 里 ——
    /// 两边都走同一个键名常量，改名不会漏改一半。
    func applyLanguage(_ preference: LanguagePreference) {
        let resolved = L10n.apply(preference)
        TetherKitLibrary.setLanguage(resolved)
        UserDefaults.standard.set(preference.rawValue, forKey: Self.languageDefaultsKey)
        languageRevision += 1
        Task { await client.setLanguage(resolved) }
    }

    /// 启动时恢复上次选的语言。没存过就是 `.system`。
    private func restoreLanguagePreference() {
        let stored = UserDefaults.standard.string(forKey: Self.languageDefaultsKey)
        let preference = stored.flatMap(LanguagePreference.init(rawValue:)) ?? .system
        // 直接写存储属性会触发 didSet 再存一次盘，绕开它：这里是「恢复」，
        // 不是「用户改了」。
        if preference != languagePreference {
            languagePreference = preference
        } else {
            applyLanguage(preference)
        }
    }

    private static let languageDefaultsKey = "TetherKitLanguagePreference"

    /// 启动时校准登录项状态：以系统侧（SMAppService）为准，覆盖本地 AppStorage。
    ///
    /// 用户可能在「系统设置 → 登录项」里手动增删过，也可能换过 App 版本导致
    /// 注册丢失 —— 这里统一拉齐，避免界面显示与实际行为不一致。
    private func syncLoginItemState() {
        let registered = SMAppService.mainApp.status == .enabled
        if loginItemEnabled != registered {
            loginItemEnabled = registered
        }
    }

    /// 切换开机自启：同时更新系统登录项注册与本地偏好存储。
    func toggleLoginItem() {
        loginItemEnabled.toggle()
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册/注销失败时回滚 AppStorage，保持界面与实际一致。
            loginItemEnabled.toggle()
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        restoreLanguagePreference()
        syncLoginItemState()

        // 自动连接：绑定模型引用，启动监控（总开关常开）。
        autoConnectManager.model = self
        autoConnectManager.startMonitoring()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // 间隔是动态的：会话在跑或窗口开着就保持流畅，纯后台待机时放慢。
                try? await Task.sleep(for: self.pollDelay)
            }
        }
        // 心跳：每 3 秒发一次。只在 helper 可用时发送（失败静默）。
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.helperAvailability.isAvailable {
                    await self.client.sendHeartbeat()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        restoreKnownUpdate()
        Task { await checkForUpdatesQuietly() }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 停止心跳定时器。
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// App 完全退出时调用：停轮询、停心跳，并请求 helper 一起退出。
    ///
    /// helper 是 LaunchDaemon，App 退出后它本会继续挂在后台；调用 quit() 可以让
    /// 它先停掉可能正在跑的会话、销毁虚拟网卡，再结束进程。
    func quitHelper() async {
        stopPolling()
        stopHeartbeat()
        _ = try? await client.quit()
    }

    /// 主窗口出现（含从菜单栏重新打开）。
    ///
    /// 立刻刷一次而不是等下一个周期：后台轮询可能正睡在 2 秒的长间隔里，
    /// 用户打开窗口的第一眼不该看到陈旧数据。
    func windowDidAppear() {
        isWindowVisible = true
        Task { await refresh() }
    }

    /// 主窗口关闭。App 转入后台模式，轮询继续（菜单栏靠它喂数据）但会放慢。
    func windowDidDisappear() {
        isWindowVisible = false
    }

    /// 窗口可见性检测：SwiftUI 的 onDisappear 可能在某些竞态场景下不触发
    /// （如窗口被系统关闭、进程被 SIGTERM 后重启），这里做一次兜底检查。
    /// 在 refresh() 中每个周期调用，确保 isWindowVisible 与真实状态一致。
    func checkWindowVisibility() {
        let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && !$0.title.isEmpty }
        if !hasVisibleWindows && isWindowVisible {
            windowDidDisappear()
        } else if hasVisibleWindows && !isWindowVisible {
            windowDidAppear()
        }
    }

    /// 登记「接下来这次主窗口展示是我们主动要求的」。
    ///
    /// App 启动时（初始化默认值）与「打开主窗口」按钮各登记一次。
    func expectWindowPresentation() {
        windowPresentationRequestedAt = ContinuousClock.now
    }

    /// 这次窗口出现是不是我们自己要求的。
    ///
    /// SwiftUI 会在「无窗口的 App 被激活」时（点菜单栏图标就会触发）擅自重建
    /// Window 场景，那种复活必须当场关掉。用时间窗而不是一次性标志来判定：
    /// 「3 秒内登记过」就算数 —— 一次性标志在「窗口已开着时再点打开」这类
    /// 路径上会残留，时间窗天然自愈。
    func isWindowPresentationExpected() -> Bool {
        ContinuousClock.now - windowPresentationRequestedAt < .seconds(3)
    }

    /// 当前该用的轮询间隔。
    ///
    /// 动态降频策略：
    ///   - 窗口可见 + 会话运行中：前 30 秒用 1 秒间隔（快速响应状态转换），
    ///     之后降到 2 秒（会话稳定后人眼对速率刷新频率不敏感，省一半 XPC 往返）
    ///   - 窗口可见 + 空闲：2 秒（用户在看但没有实时数据要展示）
    ///   - 后台 + 会话运行中：2 秒（菜单栏速率文字需要数据，但不需要 1 Hz）
    ///   - 后台 + 空闲：4 秒（唯一产出是 helper 探活与设备扫描）
    private var pollDelay: Duration {
        let sessionActive = status.runState == .running || status.runState.isTransitional

        if isWindowVisible {
            if sessionActive {
                // 会话刚启动的前 30 秒用快节奏，捕获 link-up、IP 分配等瞬态变化；
                // 30 秒后降频，省掉一半的 XPC 往返与 SwiftUI body 重算。
                if let started = sessionStartedAt, Date().timeIntervalSince(started) > 30 {
                    return .seconds(2)
                }
                return Self.pollInterval
            } else {
                // 窗口开着但没有活跃会话：2 秒足够（用户能看到设备列表变化）
                return .seconds(2)
            }
        }

        // 后台模式：会话运行时 2 秒（菜单栏速率），否则 4 秒（探活+设备扫描）
        return sessionActive ? .seconds(2) : Self.backgroundPollInterval
    }

    // MARK: - 轮询

    private func refresh() async {
        // ★ 窗口可见性兜底检测 ★
        // SwiftUI 的 onDisappear 在某些竞态场景下可能不触发（窗口被系统关闭、
        // 进程重启等），这里每周期检查一次，确保 isWindowVisible 与真实状态一致。
        checkWindowVisibility()

        // 快路径：helper 二进制不在预期位置（多半是被系统清理工具删掉了，
        // 本机装了 CleanMyMac 一类软件就可能这么干）。直接判缺失并给出安装引导，
        // 省去 10 秒 XPC 超时干等 —— 否则界面会一直卡在「Checking…」，用户无从下手。
        if !Self.helperBinaryIsInstalled() {
            helperAvailability = .missing(reason: L(.helperBinaryMissing))
            helperVersionMismatch = nil
            return
        }

        // 版本探测只做一次：协议修订号只在 App/helper 更新时才变，没必要每 500 ms
        // 查一次 XPC。已确认可用（或已知协议对不上）就跳过，省一次往返；helper
        // 真挂了，下面的 sessionStatus 会重建连接（见 HelperClient.invalidationHandler）。
        if case .available = helperAvailability {
            // 已确认可用，无需重探。
        } else {
        do {
            let (revision, version) = try await probeHelperVersion()
            guard revision == HelperConstants.protocolRevision else {
                helperAvailability = .outdated(installed: revision,
                                               expected: HelperConstants.protocolRevision)
                // 协议对不上时不再另报版本不一致：那张卡本来就是要用户去更新组件，
                // 同一件事说两遍只会让人怀疑是两个问题。
                helperVersionMismatch = nil
                // 接口对不上就别继续发请求了 —— 参数与应答的形状都可能不一致。
                return
            }
            helperAvailability = .available(version: version)
            helperVersionMismatch = Self.versionMismatch(installed: version)

            // 自动升级：启动时检测到 helper 版本落后于 App 自带的版本，
            // 且当前没有活跃会话 → 静默卸载旧版 + 安装新版，无需用户手动点「更新」。
            //
            // 条件：
            //   1) 本次启动尚未尝试过（防重复）
            //   2) 没有正在跑的会话（升级会断连）
            //   3) 当前不在忙其他操作
            if !helperAutoUpgradeAttempted && status.runState != .running && !isBusy {
                helperAutoUpgradeAttempted = true
                Task { await autoUpgradeHelper() }
            }
        } catch {
            helperAvailability = .missing(reason: error.localizedDescription)
            helperVersionMismatch = nil
            // 连不上就别再发后续请求了 —— 每一个都会重复同样的失败，
            // 只会把日志刷满。
            return
        }
        }  // else（需要重探版本）

        if environment == nil {
            environment = try? await client.environment()
        }

        if let fresh = try? await client.sessionStatus() {
            apply(status: fresh)
        }
        if let feed = try? await client.drainFeed() {
            apply(feed: feed)
        }

        // 设备列表：未运行会话时照常枚举（设备不被独占，列表随插拔更新），
        // 而且刷得比状态慢——枚举要 libusb_open 读描述符，按 500 ms 节奏做等于
        // 每秒开关设备两次，浪费且可能干扰。
        //
        // 例外：**App 启动即发现会话已在跑、而设备列表还空着**——手机早就连上
        // 了，但设备枚举被「运行中不刷」的规矩跳过，列表永远填不进来，会卡在
        // 「无设备」。这时必须从 SessionStatus 构造合成设备（而非调用 listDevices），
        // 因为运行中设备已被 helper 独占，listDevices() 无法枚举到任何设备。
        let mustFillEmpty = status.runState == .running
            && devices.isEmpty
            && !status.deviceMAC.isEmpty

        // 空闲稳定检测：idle/stopped/failed 超过阈值 + 已有设备列表 → 跳过本次枚举。
        // ★ 设备消失时不跳过 ★
        //   旧逻辑只看「设备列表非空」，设备被拔掉后列表变空但 previousDeviceCount > 0，
        //   此时应立即刷新以反映真实状态，而不是等 8 秒。
        let isIdleStable: Bool = {
            guard (status.runState == .idle || status.runState == .stopped || status.runState == .failed),
                  let becameIdleAt = sessionBecameIdleAt,
                  !devices.isEmpty,
                  devices.count == previousDeviceCount else { return false }
            return ContinuousClock.now - becameIdleAt >= Self.idleDeviceSettleDuration
        }()

        if mustFillEmpty {
            // 运行中：从 SessionStatus 构造合成设备 Descriptor，避免调用 listDevices()
            // 导致 UI 在「有设备 ↔ 空列表」之间反复切换。
            let device = DeviceDescriptor(
                vendorID: 0,
                productID: 0,
                busNumber: 255,
                deviceAddress: 255,
                manufacturer: status.vendorDescription,
                product: status.deviceDescription,
                serial: status.deviceMAC,
                summary: "RNDIS: \(status.deviceMAC)",
                usedAndroidQuirk: false
            )
            devices = [device]
        } else if status.runState != .running {
            // 未运行时：正常枚举设备列表
            if shouldRefreshDevices() && !isIdleStable {
                if let fresh = try? await client.listDevices() {
                    // ★ 设备变化检测 ★
                    // 检测设备列表数量变化（插拔），变化时重置空闲计时器，
                    // 确保下一次轮询立即重新枚举，而不是被 idle stable 跳过。
                    let deviceCountChanged = fresh.count != previousDeviceCount
                    devices = fresh
                    previousDeviceCount = fresh.count
                    if deviceCountChanged {
                        // 设备数量变了：重置空闲稳定计时，下一轮立即刷新
                        sessionBecameIdleAt = nil
                    }
                    // 用户选中的设备被拔掉后，选择要跟着失效，否则「启动」会按一个
                    // 不存在的总线地址去找设备。
                    if let selected = selectedDeviceID,
                       !devices.contains(where: { $0.id == selected }) {
                        selectedDeviceID = nil
                    }
                }
            }
        }

        // 网络配置（IP/网关/DNS）走 XPC。接口没变且未到节流间隔时沿用上次结果
        // —— 这些信息在会话期间基本不变，没必要每周期查两次。
        //
        // ★ 抗抖动（修复「connect 后 IP 反复不稳定」）★
        //   1) 接口名短暂为空（connect 早期 feth 还没起、或 link 抖动）时**不**把
        //      已有地址清空，只靠下面的「有效地址不被空结果覆盖」规则维持显示，
        //      避免界面在「有地址 ↔ 没地址」之间反复横跳。
        //   2) queryNetwork 偶发返回空（SCDynamicStore 还没跟上 / 查询竞态）时，
        //      若本地已经有一个有效地址，则保留它，不被瞬时空结果覆盖。
        //   3) 只有会话确实不在运行（idle/stopped/failed）时才清零地址。
        let sessionLive = status.runState == .running || status.runState == .starting
        if !sessionLive {
            networkState = .empty
            networkStateV6 = .empty
            lastNetworkInterfaceQueried = ""
        } else if !status.systemInterface.isEmpty {
            let now = Date()
            let due = now.timeIntervalSince(lastNetworkQueryAt) >= Self.networkQueryIntervalSeconds
            let ifaceChanged = status.systemInterface != lastNetworkInterfaceQueried
            if due || ifaceChanged {
                if let fresh = try? await client.queryNetwork(interface: status.systemInterface) {
                    // 有效地址不被瞬时空结果冲掉；新结果有效、或本地本来就没地址才更新。
                    if fresh.hasAddress || !networkState.hasAddress {
                        networkState = fresh
                    }
                }
                if let freshV6 = try? await client.queryNetworkV6(interface: status.systemInterface) {
                    if freshV6.hasAddress || !networkStateV6.hasAddress {
                        networkStateV6 = freshV6
                    }
                }
                lastNetworkQueryAt = now
                lastNetworkInterfaceQueried = status.systemInterface
            }
        }
        // sessionLive 且接口名暂空：什么都不做，networkState 维持上一次的有效值。
    }

    /// helper 二进制的预期安装路径。不在就说明没装（或被外部删除），
    /// `refresh()` 据此走安装引导，不必等 XPC 超时。
    private static let helperInstallPath =
        "/Library/PrivilegedHelperTools/\(HelperConstants.machServiceName)"

    /// helper 二进制是否还在预期位置。
    private static func helperBinaryIsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: helperInstallPath)
    }

    /// 探测 helper 版本，对 unreachable 做一次重试。
    ///
    /// on-demand 的 LaunchDaemon 在 App 启动首连时可能还没被 launchd 拉起来，
    /// 第一次 XPC 会报 unreachable。等 0.6 秒让 launchd 把服务拉起后再试一次。
    ///
    /// 超时保护在 `HelperClient.invoke()` 里：每个 XPC 调用都有 10 秒保底，
    /// helper 崩溃或死锁时会抛 unreachable，不会无限挂起。
    private func probeHelperVersion() async throws -> (revision: Int, version: String) {
        do {
            return HelperConstants.decodeVersion(try await client.helperVersion())
        } catch let error as HelperClient.Failure where error.isUnreachable {
            try? await Task.sleep(nanoseconds: 600_000_000)
            return HelperConstants.decodeVersion(try await client.helperVersion())
        }
    }


    private func apply(status fresh: SessionStatus) {
        // ★ 变化检测：状态完全相同时跳过更新 ★
        // @Observable 宏追踪所有属性写入，即使值没变也会触发 SwiftUI body 重算。
        // helper 每次轮询都返回相同快照时（空闲、会话稳定运行中），跳过赋值
        // 可以省掉整个视图树的 diff + 重绘 —— 这是 UI 空闲时 CPU 的主要来源。
        //
        // 注意：必须允许「首次调用」（previousStatus == nil）通过，因为需要建立
        // baseline 用于后续的速率差分计算。
        if let prev = previousStatus, fresh == prev { return }

        defer {
            previousStatus = fresh
            status = fresh
        }

        // 记录/清除连接时刻，用于显示已连接时长。
        if fresh.runState == .running, sessionStartedAt == nil {
            sessionStartedAt = Date()
            // 自动应用：只在「本次 App 生命周期内会话从非运行变为运行」时触发。
            //
            // App 启动时若会话已经在跑（previousStatus == nil），则跳过自动应用：
            // 自动应用需要授权，而缓存的授权在 App 退出后已失效；若此时触发，
            // 用户一打开程序就会弹密码框。新连接在 App 运行期间建立时正常自动应用。
            //
            // 使用 allowInteraction: false：自动应用是静默操作，不应主动弹授权框。
            // 若 securityd 有近期缓存则静默成功；无缓存则跳过，用户可手动点 Apply。
            if autoApplyEnabled && !autoAppliedForCurrentSession && previousStatus != nil {
                autoAppliedForCurrentSession = true
                Task { await self.authorized(allowInteraction: false) { authorization in
                    await self.applyNetworkConfiguration()
                } }
            }
            // systemInterface 可用时重试：首次 running 时 interface 可能为空，
            // 导致 applyNetworkConfiguration() 跳过。interface 就绪后再试一次。
            // 兜底处理非 auto-connect 路径（手动 Connect、 rndis-ctl 自动启动等）。
            if fresh.runState == .running,
               !fresh.systemInterface.isEmpty,
               previousStatus?.systemInterface.isEmpty == true,
               autoApplyEnabled && !autoAppliedForCurrentSession {
                autoAppliedForCurrentSession = true
                Task { await self.authorized(allowInteraction: false) { authorization in
                    await self.applyNetworkConfiguration()
                } }
            }
        } else if fresh.runState != .running, fresh.runState != .stopping {
            sessionStartedAt = nil
            autoAppliedForCurrentSession = false
            // 进入空闲/停止/失败状态：记录时刻，用于空闲稳定后停止设备枚举。
            // ★ 只在首次进入时记录，不在每次轮询时重置 —— 否则 now - becameIdleAt
            //   永远 ≈0，8 秒阈值永远达不到，isIdleStable 永远 false，枚举永不停止，
            //   libusb_open/close 每 2 秒触发 macOS 菜单栏 "USB 连接到虚拟机" 图标闪烁。
            if fresh.runState == .idle || fresh.runState == .stopped || fresh.runState == .failed,
               sessionBecameIdleAt == nil {
                sessionBecameIdleAt = ContinuousClock.now
            }
            // ★ 自动错误恢复 ★
            // 首次进入 failed 状态时记录时刻并启动延迟恢复：failed 超过 autoRecoveryDuration
            // 后自动调用 stopSession 重置状态，允许用户重新连接，而不需要手动操作。
            if fresh.runState == .failed, sessionFailedAt == nil {
                sessionFailedAt = ContinuousClock.now
                Task { [weak self] in
                    try? await Task.sleep(for: Self.autoRecoveryDuration)
                    guard let self else { return }
                    // 只有仍然处于 failed 状态时才恢复（用户可能已手动操作）
                    if self.status.runState == .failed {
                        await self.stopSession()
                    }
                    self.sessionFailedAt = nil
                }
            }
        }

        // 离开空闲/停止/失败状态：清除空闲计时，恢复正常枚举节奏。
        if let prev = previousStatus?.runState,
           (prev == .idle || prev == .stopped || prev == .failed),
           !(fresh.runState == .idle || fresh.runState == .stopped || fresh.runState == .failed) {
            sessionBecameIdleAt = nil
            sessionFailedAt = nil
        }

        guard let previous = previousStatus,
              fresh.runState == .running,
              fresh.monotonicNanos > previous.monotonicNanos else {
            if fresh.runState != .running {
                throughput = .zero
            }
            return
        }

        // 分母用库那边的单调时钟差，而不是我们的轮询周期 —— 两次拉取之间的
        // 真实间隔会被调度拉长，用固定周期当分母会把速率算高。
        let seconds = Double(fresh.monotonicNanos - previous.monotonicNanos) / 1_000_000_000
        guard seconds > 0 else { return }

        let sample = ThroughputSample(
            timestamp: Date(),
            receiveBitsPerSecond: Double(fresh.rxBytes &- previous.rxBytes) * 8 / seconds,
            transmitBitsPerSecond: Double(fresh.txBytes &- previous.txBytes) * 8 / seconds,
            receivePacketsPerSecond: Double(fresh.rxFrames &- previous.rxFrames) / seconds,
            transmitPacketsPerSecond: Double(fresh.txFrames &- previous.txFrames) / seconds)

        throughput = sample
        // ★ 后台暂停图表更新 ★
        // 窗口不可见（最小化/隐藏/菜单栏模式）时跳过历史采样：
        //   - throughput 仍更新（菜单栏面板的速率文字需要它）
        //   - 但 throughputHistory 不增长 → Swift Charts 不重绘 → 渲染循环 idle
        // 恢复可见时图表从断点继续，短暂空白用户可接受。
        if isWindowVisible {
            throughputHistory.append(sample)
            if throughputHistory.count > Self.historyCapacity {
                throughputHistory.removeFirst(throughputHistory.count - Self.historyCapacity)
            }
        }
    }

    private func apply(feed: HelperFeed) {
        if !feed.logs.isEmpty {
            logs.append(contentsOf: feed.logs)
            if logs.count > Self.logCapacity {
                logs.removeFirst(logs.count - Self.logCapacity)
            }
            // ★ 增量更新缓存：只处理新增的日志 ★
            // 旧实现每次日志变化都 O(n) 全量重建缓存，是活跃转发时 CPU 38%+ 的
            // 主要来源之一。新实现只遍历 feed 中新增的条目（通常 0~6 条），
            // 增量追加或合并到 cachedFilteredLogs 末尾，复杂度 O(k)。
            // 全量重建仅在缓存超出容量上限时触发（极罕见的安全阀）。
            for entry in feed.logs where entry.level >= logLevelFilter {
                if let last = cachedFilteredLogs.last, last.matches(entry) {
                    cachedFilteredLogs[cachedFilteredLogs.count - 1].absorb(entry)
                } else {
                    cachedFilteredLogs.append(CollapsedLogEntry(entry))
                }
            }
            // 安全阀：缓存异常膨胀时全量重建（正常情况下不会触发）
            if cachedFilteredLogs.count > Self.logCapacity {
                cachedFilteredLogs = rebuildFilteredLogs()
            }
        }
        droppedLogCount += feed.droppedLogs
    }

    /// 全量重建 filteredLogs 缓存。O(n), n ≤ logCapacity(2000)。
    /// 只在日志实际变化或过滤级别切换时调用。
    private func rebuildFilteredLogs() -> [CollapsedLogEntry] {
        var result: [CollapsedLogEntry] = []
        for entry in logs where entry.level >= logLevelFilter {
            if let last = result.last, last.matches(entry) {
                result[result.count - 1].absorb(entry)
            } else {
                result.append(CollapsedLogEntry(entry))
            }
        }
        return result
    }

    // MARK: - 动作

    /// 已连接时长；未连接时为 nil。
    var connectedDuration: TimeInterval? {
        sessionStartedAt.map { Date().timeIntervalSince($0) }
    }

    var selectedDevice: DeviceDescriptor? {
        if let selectedDeviceID {
            return devices.first { $0.id == selectedDeviceID }
        }
        return devices.first
    }

    /// 过滤 + 连续去重后的日志。
    ///
    /// 过滤 + 连续去重后的日志（缓存版）。
    ///
    /// 折叠放在过滤**之后**：原始流里两条相同的 INFO 之间可能夹着 trace，
    /// 按原始顺序折叠会失效，而用户在某个级别下看到的相邻重复才是该合并的。
    ///
    /// **性能关键**：这里直接返回 `cachedFilteredLogs`（O(1)），而不是每次
    /// SwiftUI body 重算都 O(2000) 全量扫描。缓存在 `apply(feed:)` 日志变化时
    /// 更新。用户切换 logLevelFilter 时会触发一次全量重建。
    var filteredLogs: [CollapsedLogEntry] {
        // 检测 logLevelFilter 是否变了（用户点了过滤按钮）—— 需要全量重建。
        // 用一个简单记录上次过滤级别的变量来检测变化，避免每次访问都比较。
        if _lastLogLevelFilter != logLevelFilter {
            _lastLogLevelFilter = logLevelFilter
            cachedFilteredLogs = rebuildFilteredLogs()
        }
        return cachedFilteredLogs
    }

    /// 上次重建缓存时的日志级别过滤器值，用于检测用户切换过滤级别。
    private var _lastLogLevelFilter: LogLevel? = nil

    /// 启动会话。会弹一次系统授权框。
    func startSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        var configuration = SessionConfiguration(mtu: requestedMTU,
                                                 adoptDeviceMAC: adoptDeviceMAC)
        // 指定总线 + 地址而不是 VID/PID：同型号两台设备 VID/PID 完全一样，
        // 只有总线地址能区分。
        if let device = selectedDevice {
            configuration.busNumber = device.busNumber
            configuration.deviceAddress = device.deviceAddress
        }

        await authorized { [self] authorization in
            throughputHistory.removeAll()
            try await client.startSession(authorization: authorization,
                                          configuration: configuration)
        }
    }

    /// 停止会话。
    func stopSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        await authorized { [self] authorization in
            try await client.stopSession(authorization: authorization)
        }
    }

    /// 下发网络配置（IPv4 + IPv6 一并下发）。
    func applyNetworkConfiguration() async {
        guard !isBusy else { return }
        let interface = status.systemInterface
        guard !interface.isEmpty else {
            alertMessage = L(.interfaceNotReadyYet)
            return
        }
        if let message = NetworkValidator.validationMessage(for: networkConfiguration) {
            alertMessage = message
            return
        }
        if let message = NetworkValidator.validationMessageV6(for: networkConfigurationV6) {
            alertMessage = message
            return
        }

        isBusy = true
        defer { isBusy = false }

        await authorized { [self] authorization in
            // IPv4 先走既有路径（DHCP 会阻塞到拿租约，库内上限 10 秒）。
            try await client.applyNetwork(authorization: authorization, interface: interface,
                                          configuration: networkConfiguration)

            // IPv6 随后。两者在 helper 侧共用同一条串行队列，顺序等待即可。
            //
            // 关键：自动配置是「尽力而为」的 —— 对端手机很可能压根不发 RA
            // （运营商没下发 IPv6、或 USB 网络共享只做了 IPv4）。这种情况下等超时是
            // 正常结果，不能让它把已经成功的 IPv4 一起判成失败、弹一个错误框出来。
            // 所以自动配置失败只是「这次没拿到 IPv6 地址」，由回读区如实呈现。
            //
            // 手动配置则相反：用户明确指定了地址，配不上就是真出错，必须报出来。
            do {
                try await client.applyNetworkV6(authorization: authorization, interface: interface,
                                                configuration: networkConfigurationV6)
            } catch {
                if networkConfigurationV6.mode != .automatic {
                    throw error
                }
            }

            // 立刻回读一次，让界面马上反映真实生效的地址，而不用等下一个轮询周期。
            networkState = (try? await client.queryNetwork(interface: interface)) ?? .empty
            networkStateV6 = (try? await client.queryNetworkV6(interface: interface)) ?? .empty
        }
    }

    /// 撤销网卡上的 IP 配置（IPv4 + IPv6 一并撤销）。
    ///
    /// 单独一个动作而不是「上网方式选『不配置』再点应用」：撤销是一次性操作，
    /// 混进模式选择器里会让人以为选中它就已经生效了。
    func clearNetworkConfiguration() async {
        guard !isBusy else { return }
        let interface = status.systemInterface
        guard !interface.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }

        await authorized { [self] authorization in
            try await client.applyNetwork(authorization: authorization, interface: interface,
                                          configuration: NetworkConfiguration(mode: .none))
            try await client.applyNetworkV6(authorization: authorization, interface: interface,
                                            configuration: NetworkConfigurationV6(mode: .none))
            networkState = (try? await client.queryNetwork(interface: interface)) ?? .empty
            networkStateV6 = (try? await client.queryNetworkV6(interface: interface)) ?? .empty
        }
    }

    /// 手动刷新设备列表（界面上的刷新按钮）。
    ///
    /// 手动触发时不受节流限制 —— 用户点了按钮就是想立刻看到结果。
    ///
    /// ★ 运行中会话的特别处理 ★
    ///   当会话正在运行时，设备已被 helper 独占，listDevices() 无法枚举到
    ///   任何设备（libusb_open 失败）。此时直接清空列表会导致 UI 闪烁，
    ///   因为下一次 poll 又会从 SessionStatus 重新构造合成设备。
    ///   改为：运行时从 SessionStatus 构造合成设备 Descriptor，保持列表稳定。
    func refreshDevices() async {
        lastDeviceRefresh = .now
        if status.runState == .running {
            // 运行中：listDevices() 会返回空（设备被 helper 独占），
            // 用 SessionStatus 中的信息构造合成设备 Descriptor。
            guard !status.deviceMAC.isEmpty else { return }
            // 如果已经存在相同的合成设备（busNumber=255），跳过赋值，
            // 避免每 2 秒刷新定时器反复触发 @Observable 重绘。
            if devices.first?.busNumber == 255,
               devices.first?.serial == status.deviceMAC {
                return
            }
            let device = DeviceDescriptor(
                vendorID: 0,
                productID: 0,
                busNumber: 255,
                deviceAddress: 255,
                manufacturer: status.vendorDescription,
                product: status.deviceDescription,
                serial: status.deviceMAC,
                summary: "RNDIS: \(status.deviceMAC)",
                usedAndroidQuirk: false
            )
            devices = [device]
            return
        }
        devices = (try? await client.listDevices()) ?? []
    }

    /// 轻量级设备枚举：只返回列表，不更新模型状态。
    ///
    /// 供 AutoConnectManager 轮询 RNDIS 设备用，避免干扰主界面的设备列表。
    func probeDevices() async -> [DeviceDescriptor] {
        (try? await client.listDevices()) ?? []
    }

    /// 距上次枚举是否已经够久。顺带记下这一次的时刻。
    private func shouldRefreshDevices() -> Bool {
        let now = ContinuousClock.now
        if let last = lastDeviceRefresh, now - last < Self.deviceRefreshInterval {
            return false
        }
        lastDeviceRefresh = now
        return true
    }

    func clearLogs() {
        logs.removeAll()
        droppedLogCount = 0
    }

    /// App 自带的库版本 —— 「特权组件应该是哪一版」的标准答案。
    ///
    /// 用**库**的版本而不是 Info.plist 里的 App 版本号：装到
    /// /Library/PrivilegedHelperTools 的正是 .app 里那份 libtetherkit 的拷贝
    /// （见 build-gui.sh 组装载荷那段），两边同源才比得准。而且 `swift run`
    /// 的裸可执行文件根本没有 bundle，读 Info.plist 那条路上这个判断会整个失效。
    ///
    /// 敢用 `static let` 缓存是因为它是编译期烧进 dylib 的常量，进程活着的时候
    /// 不会变 —— 与上面几个必须跟着语言走的提示语不同。顺手把版本号提取也
    /// 做掉：这个判断挂在 500 ms 一次的轮询上，没必要每次都重跑一遍正则。
    private static let bundledVersion =
        HelperConstants.semanticVersion(of: TetherKitLibrary.versionInfo.version)

    /// 装着的组件和 App 自带的是不是同一版。一致时返回 nil。
    private static func versionMismatch(installed: String) -> HelperVersionMismatch? {
        let installedVersion = HelperConstants.semanticVersion(of: installed)
        guard installedVersion != bundledVersion else { return nil }
        return HelperVersionMismatch(installed: installedVersion, expected: bundledVersion)
    }

    /// 安装 / 更新特权组件（引导卡上的「一键安装」按钮，以及版本对不上时
    /// 管理行里的「更新特权组件」—— 更新就是照着 .app 里的载荷重装一遍）。
    func installHelper() async {
        await maintainHelper(.install, prompt: Self.helperInstallPrompt,
                             expectAvailable: true,
                             failureNotice: L(.installScriptRanButUnreachable))
    }

    /// 卸载特权组件（仪表盘底部的「卸载…」，确认框在 UI 层）。
    ///
    /// bootout 给 helper 发 SIGTERM —— 正在跑的会话被优雅停掉、虚拟网卡销毁，
    /// 这一点必须在确认框里向用户说明。卸载完成后界面自然回到安装引导页。
    func uninstallHelper() async {
        await maintainHelper(.uninstall, prompt: Self.helperUninstallPrompt,
                             expectAvailable: false,
                             failureNotice: L(.uninstallScriptRanButStillAlive))
    }

    /// 启动时自动升级 helper：检测到版本不一致时，静默卸载旧版 + 安装新版。
    ///
    /// 只在「无活跃会话 + 不忙」时触发（见 refresh() 里的守卫条件）。
    /// install-helper.sh 内部已包含「先 bootout 旧服务再覆盖文件」的逻辑，
    /// 所以这里只需调 installHelper() 即可完成完整的卸载→安装流程。
    private func autoUpgradeHelper() async {
        isAutoUpgradingHelper = true
        defer { isAutoUpgradingHelper = false }
        await installHelper()
        // installHelper 成功后，下一轮 refresh() 会重新探测版本，
        // helperVersionMismatch 应该变为 nil（版本一致了）。
        // 如果仍然不一致（安装失败），用户仍可手动点更新按钮。
    }

    /// 安装与卸载共用的执行壳：授权（复用缓存令牌）→ AEWP 执行 → XPC 探测
    /// 兜底确认。
    ///
    /// 授权与日常特权操作共用同一条权利（system.privilege.admin），令牌缓存
    /// 因此天然通用：装完 5 分钟内接着点「连接」不会再弹框。缓存令牌已过期的
    /// 罕见路径由 AEWP 自己弹系统默认文案的框兜底，不为它专造一次「带自定义
    /// 文案的重新授权」。
    ///
    /// ★ 成败判定 ★
    ///   AEWP 不给退出码（见 HelperInstaller 的说明），所以脚本跑完后用真实的
    ///   XPC 往返确认，兜几秒等 launchd 完成登记与按需拉起（或注销生效）。
    ///   方向由 expectAvailable 决定：安装等「连得上」，卸载等「连不上」。
    ///   失败时把脚本输出的末尾放进弹窗 —— 真实原因几乎总写在结尾。
    private func maintainHelper(_ action: HelperInstaller.Action,
                                prompt: String,
                                expectAvailable: Bool,
                                failureNotice: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // 载荷与 AEWP 先行自检 —— 缺哪样都必须在弹授权框**之前**说清楚。
        if let failure = HelperInstaller.preflightError() {
            alertMessage = failure.localizedDescription
            return
        }

        let output: String
        do {
            let token: AuthorizationToken
            if let cached = cachedAuthorization {
                token = cached
            } else if let saved = CredentialStore.load(),
                      let passwordToken = try? AuthorizationBroker.requestAuthorization(password: saved) {
                // 钥匙串里有密码：静默取得，安装也免弹框。
                token = passwordToken
                cachedAuthorization = token
            } else {
                token = try AuthorizationBroker.requestAuthorization(prompt: prompt)
                cachedAuthorization = token
            }
            defer { withExtendedLifetime(token) {} }
            output = try await HelperInstaller.run(action, with: token)
        } catch AuthorizationBroker.Failure.userCancelled {
            return
        } catch HelperInstaller.Failure.userCancelled {
            return
        } catch {
            alertMessage = error.localizedDescription
            return
        }

        for _ in 0..<6 {
            await refresh()
            if helperAvailability.isAvailable == expectAvailable { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        alertMessage = L(.scriptOutput, failureNotice, Self.tail(of: output))
    }

    // MARK: - 检查更新

    /// 手动检查（App 菜单「检查更新…」）。结果无论好坏都弹窗。
    func checkForUpdates() async {
        guard let current = UpdateChecker.currentVersion else {
            updateCheckResult = .unavailable
            return
        }
        do {
            let latest = try await UpdateChecker.fetchLatestRelease()
            remember(latest)
            if UpdateChecker.isNewer(latest.version, than: current) {
                availableUpdate = latest
                updateCheckResult = .updateAvailable(latest)
            } else {
                availableUpdate = nil
                updateCheckResult = .upToDate(current: current)
            }
        } catch {
            updateCheckResult = .failed(error.localizedDescription)
        }
    }

    /// 自动检查：每天至多一次、失败静默、发现新版只点亮管理行的提示，
    /// 绝不弹窗打断 —— 更新是「顺便知道」的事，不值得一个模态框。
    /// `defaults write com.tetherkit.app updateCheckDisabled -bool YES` 可关掉。
    private func checkForUpdatesQuietly() async {
        guard let current = UpdateChecker.currentVersion else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.updateCheckDisabledKey) else { return }
        if let last = defaults.object(forKey: Self.updateLastCheckedKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }

        guard let latest = try? await UpdateChecker.fetchLatestRelease() else { return }
        defaults.set(Date(), forKey: Self.updateLastCheckedKey)
        remember(latest)
        availableUpdate = UpdateChecker.isNewer(latest.version, than: current) ? latest : nil
    }

    /// 把查到的最新版记进 defaults —— 明天的启动被节流拦住时，提示不该消失。
    private func remember(_ release: UpdateChecker.Release) {
        let defaults = UserDefaults.standard
        defaults.set(release.version, forKey: Self.updateKnownVersionKey)
        defaults.set(release.pageURL.absoluteString, forKey: Self.updateKnownPageKey)
    }

    /// 启动时恢复上次查到的新版提示。升级完成后（当前版本 ≥ 记住的版本）
    /// 自然失效，不需要任何清理逻辑。
    private func restoreKnownUpdate() {
        guard let current = UpdateChecker.currentVersion,
              let version = UserDefaults.standard.string(forKey: Self.updateKnownVersionKey),
              let page = UserDefaults.standard.string(forKey: Self.updateKnownPageKey),
              let pageURL = URL(string: page),
              UpdateChecker.isNewer(version, than: current) else { return }
        availableUpdate = UpdateChecker.Release(version: version, pageURL: pageURL)
    }

    private static let updateCheckDisabledKey = "updateCheckDisabled"
    private static let updateLastCheckedKey = "updateLastCheckedAt"
    private static let updateKnownVersionKey = "updateKnownVersion"
    private static let updateKnownPageKey = "updateKnownPageURL"

    /// 取输出的末尾几行给弹窗用 —— 完整输出可能很长，真实原因几乎总在结尾。
    /// 顺手剥掉脚本里的 ANSI 颜色码，弹窗里那是乱码。
    private static func tail(of output: String,
                             maxLines: Int = 10, maxCharacters: Int = 700) -> String {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "",
                                                options: .regularExpression)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: true)
        var kept = lines.suffix(maxLines).joined(separator: "\n")
        if kept.count > maxCharacters {
            kept = String(kept.suffix(maxCharacters))
        }
        return kept.isEmpty ? L(.scriptNoOutput) : kept
    }

    /// 带着授权凭据执行一次特权操作，优先静默（不弹框），必要时才弹系统授权框。
    ///
    /// ★ 为什么静默优先能大幅减少弹框 ★
    ///
    ///   macOS 的 securityd 会在登录会话内缓存近期成功的管理员认证（类似 sudo
    ///   的 5 分钟窗口）。只要用户在本会话中最近输入过密码——无论是给 TetherKit、
    ///   终端 sudo 还是任何其他工具——不带 .interactionAllowed 的
    ///   AuthorizationCopyRights 就可以直接命中缓存，不弹任何 UI。
    ///
    ///   旧代码每次都带 .interactionAllowed（「必须弹框」），所以即使 securityd
    ///   有缓存也会弹。改成静默优先后：
    ///     * 同一会话内刚输过密码 → 静默命中，零弹框
    ///     * 缓存过期（~5分钟无管理员操作）→ 回退到交互式授权，弹一次框
    ///     * App 重启后若缓存仍有效 → 同样静默命中
    ///
    /// ★ 令牌缓存（cachedAuthorization）仍然保留 ★
    ///   它覆盖的是同一 ref 上的 5 分钟窗口：第一次操作取到令牌后，后续操作在
    ///   令牌有效期内连静默查询都不用做，直接复用。两层机制叠加：
    ///   令牌缓存 → 静默查询 → 交互式弹框，逐级降级。
    ///
    /// 用户取消时**不**弹错误提示 —— 取消是正常操作，再弹一个「已取消」的框
    /// 只会烦人。
    private func authorized(allowInteraction: Bool = true,
                            _ body: @escaping (Data) async throws -> Void) async {
        // 第一趟：有缓存就直接用，不打扰用户。
        if let cached = cachedAuthorization {
            defer { withExtendedLifetime(cached) {} }
            do {
                try await body(cached.externalForm)
                return
            } catch let failure as HelperClient.Failure where failure.isAuthorizationProblem {
                // 凭据过期了。丢掉缓存，往下走「重新授权 + 重试」。
                cachedAuthorization = nil
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }

        // 第二趟起：拿授权凭据。优先用钥匙串里存的密码静默取得；
        // 存的不对或没有，再回到 TetherKit 自己的密码框（用户现输一次）。
        var lastAttemptFailed = false
        while true {
            // 钥匙串里有密码：静默试一次，正确就直接用并把令牌缓存起来。
            if let saved = CredentialStore.load(),
               let token = try? AuthorizationBroker.requestAuthorization(password: saved) {
                cachedAuthorization = token
                defer { withExtendedLifetime(token) {} }
                do {
                    try await body(token.externalForm)
                    return
                } catch let failure as HelperClient.Failure where failure.isAuthorizationProblem {
                    // 凭据被 helper 判为过期（极少）—— 清缓存重试。
                    cachedAuthorization = nil
                } catch {
                    alertMessage = error.localizedDescription
                    return
                }
            }

            // 走到这里说明：钥匙串里没有密码，或存的密码已经失效。
            // 没有交互权限（自动应用）就直接放弃，不弹框 —— 用户可手动点 Apply。
            guard allowInteraction else { return }

            // 失效的那条清掉，避免下次启动又用错误的试一次。
            CredentialStore.delete()

            // 弹 TetherKit 自己的密码框让用户现输一次（失败过就带「不正确」提示）。
            // 取消则放弃本次授权，连接/应用照常跳过（可手动触发系统授权框）。
            let entered = await requestPasswordFromUser(retry: lastAttemptFailed)
            guard let entered, !entered.isEmpty else { return }

            // 用刚输的密码静默取得授权。
            guard let token = try? AuthorizationBroker.requestAuthorization(password: entered) else {
                // 密码不对：记下来，下一轮带着「不正确」的提示再弹，让用户改。
                // 用户可随时取消退出循环。
                lastAttemptFailed = true
                continue
            }
            // 密码对了：落盘钥匙串（下次启动自动加载），缓存令牌并继续。
            CredentialStore.save(entered)
            cachedAuthorization = token
            defer { withExtendedLifetime(token) {} }
            do {
                try await body(token.externalForm)
                return
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
    }

    /// 弹出 TetherKit 自己的密码框，等用户提交或取消，返回密码或 nil（取消）。
    ///
    /// 必须是 AppModel 自己收密码、而不是复用系统授权框：系统框的返回值里
    /// 根本没有密码，我们拿不到可落盘的凭据；只有自己收一次，才能把密码存进
    /// 钥匙串、实现「下次启动自动加载」。
    private func requestPasswordFromUser(retry: Bool) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.credentialContinuation = cont
            // 重置框内状态，避免上一次输入残留。
            self.credentialPassword = ""
            self.credentialSubmitting = false
            self.credentialCancelling = false
            self.credentialPrompt = CredentialPromptState(
                title: L(.credentialPromptTitle),
                message: retry ? L(.credentialWrongMessage) : L(.credentialPromptMessage))
        }
    }

    /// 用户在密码框里点了「确定」：把密码交出去，由上面的静默授权路径判断对不对 ——
    /// 不对就带着重试文案再次弹出。
    func submitCredential(_ password: String) {
        let cont = credentialContinuation
        credentialContinuation = nil
        credentialPrompt = nil
        credentialPassword = ""
        credentialSubmitting = false
        credentialCancelling = false
        cont?.resume(returning: password)
    }

    /// 用户取消密码框：当次不授权。已存的失效密码顺手清掉，免得下次启动又试一次。
    func cancelCredential() {
        let cont = credentialContinuation
        credentialContinuation = nil
        credentialPrompt = nil
        credentialPassword = ""
        credentialSubmitting = false
        credentialCancelling = false
        cont?.resume(returning: nil)
    }
}
