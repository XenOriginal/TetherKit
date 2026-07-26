// RNDIS 数据通道：异步 bulk IN / OUT 传输池。
//
// ★ 无 use-after-free 的拆除算法（本文件最重要的部分）★
//
//   libusb_close **不会**帮你回收在飞 transfer。do_close() 对仍在飞的 transfer
//   只是 list_del + 把 transfer->dev_handle 置空，再打一条
//   "Device handle closed while transfer was still being processed" 的日志 ——
//   **不调用你的回调、不释放内存**。而之后 darwin 后端 close 会
//   USBInterfaceClose 触发 IOKit 中止，darwin_async_io_callback 仍然会在 libusb
//   内部线程上跑并调 usbi_signal_transfer_completion()。如果那时你已经
//   libusb_free_transfer 了，就是 use-after-free。
//
//   正确顺序（Shutdown() 实现的就是这个）：
//     1. 置停机标志 —— 回调看到它就不再 resubmit，让在飞数自然收敛；
//     2. 对在飞 transfer 调 libusb_cancel_transfer；
//     3. **等到在飞计数归零**（每个回调都回来了）；
//     4. 这时才 libusb_free_transfer + 释放缓冲；
//     5. 调用方之后才可以销毁 Device（release_interface → close）。
//
//   ⚠️ 第 3 步**绝对不能在 libusb 事件线程上等** —— 回调正是在那个线程上跑的，
//      在那里等就是自己等自己，必然死锁。Shutdown() 因此只能从控制线程或主线程
//      调用，代码里用注释和断言双重提醒。
//
//   关于 darwin 的 cancel 粒度：libusb_cancel_transfer 在 darwin 上是
//   darwin_abort_transfers → **AbortPipe(pipeRef)**，即取消一个 transfer 会
//   取消**该端点上所有**在飞 transfer（全部以 kIOReturnAborted →
//   LIBUSB_TRANSFER_CANCELLED 回来）。所以其实只需对每个端点调一次，
//   但逐个调是幂等且更清晰的，不做这个微优化。
//
// ★ 为什么「宁少而大，勿多而小」★
//
//   darwin 后端在**每次** submit_bulk_transfer 之前都调 darwin_get_pipe_properties，
//   在 IOUSBInterfaceInterface >= 550 上等于两次 IOKit user-client 调用
//   （GetPipePropertiesV3 + GetEndpointPropertiesV3）。也就是说 macOS 上每次
//   libusb_submit_transfer 至少 3 次 IOKit 往返，而不是 1 次。
//   反过来，darwin 后端对单次 bulk 传输**没有任何长度上限、不做分片**
//   （Linux 后端才有 MAX_BULK_BUFFER_LENGTH = 16384 的 URB 拆分）。
//   → 结论：用较少、较大的传输。
#pragma once

#include <libusb.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <span>
#include <vector>

#include "tetherkit/common/error.h"
#include "tetherkit/common/frame_ring.h"
#include "tetherkit/common/spsc_ring.h"
#include "tetherkit/common/stats.h"
#include "tetherkit/rndis/messages.h"
#include "tetherkit/usb/device.h"

namespace tetherkit::usb {

/// 数据通道的配置。
struct DataChannelConfig {
  /// 并发在飞的 bulk IN 传输数。
  ///
  /// 8 个 × 16 KiB = 128 KiB 在飞。调研给的经验值是「在飞总量 ≥ 256 KiB」才能
  /// 在 USB 2.0 高速（53.2 MB/s 上限）下保证控制器队列不见底 —— 按 50 MB/s 计，
  /// 1 ms 的空档就浪费 50 KB。所以默认 16 个 × 16 KiB = 256 KiB。
  std::uint32_t rx_transfer_count = 16;

  /// 每个 bulk IN 缓冲的字节数。
  ///
  /// 必须 >= 我们在 INITIALIZE_MSG 里宣称的 MaxTransferSize，否则设备聚合出来的
  /// 大传输会溢出/被截断。运行时会用协商结果覆盖这个值。
  std::uint32_t rx_transfer_bytes = 16 * 1024;

