import Foundation
import TetherKitCore
import TetherKitIPC

/// helper 的 XPC 服务实现。
///
/// ★ 线程模型 ★
///
///   XPC 的方法在连接自己的队列上被调用。凡是可能耗时的操作（启动会话要做 USB
///   握手、DHCP 要等租约）都**立刻派发到自己的串行队列并异步回复**，绝不在
///   XPC 队列上阻塞 —— 否则同一条连接上后续的状态轮询会被一起卡住，界面表现
///   成「整个卡死」。
///
///   会话生命周期与网卡配置各用一条串行队列：两者互不阻塞，但各自内部严格串行
///   （并发的 start/stop 或并发的 ipconfig 都是灾难）。状态查询不排队，直接打到
///   C 层 —— 那边的快照本来就是线程安全的。
final class HelperService: NSObject, TetherKitHelperProtocol {
    private let lifecycleQueue = DispatchQueue(label: "com.tetherkit.helper.lifecycle")
    private let networkQueue = DispatchQueue(label: "com.tetherkit.helper.network")

    /// 保护 session 与 notices。持有时间都极短，用普通锁足够。
    private let stateLock = NSLock()
    private var session: TetherKitSession?
    /// startSession 正在构造 / 握手中。这段窗口里 session 还没登记，但设备
    /// **已经**被本进程打开了 —— 枚举的占用判定必须把它算进去，否则字符串
    /// 读取会往握手中的控制端点再插一笔传输。
    private var sessionStarting = false
    /// 尚未被 App 取走的提示。
    private var pendingNotices: [String] = []

    /// 最后一次收到 XPC 调用或会话状态变更的时刻，用于空闲自退出。
    private let idleLock = NSLock()
    private var lastActivity = Date()

    /// 无会话运行且无 XPC 活动时，经过多久自动退出（秒）。
    private static let idleTimeout: TimeInterval = 60

    // MARK: - 心跳检测

    /// 最后一次收到 GUI 心跳的时刻。
    private let heartbeatLock = NSLock()
    private var lastHeartbeat = Date()

    /// 连续未收到心跳多少秒后判定 GUI 已死、helper 自行退出（秒）。
    ///
    /// 取值需大于 GUI 的心跳发送间隔（3 秒），留出网络抖动和调度延迟的余量。
    /// 10 秒意味着 GUI 要连续丢失 3~4 个心跳才会触发退出——足够区分
    /// 「真的崩了」和「暂时卡顿」。
    private static let heartbeatTimeout: TimeInterval = 10

    /// 心跳超时检查是否已启动（避免重复调度）。
    private var heartbeatCheckScheduled = false

    /// 当前连上来的 App 连接。helper 仅服务 TetherKit 一个客户端，理论上同时
    /// 只有一条；但 App 崩溃重启时旧连接先失效、新连接紧接着来，会短暂出现两条。
    /// 用 ObjectIdentifier 做键，因为 NSXPCConnection 本身不可 Hash。
    private let connectionLock = NSLock()
    private var clientConnectionIDs = Set<ObjectIdentifier>()

    /// App 连接全部断开后，延迟多久再拆除会话并退出（秒）。
    ///
    /// 留出宽限是为了兼容 App 的「崩溃后立即重启」：旧连接失效会触发拆除流程，
    /// 但新连接若在宽限内到达就该取消，而不是把一个正要重连的 App 的 helper 杀掉。
    private static let clientGoneGraceSeconds: TimeInterval = 2

    /// App 连接断开后待执行的「拆除 + 退出」任务。新连接到达时取消它。
    private var pendingExitWorkItem: DispatchWorkItem?

    // MARK: - 不需要授权的探测接口

    func helperVersion(reply: @escaping (String) -> Void) {
        bumpActivity()
        // 带上 XPC 接口修订号，让 App 能发现「helper 是升级前的旧版本」。
        reply(HelperConstants.encodeVersion(TetherKitLibrary.versionInfo.version))
    }

