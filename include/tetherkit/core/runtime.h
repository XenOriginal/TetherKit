// 运行时编排：把 USB、RNDIS 状态机、feth、BPF、桥接组装成一个可运行的驱动。
//
// ★ 启动顺序（每一步都依赖前一步的产物，不能调换）★
//
//   1. 权限检查            —— 提前给出人话错误，而不是让后面一堆 EPERM 冒出来
//   2. libusb 上下文 + 事件线程
//   3. 发现并打开 RNDIS 设备（声明两个接口、解析端点）
//   4. RNDIS 控制通道 + 状态机 Start()
//        └→ 这一步才拿到：设备 MAC、协商出的 MTU、聚合上限、对齐要求
//   5. 用第 4 步的结果创建 feth 网卡对（系统侧 MAC = 设备汇报的 MAC）
//   6. 在驱动侧接口上打开 BPF
//   7. 用第 4 步的协商参数创建 USB 数据通道
//   8. 启动桥接层
//   9. 控制线程进入循环：定期 Poll()（保活 + 排空设备推送）
//
//   为什么 feth 必须在 RNDIS 协商**之后**创建：系统侧网卡的 MAC 要设成设备
//   汇报的 OID_802_3_PERMANENT_ADDRESS，而 MTU 要用协商结果 —— 这两个值在第 4 步
//   之前都拿不到。而 MAC 又必须在接口 IFF_UP 之前设好。
//
// ★ 停机顺序是启动顺序的严格逆序 ★
//
//   桥接层 → 数据通道（等在飞传输回收）→ BPF → feth → 状态机 HALT → 设备 → libusb
//
//   其中「数据通道等在飞传输回收」这一步必须在销毁设备**之前**完成，
//   否则就是 use-after-free（详见 usb/data_channel.h 的说明）。
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>

#include "tetherkit/common/error.h"
#include "tetherkit/core/bridge.h"
#include "tetherkit/net/bpf_link.h"
#include "tetherkit/net/feth_device.h"
#include "tetherkit/rndis/state_machine.h"
#include "tetherkit/usb/context.h"
#include "tetherkit/usb/data_channel.h"
#include "tetherkit/usb/device.h"

namespace tetherkit::core {

/// 运行时配置。默认值都在各自字段的注释里说明了推导依据。
struct RuntimeConfig {
  /// 设备筛选。全为 0 表示用第一个找到的 RNDIS 设备。
  usb::DeviceFilter device_filter;

  /// 希望使用的 MTU。设备装不下时会被协商下调。
  ///
  /// 上限受 feth 的 sysctl net.link.fake.max_mtu 约束（本机 2048）。
  std::uint32_t mtu = rndis::kDefaultMtu;

  /// 指定 feth 接口名（如 "feth7"）；留空表示让内核自动选编号。
  std::string system_interface_name;
  std::string driver_interface_name;

  /// 是否把系统侧网卡的 MAC 设为设备汇报的地址。
  ///
  /// 默认开：RNDIS 语义下设备就是这块网卡，对端的 ARP 表与 DHCP 租约都按这个
  /// MAC 建立。关掉只在排查 MAC 冲突时有用。
  bool adopt_device_mac = true;

  rndis::StateMachineConfig rndis;
  usb::DataChannelConfig data_channel;
  net::BpfConfig bpf;
  BridgeConfig bridge;

  /// 统计报告周期（毫秒）；0 表示不报告。
  std::uint32_t stats_interval_millis = 5'000;
};

/// 组装并运行整个驱动。
///
/// 用法：
/// ```
/// TETHERKIT_ASSIGN_OR_RETURN(auto runtime, Runtime::Create(config));
/// TETHERKIT_RETURN_IF_ERROR(runtime->Start());
/// runtime->RunUntilStopped();   // 阻塞，直到 RequestStop()
/// ```
class Runtime final : public rndis::StateMachineObserver {
 public:
  [[nodiscard]] static Result<std::unique_ptr<Runtime>> Create(const RuntimeConfig& config);

  Runtime(const Runtime&) = delete;
  Runtime& operator=(const Runtime&) = delete;
  Runtime(Runtime&&) = delete;
  Runtime& operator=(Runtime&&) = delete;

  ~Runtime() override;

  /// 走完完整的启动序列。
  [[nodiscard]] Status Start();

  /// 阻塞运行控制循环，直到 RequestStop() 被调用或链路不可恢复。
  ///
  /// 控制循环做三件事：定期 Poll() 状态机（保活 + 排空设备推送）、
  /// 定期打印统计、检查停机请求。
  ///
  /// **控制通道必须跑在这个线程上** —— libusb 的同步 API 在事件线程上会返回
  /// LIBUSB_ERROR_BUSY，所以状态机不能放到事件线程里。
  void RunUntilStopped();

  /// 请求停机。可从信号处理器或任意线程调用，异步信号安全（只写一个原子）。
  void RequestStop() noexcept { stop_requested_.store(true, std::memory_order_release); }

  /// 按启动顺序的严格逆序拆除。幂等。
  void Stop();

  /// 系统侧网卡名，用于给用户打印「接下来该做什么」。
  [[nodiscard]] std::string_view SystemInterfaceName() const noexcept;

  [[nodiscard]] const rndis::DeviceInfo& DeviceInfo() const noexcept;

  // ---- StateMachineObserver ----
  void OnStateChanged(rndis::State from, rndis::State to) override;
  void OnNegotiated(const rndis::NegotiatedParameters& parameters,
                    const rndis::DeviceInfo& info) override;
  void OnLinkStateChanged(bool connected) override;
  void OnDeviceReset(bool addressing_lost) override;
  void OnFatalError(const Error& error) override;

 private:
  Runtime() = default;

  /// 打印「网卡已就绪，接下来该怎么配 IP」的提示。
  void PrintNextSteps() const;

  RuntimeConfig config_;

  std::unique_ptr<usb::Context> usb_context_;
  std::unique_ptr<usb::Device> device_;
  std::unique_ptr<usb::UsbControlChannel> control_channel_;
  std::unique_ptr<rndis::StateMachine> state_machine_;
  std::unique_ptr<net::FethPair> feth_pair_;
  std::unique_ptr<net::BpfLink> bpf_link_;
  std::unique_ptr<usb::UsbDataChannel> data_channel_;
  std::unique_ptr<Bridge> bridge_;

  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> fatal_error_{false};
  bool started_ = false;
  bool stopped_ = false;
};

}  // namespace tetherkit::core