  /// 并发在飞的 bulk OUT 传输数。
  ///
  /// TX 侧不需要像 RX 那么多：帧是我们主动攒批发出去的，4 个足以让
  /// 「组装下一批」与「上一批在飞」重叠起来。
  std::uint32_t tx_transfer_count = 4;

  /// 每个 bulk OUT 缓冲的字节数。运行时会被协商出的设备 MaxTransferSize 覆盖。
  std::uint32_t tx_transfer_bytes = 16 * 1024;

  /// bulk IN 的超时（毫秒）。
  ///
  /// **必须是 0（无限）**：RNDIS 的数据通道可能长时间空闲（用户没在传数据），
  /// 设了超时就会不断地超时-重提交，每次重提交都是 3 次 IOKit 往返，纯属浪费。
  /// darwin 把 timeout 同时作为 noDataTimeout 与 completionTimeout 传给 IOKit，
  /// 0 表示无限等待。
  std::uint32_t rx_timeout_millis = 0;

  /// bulk OUT 的超时（毫秒）。TX 有超时是合理的 —— 设备卡住时我们要能察觉。
  std::uint32_t tx_timeout_millis = 5'000;
};

/// 数据通道抽象。
///
/// 抽象的粒度是**批**而不是帧：一次虚调用处理几十上百帧，摊到每帧的开销远小于
/// 1 ns。这是刻意的 —— 若做成每帧一次虚调用就不可接受了。
class DataChannel {
 public:
  DataChannel() = default;
  DataChannel(const DataChannel&) = delete;
  DataChannel& operator=(const DataChannel&) = delete;
  DataChannel(DataChannel&&) = delete;
  DataChannel& operator=(DataChannel&&) = delete;
  virtual ~DataChannel() = default;

  /// 启动接收：把解出的以太帧推进 `rx_ring`。
  ///
  /// 调用后接收就一直在跑，直到 Shutdown()。
  [[nodiscard]] virtual Status StartReceiving(FrameRing& rx_ring,
                                              DirectionCounters& rx_counters) = 0;

  /// 把一批以太帧聚合成 RNDIS 消息发给设备。
  ///
  /// 返回实际发出的帧数。返回值小于 `frames.size()` 表示传输池暂时没有空闲槽位
  /// （背压），调用方应把剩余帧留到下次。
  [[nodiscard]] virtual Result<std::uint32_t> SendFrames(std::span<const FrameView> frames) = 0;

  /// 停止并回收全部在飞传输。
  ///
  /// **不能从 libusb 事件线程调用**（会死锁，见文件头说明）。
  virtual void Shutdown() = 0;

  /// 当前 TX 是否有空闲传输槽位可用。
  [[nodiscard]] virtual bool CanSend() const noexcept = 0;

  /// 单次传输能容纳的最大字节数（TX 方向）。
  [[nodiscard]] virtual std::uint32_t MaxTransferBytes() const noexcept = 0;

  /// 异步发送完成回调里累计的 I/O 错误数（STALL、传输失败等）。
  ///
  /// 为什么要单独开这个接口，而不是让数据通道直接写桥接层的 TX 计数器：
  /// DirectionCounters 的契约是「**只允许一个线程**调用 Add*」（它用 relaxed
  /// load+store 而非 fetch_add，正是靠单写者才安全）。而 TX 方向有两个写者 ——
  /// 提交侧在 TX 抽取线程、错误侧在 libusb 事件线程。硬塞进同一个计数器就破坏了
  /// 这个不变式（TSan 也会报）。
  /// 因此拆成两份各自单写的计数，由 Bridge::Snapshot() 在**读取时**合并。
  [[nodiscard]] virtual std::uint64_t AsyncSendErrors() const noexcept = 0;
};

/// 基于 libusb 异步 API 的数据通道实现。
class UsbDataChannel final : public DataChannel {
 public:
  /// @param device      已声明好接口的设备
  /// @param parameters  RNDIS 协商结果（决定聚合上限与对齐）
  /// @param config      传输池参数
  [[nodiscard]] static Result<std::unique_ptr<UsbDataChannel>> Create(
      Device& device, const rndis::NegotiatedParameters& parameters,
      const DataChannelConfig& config);