    func environment(reply: @escaping (Data?, String?) -> Void) {
        bumpActivity()
        respond(with: TetherKitLibrary.checkEnvironment(), reply: reply)
    }

    func listDevices(reply: @escaping (Data?, String?) -> Void) {
        bumpActivity()
        // 设备被本进程持有期间不读字符串描述符：读要 libusb_open，白白失败一遍，
        // 还会往正在握手的控制端点插传输。判定用「真的持有」而不是「session
        // 非 nil」—— failed / stopped 的死会话早就把 USB 拆干净了，把它们也算
        // 「占用」会让设备拔掉重插后一直读不到名字。
        // 跳过不会丢名字：C 层会回填上次成功读到的值（见 environment.cc）。
        let deviceHeld = stateLock.withLock { () -> Bool in
            if sessionStarting { return true }
            guard let session else { return false }
            switch session.status().runState {
            case .starting, .running, .stopping: return true
            case .idle, .stopped, .failed: return false
            }
        }
        do {
            let devices = try TetherKitLibrary.listDevices(readStrings: !deviceHeld)
            respond(with: devices, reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func sessionStatus(reply: @escaping (Data?, String?) -> Void) {
        bumpActivity()
        let status = withState { $0?.status() } ?? .idle
        // 顺带把会话事件收进提示队列 —— 状态轮询本来就是每个刷新周期一次，
        // 搭车过来不用多一次 XPC 往返。
        if let notices = withState({ $0?.drainNotices() }), !notices.isEmpty {
            appendNotices(notices)
        }
        respond(with: status, reply: reply)
    }

    func queryNetwork(interface: String, reply: @escaping (Data?, String?) -> Void) {
        bumpActivity()
        do {
            respond(with: try NetworkConfigurator.query(interface: interface), reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func applyNetworkV6(authorization: Data, interface: String, configuration: Data,
                       reply: @escaping (String?, Bool) -> Void) {
        bumpActivity()
        guard let configuration = decode(NetworkConfigurationV6.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }
        if let message = NetworkValidator.validationMessageV6(for: configuration) {
            reply(message, false)
            return
        }

        networkQueue.async { [weak self] in
            do {
                try NetworkConfigurator.applyV6(configuration, to: interface)
                self?.appendNotices([L(.helperNetworkApplied, configuration.mode.displayName)])
                reply(nil, false)
            } catch {
                reply(error.localizedDescription, false)
            }
        }
    }

    func queryNetworkV6(interface: String, reply: @escaping (Data?, String?) -> Void) {
        bumpActivity()
        do {
            respond(with: try NetworkConfigurator.queryV6(interface: interface), reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func drainFeed(reply: @escaping (Data?) -> Void) {
        bumpActivity()
        let drained = TetherKitLibrary.drainLogs()
        let notices = takeNotices()
        let feed = HelperFeed(logs: drained.entries, droppedLogs: drained.dropped, notices: notices)
        reply(try? JSONEncoder().encode(feed))
    }

    func setLanguage(_ rawValue: String, reply: @escaping () -> Void) {
        bumpActivity()
        // 认不出来就保持原样。宁可继续用上一种语言，也不要因为 App 传了个新值
        // 就退回默认 —— 那会表现成「切了个语言，helper 的日志反而变回英文」。
        if let language = Language(rawValue: rawValue) {
            L10n.apply(language == .chinese ? .chinese : .english)
            TetherKitLibrary.setLanguage(language)
        }
        reply()
    }

    // MARK: - 需要授权的特权接口

    func startSession(authorization: Data, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void) {
        bumpActivity()
        guard let configuration = decode(SessionConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }

        lifecycleQueue.async { [weak self] in
            guard let self else { return }

            // 已经彻底死掉（失败 / 已停）的旧会话不能挡住新的连接。
            //
            // 典型场景：设备被拔掉 → 保活连续失败 → 会话进入 failed。C++ 侧
            // 此时已经把 USB、网卡全部拆干净了，Swift 这层只剩一个壳 —— 但它
            // 非 nil。若只按「session != nil 就拒绝」，用户重插设备后永远
            // 连不上，只能重装 helper。这个坑真实踩过。
            if let existing = self.withState({ $0 }) {
                let state = existing.status().runState
                guard state == .failed || state == .stopped else {
                    reply(L(.helperSessionAlreadyRunning), false)
                    return
                }
                existing.stop()  // 幂等，只是保险
                self.stateLock.withLock { self.session = nil }
            }

            // 从构造到 start() 返回的整个握手期间把「设备已被持有」亮出来，
            // 让并发到来的 listDevices 跳过字符串读取（见那边的说明）。
            self.stateLock.withLock { self.sessionStarting = true }
            defer { self.stateLock.withLock { self.sessionStarting = false } }
            do {
                let session = try TetherKitSession(configuration: configuration)
                try session.start()
                self.stateLock.withLock { self.session = session }
                reply(nil, false)
            } catch {
                reply(error.localizedDescription, false)
            }
        }
    }

    func stopSession(authorization: Data, reply: @escaping (String?, Bool) -> Void) {
        bumpActivity()
        guard authorize(authorization, reply: reply) else { return }

        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            // 先把 session 从状态里摘出来再停：停机要 join 控制线程、可能耗时
            // 数百毫秒，期间不该继续对外声称「会话在运行」。
            let session = self.stateLock.withLock { () -> TetherKitSession? in
                defer { self.session = nil }
                return self.session
            }
            session?.stop()
            self.appendNotices([L(.helperSessionStopped)])
            reply(nil, false)
        }
    }

    func applyNetwork(authorization: Data, interface: String, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void) {
        bumpActivity()
        guard let configuration = decode(NetworkConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }
        // 界面已经校验过一遍，但 XPC 是任何本机进程都能连的，helper 必须自己再挡
        // 一道 —— 而且用的是同一份规则，不会出现两边判断不一致。
        if let message = NetworkValidator.validationMessage(for: configuration) {
            reply(message, false)
            return
        }

        // DHCP 会阻塞到拿到租约（库内部上限 10 秒），所以必须异步回复。
        networkQueue.async { [weak self] in
            do {
                try NetworkConfigurator.apply(configuration, to: interface)
                self?.appendNotices([L(.helperNetworkApplied, configuration.mode.displayName)])
                reply(nil, false)
            } catch {
                reply(error.localizedDescription, false)
            }
        }
    }

    // MARK: - 停机清理

    /// App 请求 helper 优雅停机并退出进程。**不要求授权。**
    ///
    /// 先回复再退出：给 XPC 一帧时间把 reply 发出去。实际 Mach 消息大概率已经
    /// 在路上了，0.05 秒的延迟只是兜底。
    func quit(reply: @escaping () -> Void) {
        bumpActivity()
        reply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.gracefulExit(reason: "quit requested by GUI")
        }
    }

    /// 收到 GUI 心跳。**不要求授权**。
    ///
    /// 每次调用都刷新心跳时钟，并启动超时检查（若尚未启动）。
    func heartbeat(reply: @escaping () -> Void) {
        bumpActivity()
        heartbeatLock.withLock { lastHeartbeat = Date() }
        if !heartbeatCheckScheduled {
            heartbeatCheckScheduled = true
            scheduleHeartbeatCheck()
        }
        reply()
    }

    /// 收到 SIGTERM（`launchctl bootout`）时调用。
    ///
    /// Swift 的 deinit 在进程被终止时不会跑，不主动停一下就会把 feth 网卡漏在
    /// 内核里。落盘登记能兜住 SIGKILL，但能优雅退出时还是该优雅退出 ——
    /// 那样连「下次启动清理」这一步都省了。
    func shutdown() {
        let session = stateLock.withLock { () -> TetherKitSession? in
            defer { self.session = nil }
            return self.session
        }
        session?.stop()
    }

    /// 统一退出路径：先断开连接（销毁 feth 网卡），再退出进程。
    ///
    /// 所有退出入口（quit / heartbeat-timeout / orphan / SIGTERM）都汇聚到这里，
    /// 确保资源清理顺序一致：disconnect → cleanup → exit。
    func gracefulExit(reason: String) {
        writeToStandardError("TetherKit helper exiting: \(reason)")
        // 第一步：断开会话 —— 这会触发 Runtime::Teardown()，
        // 内部执行 SIOCIFDESTROY 销毁 feth0/feth1。
        shutdown()
        // 第二步：退出进程。
        exit(0)
    }

    /// 启动空闲自退出检查。
    ///
    /// helper 作为 LaunchDaemon 按需拉起，没会话运行时还一直挂着对用户没意义；
    /// 之前 RX injector 忙等待的 bug 也让我们学到「后台 helper 可能烧 CPU」。
    /// 这里设一个 60 秒空闲超时：无会话运行且 60 秒没有任何 XPC 调用时主动退出。
    func scheduleIdleTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout) { [weak self] in
            self?.checkIdleTimeout()
        }
    }

    private func checkIdleTimeout() {
        let sessionRunning = stateLock.withLock {
            guard let session else { return false }
            switch session.status().runState {
            case .running, .starting, .stopping: return true
            case .idle, .stopped, .failed: return false
            }
        }
        let idle = idleLock.withLock { Date().timeIntervalSince(lastActivity) }

        if !sessionRunning && idle >= Self.idleTimeout {
            writeToStandardError("TetherKit helper idle timeout reached; exiting.")
            gracefulExit(reason: "idle timeout (\(Self.idleTimeout)s no activity)")
        }

        // 还不该退，继续下一轮检查。
        scheduleIdleTimeout()
    }

    // MARK: - 心跳超时检查

    /// 启动心跳超时检查循环。
    func scheduleHeartbeatCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.heartbeatTimeout) { [weak self] in
            self?.checkHeartbeatTimeout()
        }
    }

    private func checkHeartbeatTimeout() {
        let elapsed = heartbeatLock.withLock { Date().timeIntervalSince(lastHeartbeat) }

        if elapsed >= Self.heartbeatTimeout {
            // 连续 N 秒未收到心跳 → GUI 已死。执行 disconnect → cleanup → exit。
            writeToStandardError("TetherKit helper: no heartbeat for \(Int(elapsed))s; assuming GUI is gone.")
            gracefulExit(reason: "heartbeat timeout (\(Int(elapsed))s >= \(Self.heartbeatTimeout)s)")
            return  // exit(0) 已执行，不会回来
        }

        // 心跳还在，继续下一轮检查。
        scheduleHeartbeatCheck()
    }

    // MARK: - 客户端连接生命周期

    /// App 建立了一条新 XPC 连接。
    func clientConnectionDidConnect(_ connection: NSXPCConnection) {
        connectionLock.withLock {
            clientConnectionIDs.insert(ObjectIdentifier(connection))
            // 有新连接 → 取消「全断开后退出」的待定任务。
            pendingExitWorkItem?.cancel()
            pendingExitWorkItem = nil
        }
        bumpActivity()
    }

    /// App 的 XPC 连接失效（App 退出 / 崩溃 / 强杀 / 窗口关闭后进程终止）。
    ///
    /// ★ 这是修掉「helper 残留 + 残留期间高 CPU + feth 网卡不清理」的关键 ★
    ///
    /// 此前 helper 只有两条退出路径：App 显式调 `quit()`，或「无会话运行时」的
    /// 60 秒空闲自退。若 App 在会话运行中崩溃/被强杀，这两条都不会触发 ——
    /// 于是带着活跃数据路径的 helper 常驻后台，烧 CPU 且把 feth 网卡漏在内核里。
    ///
    /// 接住连接失效后：先等到宽限期满，若期间没有新连接来（即 App 真的走了），
    /// 就拆除会话（顺带销毁 feth0/feth1）并退出进程。
    func clientConnectionDidInvalidate(_ connection: NSXPCConnection) {
        let stillConnected: Bool = connectionLock.withLock {
            clientConnectionIDs.remove(ObjectIdentifier(connection))
            return !clientConnectionIDs.isEmpty
        }
        if stillConnected {
            return  // 还有别的连接（极少见的并发场景），不退出
        }

        connectionLock.withLock { pendingExitWorkItem?.cancel() }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.connectionLock.withLock { self.pendingExitWorkItem = nil }
            writeToStandardError(L(.helperClientGoneExiting))
            self.gracefulExit(reason: "all XPC connections gone (\(Self.clientGoneGraceSeconds)s grace)")
        }
        connectionLock.withLock { pendingExitWorkItem = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.clientGoneGraceSeconds,
                                          execute: item)
    }

    // MARK: - 内部工具

    /// 记录一次 XPC 活动，用于空闲自退出计时。
    private func bumpActivity() {
        idleLock.withLock { lastActivity = Date() }
    }

    /// 复核授权；不通过时回复错误并把第二个参数置为 true，告诉 App
    /// 「这是授权问题，重新弹框再来一次也许就成了」。
    private func authorize(_ data: Data, reply: @escaping (String?, Bool) -> Void) -> Bool {
        do {
            try AuthorizationVerifier.verify(externalForm: data)
            return true
        } catch {
            reply(error.localizedDescription, true)
            return false
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                      reply: @escaping (String?, Bool) -> Void) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            reply(L(.helperRequestDecodeFailed, error.localizedDescription), false)
            return nil
        }
    }

    private func respond<T: Encodable>(with value: T, reply: (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, L(.helperReplyEncodeFailed, error.localizedDescription))
        }
    }

