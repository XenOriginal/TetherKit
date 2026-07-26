#include "tetherkit/core/runtime.h"

#include <algorithm>
#include <chrono>
#include <ranges>
#include <format>
#include <thread>

#include "tetherkit/common/logging.h"
#include "tetherkit/common/scheduling.h"
#include "tetherkit/common/time.h"

namespace tetherkit::core {

Result<std::unique_ptr<Runtime>> Runtime::Create(const RuntimeConfig& config) {
  auto runtime = std::unique_ptr<Runtime>(new Runtime());
  runtime->config_ = config;
  return runtime;
}

Runtime::~Runtime() {
  Stop();
}

std::string_view Runtime::SystemInterfaceName() const noexcept {
  return feth_pair_ == nullptr ? std::string_view{} : feth_pair_->SystemSide().Name();
}

const rndis::DeviceInfo& Runtime::DeviceInfo() const noexcept {
  static const rndis::DeviceInfo empty_info;
  return state_machine_ == nullptr ? empty_info : state_machine_->Info();
}

// =============================================================================
// 启动
// =============================================================================

Status Runtime::Start() {
  if (started_) {
    return std::unexpected(Error::Generic("运行时已启动"));
  }
  started_ = true;

  // ---- 第 1 步：权限检查 ----
  //
  // 提前检查并给出人话，而不是让后面一连串 EPERM 冒出来让用户自己猜。
  // 注意：libusb 声明 RNDIS 接口**不需要** root（macOS 没有 RNDIS 内核驱动），
  // 需要 root 的是 feth 创建与 /dev/bpf* 打开。
  if (!net::IsRunningAsRoot()) {
    return std::unexpected(Error::Generic(
        "TetherKit 需要 root 权限才能创建 feth 虚拟网卡并打开 /dev/bpf*。\n"
        "  请用 sudo 运行：sudo tetherkit\n"
        "  （USB 侧本身不需要 root —— macOS 没有 RNDIS 内核驱动，"
        "所以 libusb 能直接声明接口。）"));
  }

  // ---- 第 2 步：libusb 上下文与事件线程 ----
  TETHERKIT_ASSIGN_OR_RETURN(usb_context_, usb::Context::Create());

  // ---- 第 3 步：发现并打开设备 ----
  TETHERKIT_ASSIGN_OR_RETURN(const auto candidates,
                             usb::FindRndisDevices(*usb_context_, config_.device_filter));
  if (candidates.empty()) {
    return std::unexpected(Error::Generic(
        "没有找到 RNDIS 设备。请检查：\n"
        "  1. 设备已用 USB 数据线（不是只供电的线）连接；\n"
        "  2. 设备上已开启「USB 网络共享 / USB tethering」；\n"
        "  3. 手机解锁并信任本机（部分设备锁屏时不暴露 RNDIS 接口）。\n"
        "  可用 `system_profiler SPUSBDataType` 确认设备是否被系统识别。"));
  }
  if (candidates.size() > 1) {
    TETHERKIT_INFO("找到 {} 个 RNDIS 设备，使用第一个（可用 --vid/--pid 指定）",
                   candidates.size());
  }
  TETHERKIT_ASSIGN_OR_RETURN(device_, usb::Device::Open(*usb_context_, candidates.front()));

  // ---- 第 4 步：RNDIS 控制通道与状态机 ----
  //
  // 控制通道用同步 libusb API，因此必须跑在**非事件线程**上 —— 这里以及后面的
  // RunUntilStopped 都在调用方线程（主线程）上，满足要求。
  control_channel_ = std::make_unique<usb::UsbControlChannel>(
      *device_, config_.rndis.control_timeout_millis);

  // 让 RNDIS 协商用上真实的端点最大包长（影响 MaxTransferSize 的推导）。
  rndis::StateMachineConfig rndis_config = config_.rndis;
  rndis_config.requested_mtu = config_.mtu;
  state_machine_ =
      std::make_unique<rndis::StateMachine>(*control_channel_, *this, rndis_config);

  TETHERKIT_RETURN_IF_ERROR(state_machine_->Start());

  // 到这里才拿到了协商结果：设备 MAC、最终 MTU、聚合上限、对齐要求。
  const rndis::NegotiatedParameters& parameters = state_machine_->Parameters();
  const rndis::DeviceInfo& info = state_machine_->Info();

  // ---- 第 5 步：创建 feth 网卡对 ----
  //
  // 必须在协商之后：系统侧 MAC 要设成设备汇报的地址，MTU 要用协商结果，
  // 而 MAC 又必须在接口 IFF_UP 之前设好。
  {
    const net::MacAddress* system_mac = nullptr;
    net::MacAddress adopted{};
    if (config_.adopt_device_mac && info.has_permanent_address) {
      std::ranges::copy(info.permanent_address, adopted.begin());
      system_mac = &adopted;
    }
    TETHERKIT_ASSIGN_OR_RETURN(auto pair, net::FethPair::Create(parameters.mtu, system_mac));
    feth_pair_ = std::make_unique<net::FethPair>(std::move(pair));
  }

  // ---- 第 6 步：在**驱动侧**接口上打开 BPF ----
  //
  // 挂驱动侧而不是系统侧，是因为主机从系统侧发出的帧在驱动侧表现为 input 方向，
  // 而我们 write 进驱动侧的帧会进入系统侧的 input —— 一个描述符同时完成收发。
  {
    net::BpfConfig bpf_config = config_.bpf;
    // 单帧上限 = MTU + 以太头。注意内核 bpfwrite 的硬上限是 MTU + 18，
    // 所以这里绝不能超过它。
    bpf_config.max_frame_bytes = parameters.mtu + rndis::kEthernetHeaderBytes;
    TETHERKIT_ASSIGN_OR_RETURN(bpf_link_,
                               net::BpfLink::Open(feth_pair_->DriverSide().Name(), bpf_config));
  }

  // ---- 第 7 步：创建 USB 数据通道 ----
  {
    usb::DataChannelConfig data_config = config_.data_channel;
    // bulk IN 缓冲必须 >= 我们在 INITIALIZE_MSG 里宣称的 MaxTransferSize，
    // 否则设备聚合出来的大传输会溢出/被截断。
    data_config.rx_transfer_bytes =
        std::max(data_config.rx_transfer_bytes, config_.rndis.host_max_transfer_size);
    TETHERKIT_ASSIGN_OR_RETURN(
        data_channel_, usb::UsbDataChannel::Create(*device_, parameters, data_config));
  }

  // ---- 第 8 步：启动桥接层 ----
  {
    BridgeConfig bridge_config = config_.bridge;
    bridge_config.max_frame_bytes = parameters.mtu + rndis::kEthernetHeaderBytes;
    bridge_ = std::make_unique<Bridge>(*data_channel_, *bpf_link_, bridge_config);
    TETHERKIT_RETURN_IF_ERROR(bridge_->Start());
  }

  PrintNextSteps();
  return Ok();
}

void Runtime::PrintNextSteps() const {
  const std::string_view name = SystemInterfaceName();
  TETHERKIT_INFO("");
  TETHERKIT_INFO("==== 网卡已就绪：{} ====", name);
  TETHERKIT_INFO("接下来给它配一个 IP（RNDIS 设备通常自带 DHCP 服务器）：");
  TETHERKIT_INFO("    sudo ipconfig set {} DHCP", name);
  TETHERKIT_INFO("验证：");
  TETHERKIT_INFO("    ipconfig getifaddr {}", name);
  TETHERKIT_INFO("    ipconfig getsummary {}", name);
  TETHERKIT_INFO("若要让流量默认走它（会顶掉现有默认路由，请谨慎）：");
  TETHERKIT_INFO("    sudo route -n change default $(ipconfig getoption {} router)", name);
  TETHERKIT_INFO("注意：ipconfig set 建立的是**临时**服务，只存活到下一次网络");
  TETHERKIT_INFO("      配置变更，且不会出现在「系统设置 → 网络」里。");
  TETHERKIT_INFO("");
}

// =============================================================================
// 控制循环
// =============================================================================

void Runtime::RunUntilStopped() {
  // 控制线程用 kControl 而非 kDataPath 的 QoS：它每几秒才干一点活，
  // 抢性能核对它没意义，反而可能挤占三个真正的数据路径线程。
  ConfigureCurrentThread("rndis-ctl", ThreadRole::kControl);

  RateSampler sampler;
  BridgeStats previous = bridge_->Snapshot();
  Nanos last_stats_nanos = MonotonicNanos();

  const Nanos stats_interval_nanos =
      static_cast<Nanos>(config_.stats_interval_millis) * kNanosPerMilli;

  while (!stop_requested_.load(std::memory_order_acquire) &&
         !fatal_error_.load(std::memory_order_acquire)) {
    // ---- 状态机的周期性工作：保活 + 排空设备推送的消息 ----
    if (const auto status = state_machine_->Poll(); !status) {
      TETHERKIT_ERROR("RNDIS 控制通道故障：{}", status.error().ToString());
      break;
    }

    // ---- 周期性统计 ----
    const Nanos now = MonotonicNanos();
    if (stats_interval_nanos != 0 && now - last_stats_nanos >= stats_interval_nanos) {
      const BridgeStats current = bridge_->Snapshot();
      const double seconds =
          static_cast<double>(now - last_stats_nanos) / static_cast<double>(kNanosPerSecond);
      TETHERKIT_INFO("{}", FormatStatsLine(previous, current, seconds));
      previous = current;
      last_stats_nanos = now;
    }

    // ---- 睡到下一个该醒的时刻 ----
    //
    // 取「下次保活」与「下次统计」两个期限里更近的那个，避免无谓的唤醒。
    // 上限 250 ms 是为了让 RequestStop() 能被及时看到。
    std::uint32_t sleep_millis = std::min<std::uint32_t>(state_machine_->MillisUntilNextPoll(), 250);
    if (stats_interval_nanos != 0) {
      const Nanos elapsed = now - last_stats_nanos;
      const Nanos remaining =
          elapsed >= stats_interval_nanos ? 0 : stats_interval_nanos - elapsed;
      sleep_millis =
          std::min<std::uint32_t>(sleep_millis, static_cast<std::uint32_t>(remaining / kNanosPerMilli));
    }
    // 至少睡 10 ms：避免在保活刚好到期的边界上忙转。
    std::this_thread::sleep_for(std::chrono::milliseconds(std::max<std::uint32_t>(sleep_millis, 10)));
  }

  if (fatal_error_.load(std::memory_order_acquire)) {
    TETHERKIT_ERROR("因不可恢复的错误退出");
  }
}

// =============================================================================
// 停机
// =============================================================================

void Runtime::Stop() {
  if (stopped_ || !started_) {
    stopped_ = true;
    return;
  }
  stopped_ = true;
  TETHERKIT_INFO("正在停机……");

  // 严格按启动顺序的**逆序**拆除。
  //
  // 1. 先停桥接层：它内部会 join 两个数据路径线程，然后调
  //    DataChannel::Shutdown() 等在飞 USB 传输全部回收。这一步必须在销毁
  //    device_ 之前完成 —— libusb_close 不会帮我们回收在飞 transfer，
  //    先关句柄再释放 transfer 就是 use-after-free。
  if (bridge_ != nullptr) {
    bridge_->Stop();
    bridge_.reset();
  }
  data_channel_.reset();

  // 2. 关 BPF（此时已经没人在读写它了）。
  bpf_link_.reset();

  // 3. 销毁 feth 网卡对。内核的 feth_clone_destroy 会自动先解绑 peer。
  feth_pair_.reset();

  // 4. 让设备退出 RNDIS：先 SET filter = 0 让它停止发数据，再发 HALT。
  //    必须在关闭 USB 句柄之前做 —— 否则设备会一直以为主机还在，
  //    下次插上时状态不干净。
  if (state_machine_ != nullptr) {
    state_machine_->Stop();
    state_machine_.reset();
  }
  control_channel_.reset();

  // 5. 释放接口并关闭设备句柄。
  device_.reset();

  // 6. 最后停 libusb 事件线程并释放上下文。
  usb_context_.reset();

  TETHERKIT_INFO("已停机");
}

// =============================================================================
// StateMachineObserver
// =============================================================================

void Runtime::OnStateChanged(rndis::State /*from*/, rndis::State /*to*/) {
  // 状态机自己已经打了日志，这里不重复。保留这个钩子是为了将来接入指标上报。
}

void Runtime::OnNegotiated(const rndis::NegotiatedParameters& parameters,
                           const rndis::DeviceInfo& info) {
  TETHERKIT_INFO("RNDIS 就绪：设备 MAC {}，MTU {}，链路 {:.0f} Mbps",
                 rndis::FormatMac(info.permanent_address).data(), parameters.mtu,
                 info.LinkSpeedMbps());
}

void Runtime::OnLinkStateChanged(bool connected) {
  TETHERKIT_INFO("链路状态：{}", connected ? "已连接" : "已断开");

  // 链路 down 时暂停数据搬运。继续往断开的链路发帧只是浪费，而且会把队列填满
  // 导致真正恢复时先送出一堆过期的帧。
  if (bridge_ != nullptr) {
    bridge_->SetPaused(!connected);
  }
}

void Runtime::OnDeviceReset(bool addressing_lost) {
  TETHERKIT_WARN("设备已软复位（寻址信息{}）", addressing_lost ? "丢失，已重放" : "保持");

  // 复位期间设备丢弃了所有未完成的数据包。短暂暂停让状态机把包过滤重放完，
  // 避免在设备重建内部状态的窗口里继续灌数据。
  if (bridge_ != nullptr) {
    bridge_->SetPaused(true);
    bridge_->SetPaused(false);
  }
}

void Runtime::OnFatalError(const Error& error) {
  TETHERKIT_ERROR("链路不可恢复：{}", error.ToString());
  fatal_error_.store(true, std::memory_order_release);
}

}  // namespace tetherkit::core