  // 拷贝与移动已在基类 DataChannel 中删除，这里显式重申以满足静态检查。
  UsbDataChannel(const UsbDataChannel&) = delete;
  UsbDataChannel& operator=(const UsbDataChannel&) = delete;
  UsbDataChannel(UsbDataChannel&&) = delete;
  UsbDataChannel& operator=(UsbDataChannel&&) = delete;
  ~UsbDataChannel() override;

  [[nodiscard]] Status StartReceiving(FrameRing& rx_ring,
                                      DirectionCounters& rx_counters) override;
  [[nodiscard]] Result<std::uint32_t> SendFrames(std::span<const FrameView> frames) override;
  void Shutdown() override;

  [[nodiscard]] bool CanSend() const noexcept override;

  [[nodiscard]] std::uint32_t MaxTransferBytes() const noexcept override {
    return tx_transfer_bytes_;
  }

  [[nodiscard]] std::uint64_t AsyncSendErrors() const noexcept override {
    return async_send_errors_.load(std::memory_order_relaxed);
  }

  /// 累计因 RNDIS 消息畸形而丢弃的传输数，用于诊断设备 bug。
  [[nodiscard]] std::uint64_t MalformedTransfers() const noexcept {
    return malformed_transfers_.load(std::memory_order_relaxed);
  }

 private:
  UsbDataChannel() = default;

  /// 池中的一个传输及其缓冲。
  struct Slot {
    ::libusb_transfer* transfer = nullptr;
    std::byte* buffer = nullptr;
    std::uint32_t buffer_bytes = 0;
    UsbDataChannel* owner = nullptr;
    std::uint32_t index = 0;
  };

  // ---- libusb 回调（静态跳板 → 成员函数）----
  static void ReceiveCallbackTrampoline(::libusb_transfer* transfer);
  static void SendCallbackTrampoline(::libusb_transfer* transfer);

  void OnReceiveComplete(Slot& slot) noexcept;
  void OnSendComplete(Slot& slot) noexcept;

  /// 分配一个池。缓冲按页对齐（darwin 上没有零拷贝 DMA 缓冲，
  /// libusb_dev_mem_alloc 返回 NULL，只能自己 posix_memalign；按 hw.pagesize
  /// 对齐能减少 IOKit 建立 DMA 描述符时的分段）。
  [[nodiscard]] Status AllocatePool(std::vector<Slot>& pool, std::uint32_t count,
                                    std::uint32_t buffer_bytes);

  static void FreePool(std::vector<Slot>& pool) noexcept;

  /// 提交一个 RX 传输。
  [[nodiscard]] Status SubmitReceive(Slot& slot);

  Device* device_ = nullptr;
  rndis::NegotiatedParameters parameters_{};
  DataChannelConfig config_{};

  std::uint32_t tx_transfer_bytes_ = 0;

  std::vector<Slot> rx_pool_;
  std::vector<Slot> tx_pool_;

  /// TX 空闲槽位索引队列。
  ///
  /// 生产者 = libusb 事件线程（发送完成回调归还槽位），
  /// 消费者 = BPF 读线程（取槽位组装下一批）。正好是 SPSC。
  std::unique_ptr<SpscRing<std::uint32_t>> tx_free_slots_;

  /// 接收目标。StartReceiving 之后非空。
  FrameRing* rx_ring_ = nullptr;
  DirectionCounters* rx_counters_ = nullptr;

  /// 异步发送完成回调里累计的 I/O 错误。**只由 libusb 事件线程递增**，
  /// 与桥接层的 TX 计数器分开，见 AsyncSendErrors() 的说明。
  std::atomic<std::uint64_t> async_send_errors_{0};

  /// 在飞传输计数。回调递减，Shutdown 等它归零。
  std::atomic<std::uint32_t> outstanding_{0};
  /// 停机标志。回调看到它就不再 resubmit。
  std::atomic<bool> shutting_down_{false};
  /// 是否已经完成拆除（Shutdown 幂等）。
  bool shutdown_complete_ = false;

  std::atomic<std::uint64_t> malformed_transfers_{0};

  /// 等待在飞计数归零。
  std::mutex drain_mutex_;
  std::condition_variable drain_condition_;
};

}  // namespace tetherkit::usb