    private func withState<T>(_ body: (TetherKitSession?) -> T) -> T {
        stateLock.withLock { body(session) }
    }

    private func appendNotices(_ notices: [String]) {
        guard !notices.isEmpty else { return }
        stateLock.withLock {
            pendingNotices.append(contentsOf: notices)
            // 上限 200：App 若长时间不来取（比如被挂起），不该让它无限增长。
            if pendingNotices.count > 200 {
                pendingNotices.removeFirst(pendingNotices.count - 200)
            }
        }
    }

    private func takeNotices() -> [String] {
        stateLock.withLock {
            defer { pendingNotices.removeAll() }
            return pendingNotices
        }
    }
}

/// XPC 监听器代理。
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // ★ 为什么这里无条件接受 ★
        //
        //   安全性不建立在「谁能连上」，而建立在「每次特权调用都要附带一份用户刚
        //   确认过的授权凭据」。这是刻意的选择：另一条路是校验调用方的代码签名
        //   （SMJobBless 的做法），但那依赖证书的 designated requirement，而源码
        //   分发下每台机器编出的 cdhash 都不同，写死的 DR 必然对不上。
        //
        //   对开源、源码分发的工具，凭据复核是更合适的模型：谁编译的都一样安全。
        connection.exportedInterface = NSXPCInterface(with: TetherKitHelperProtocol.self)
        connection.exportedObject = service

        // 接住连接失效：App 退出 / 崩溃 / 强杀时，libxpc 会通过死端口通知触发它。
        // 这是 helper 能感知「自己的唯一客户端走了」的唯一途径 —— 否则会话运行
        // 中 App 一死，helper 就带着活跃数据路径常驻，烧 CPU 且漏掉 feth 网卡。
        connection.invalidationHandler = { [weak service] in
            service?.clientConnectionDidInvalidate(connection)
        }

        connection.resume()
        service.clientConnectionDidConnect(connection)
        return true
    }
}
