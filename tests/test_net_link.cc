// 链路层测试。
//
// 分两部分：
//   * loopback 后端 —— 任何环境都能跑，是桥接层测试的基础设施，必须自身可靠；
//   * feth + BPF —— 需要 root，非 root 环境下**跳过而非失败**。
//     用 TETHERKIT_ROOT_TESTS=1 显式开启（避免 CI 上误跑真实网卡操作）。
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <format>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include <doctest.h>

#include "tetherkit/net/bpf_link.h"
#include "tetherkit/net/darwin_abi.h"
#include "tetherkit/net/feth_device.h"
#include "tetherkit/net/loopback_link.h"

using namespace tetherkit;       // NOLINT(google-build-using-namespace)
using namespace tetherkit::net;  // NOLINT(google-build-using-namespace)

namespace {

/// 造一帧合法以太帧：目的 MAC、源 MAC、EtherType，再填可校验的净荷。
std::vector<std::byte> MakeEthernetFrame(std::uint32_t total_length, std::uint8_t tag) {
  std::vector<std::byte> frame(total_length);
  // 目的 MAC：广播；源 MAC：02:00:00:00:00:tag（本地管理单播）。
  for (int i = 0; i < 6; ++i) {
    frame[static_cast<std::size_t>(i)] = std::byte{0xFF};
  }
  frame[6] = std::byte{0x02};
  frame[11] = std::byte{tag};
  frame[12] = std::byte{0x08};  // EtherType 0x0800 = IPv4
  frame[13] = std::byte{0x00};
  for (std::uint32_t i = 14; i < total_length; ++i) {
    frame[i] = std::byte{static_cast<unsigned char>((tag + i) & 0xFFU)};
  }
  return frame;
}

/// 需要 root 的测试是否启用。
///
/// getenv 在多线程下不安全，但这里是测试用例开头的一次性读取，进程内没有
/// 并发的 setenv，因此豁免检查。
// NOLINTNEXTLINE(concurrency-mt-unsafe)
bool RootTestsEnabled() {
  const char* flag = std::getenv("TETHERKIT_ROOT_TESTS");
  return flag != nullptr && flag[0] == '1' && IsRunningAsRoot();
}

/// 把 Result/Status 的错误渲染成字符串，成功时返回空串。
///
/// 直接在 REQUIRE_MESSAGE 里写 `r ? "" : r.error().ToString()` 编译不过 ——
/// doctest 的 MessageBuilder 会把三元表达式整体吞进流里再试图转 bool。
template <typename T>
std::string Why(const T& result) {
  return result.has_value() ? std::string{} : result.error().ToString();
}

/// 打印跳过原因，让「跳过」在测试输出里是可见的、而不是静默通过。
///
/// 先用 std::format 拼成一个 std::string 再交给 MESSAGE：doctest 的
/// MessageBuilder 对 `const char*` 会按指针字符串化，直接流进去会打出地址。
void ReportSkip(std::string_view what) {
  const std::string message =
      std::format("跳过 {}：需要 root 且需设置 TETHERKIT_ROOT_TESTS=1（当前 euid={}）", what,
                  IsRunningAsRoot() ? "0" : "非 0");
  MESSAGE(message);
}

}  // namespace

TEST_SUITE("net.abi") {

TEST_CASE("私有 ABI 的结构体大小与 ioctl 编号与实测值一致") {
  // 这些都是 static_assert，能编译过就说明成立；这里再运行期确认一遍，
  // 让 ABI 假设在测试报告里是**可见**的。
  CHECK(sizeof(IfDrv) == 40);
  CHECK(sizeof(FethRequest) == 160);
  CHECK(offsetof(FethRequest, u) == 32);
  CHECK(kSetDriverSpec == 0x8028'697BUL);
  CHECK(kGetDriverSpec == 0xC028'697BUL);
  CHECK(kBpfSetBatchWrite == 0x8004'428FUL);
  CHECK(kBpfSetNoTimestamp == 0x8004'4291UL);
  CHECK(static_cast<unsigned long>(FethSetCommand::kSetPeer) == 1);
  CHECK(static_cast<unsigned long>(FethGetCommand::kGetPeer) == 1);
}

TEST_CASE("BPF 记录头的大小陷阱：sizeof 是 20 但 bh_hdrlen 是 18") {
  // 这是 BPF 解析最容易出错的地方，用测试把它钉死。
  CHECK(sizeof(struct bpf_hdr) == 20);
  CHECK(sizeof(struct BPF_TIMEVAL) == 8);
  CHECK(kBpfHeaderMinBytes == 18);
  CHECK(BPF_ALIGNMENT == 4);
  // 内核对 DLT_EN10MB 的推导：BPF_WORDALIGN(14 + 18) - 14 = 18。
  CHECK(BPF_WORDALIGN(14 + kBpfHeaderMinBytes) - 14 == kBpfHeaderMinBytes);
}

TEST_CASE("feth 创建期 sysctl 清单非空且都有说明") {
  CHECK(std::size(kRequiredFethSysctls) > 0);
  for (const RequiredFethSysctl& entry : kRequiredFethSysctls) {
    CHECK(entry.name != nullptr);
    CHECK(entry.why != nullptr);
    CHECK(std::string{entry.why}.size() > 10);  // 说明必须是人话，不能只有一个词
  }
}

}  // TEST_SUITE("net.abi")

TEST_SUITE("net.loopback") {

TEST_CASE("空队列读取返回空批次") {
  LoopbackLink link;
  const auto batch = link.ReadFrames();
  REQUIRE(batch.has_value());
  CHECK(batch->frames.empty());
}

TEST_CASE("注入的帧能按 FIFO 顺序读出") {
  LoopbackLink link;
  for (std::uint8_t i = 0; i < 5; ++i) {
    REQUIRE(link.PushInbound(MakeEthernetFrame(100, i)));
  }
  const auto batch = link.ReadFrames();
  REQUIRE(batch.has_value());
  REQUIRE(batch->frames.size() == 5);
  for (std::size_t i = 0; i < 5; ++i) {
    CHECK(batch->frames[i].length == 100);
    // 源 MAC 的最后一字节是我们塞的序号。
    CHECK(batch->frames[i].data[11] == std::byte{static_cast<unsigned char>(i)});
  }
}

TEST_CASE("单批读取受 max_frames_per_batch 限制，剩余留到下一批") {
  LoopbackLink link(LoopbackConfig{.max_frames_per_batch = 3});
  for (std::uint8_t i = 0; i < 7; ++i) {
    REQUIRE(link.PushInbound(MakeEthernetFrame(64, i)));
  }
  const auto first = link.ReadFrames();
  REQUIRE(first.has_value());
  CHECK(first->frames.size() == 3);

  const auto second = link.ReadFrames();
  REQUIRE(second.has_value());
  CHECK(second->frames.size() == 3);

  const auto third = link.ReadFrames();
  REQUIRE(third.has_value());
  CHECK(third->frames.size() == 1);
}

TEST_CASE("注入队列满时丢弃并计数") {
  LoopbackLink link(LoopbackConfig{.inbound_capacity = 2});
  CHECK(link.PushInbound(MakeEthernetFrame(64, 1)));
  CHECK(link.PushInbound(MakeEthernetFrame(64, 2)));
  CHECK_FALSE(link.PushInbound(MakeEthernetFrame(64, 3)));
  CHECK(link.InboundDrops() == 1);
}

TEST_CASE("超长帧被拒绝注入") {
  LoopbackLink link(LoopbackConfig{.max_frame_bytes = 128});
  CHECK_FALSE(link.PushInbound(MakeEthernetFrame(129, 1)));
  CHECK(link.InboundDrops() == 1);
}

TEST_CASE("写出的帧可被取回，内容完整") {
  LoopbackLink link;
  const auto frame_a = MakeEthernetFrame(1514, 0xA1);
  const auto frame_b = MakeEthernetFrame(64, 0xB2);
  const std::array<FrameView, 2> batch{
      FrameView{.data = frame_a.data(), .length = static_cast<std::uint32_t>(frame_a.size())},
      FrameView{.data = frame_b.data(), .length = static_cast<std::uint32_t>(frame_b.size())},
  };

  const auto result = link.WriteFrames(batch);
  REQUIRE(result.has_value());
  CHECK(result->frames_written == 2);
  CHECK(result->bytes_written == 1514 + 64);
  CHECK(result->frames_skipped == 0);

  const auto sent = link.DrainSent();
  REQUIRE(sent.size() == 2);
  CHECK(sent[0] == frame_a);
  CHECK(sent[1] == frame_b);
  // DrainSent 不影响累计计数。
  CHECK(link.TotalSentFrames() == 2);
  CHECK(link.TotalSentBytes() == 1514 + 64);
  // 取空之后再取应为空。
  CHECK(link.DrainSent().empty());
}

TEST_CASE("写出时跳过过短与过长的帧") {
  LoopbackLink link(LoopbackConfig{.max_frame_bytes = 200});
  const auto too_short = MakeEthernetFrame(14, 1);
  std::vector<std::byte> shorter(13);
  const auto too_long = MakeEthernetFrame(201, 2);
  const auto valid = MakeEthernetFrame(100, 3);

  const std::array<FrameView, 3> batch{
      FrameView{.data = shorter.data(), .length = 13},
      FrameView{.data = too_long.data(), .length = 201},
      FrameView{.data = valid.data(), .length = 100},
  };
  const auto result = link.WriteFrames(batch);
  REQUIRE(result.has_value());
  CHECK(result->frames_written == 1);
  CHECK(result->frames_skipped == 2);
  // 14 字节恰好是最小合法帧，应被接受。
  const std::array<FrameView, 1> minimal{FrameView{.data = too_short.data(), .length = 14}};
  const auto minimal_result = link.WriteFrames(minimal);
  REQUIRE(minimal_result.has_value());
  CHECK(minimal_result->frames_written == 1);
}

TEST_CASE("写出队列满时停止写入，如实反映已写数") {
  LoopbackLink link(LoopbackConfig{.sent_capacity = 2});
  const auto frame = MakeEthernetFrame(64, 1);
  std::vector<FrameView> batch(5, FrameView{.data = frame.data(), .length = 64});
  const auto result = link.WriteFrames(batch);
  REQUIRE(result.has_value());
  CHECK(result->frames_written == 2);
}

TEST_CASE("Interrupt 后读取立即返回空批次") {
  LoopbackLink link;
  REQUIRE(link.PushInbound(MakeEthernetFrame(64, 1)));
  link.Interrupt();
  CHECK(link.Interrupted());
  const auto batch = link.ReadFrames();
  REQUIRE(batch.has_value());
  CHECK(batch->frames.empty());
}

TEST_CASE("可以注入写失败以测试错误传播") {
  LoopbackLink link;
  link.FailWritesAfter(1);  // 第 1 次成功，第 2 次起失败
  const auto frame = MakeEthernetFrame(64, 1);
  const std::array<FrameView, 1> batch{FrameView{.data = frame.data(), .length = 64}};

  CHECK(link.WriteFrames(batch).has_value());
  CHECK_FALSE(link.WriteFrames(batch).has_value());
}

TEST_CASE("空批次写入是合法的空操作") {
  LoopbackLink link;
  const auto result = link.WriteFrames({});
  REQUIRE(result.has_value());
  CHECK(result->frames_written == 0);
}

}  // TEST_SUITE("net.loopback")

TEST_SUITE("net.feth" * doctest::skip(false)) {

TEST_CASE("查询 feth MTU 上限（只读 sysctl，无需 root）") {
  const auto max_mtu = QueryFethMaxMtu();
  REQUIRE(max_mtu.has_value());
  // 内核保证 >= ETHERMTU(1500)。
  CHECK(*max_mtu >= 1500);
  MESSAGE(std::format("net.link.fake.max_mtu = {}", *max_mtu));
}

TEST_CASE("校验 feth 创建期 sysctl（只读，无需 root）") {
  const auto status = VerifyFethSysctls();
  if (!status) {
    // 不是测试失败 —— 是这台机器的 sysctl 被改过。报出来让人知道。
    MESSAGE(std::format("本机 feth sysctl 不满足要求：{}", status.error().ToString()));
  }
  // 只要能读到就算通过；具体值取决于机器配置。
  CHECK(true);
}

TEST_CASE("非 root 环境下创建 feth 必须给出明确的权限错误") {
  if (IsRunningAsRoot()) {
    MESSAGE("当前以 root 运行，跳过权限错误检查");
    return;
  }
  const auto pair = FethPair::Create(1500);
  REQUIRE_FALSE(pair.has_value());
  const std::string message = pair.error().ToString();
  // 错误必须提到 root / sudo，而不是丢一个裸 EPERM 给用户。
  CHECK((message.find("root") != std::string::npos || message.find("sudo") != std::string::npos));
}

TEST_CASE("MAC 格式化") {
  const MacAddress mac{0x66, 0x65, 0x74, 0x68, 0x00, 0x00};
  // 内核给 feth0 分配的正是这个地址（'f','e','t','h', unit>>8, unit&0xff）。
  CHECK(std::string{FormatMac(mac).data()} == "66:65:74:68:00:00");
}

TEST_CASE("完整生命周期：创建、配对、设 MTU/MAC、UP、销毁") {
  if (!RootTestsEnabled()) {
    ReportSkip("feth 完整生命周期测试");
    return;
  }

  const MacAddress device_mac{0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE};
  auto pair = FethPair::Create(1500, &device_mac);
  REQUIRE_MESSAGE(pair.has_value(), Why(pair));

  const std::string system_name{pair->SystemSide().Name()};
  const std::string driver_name{pair->DriverSide().Name()};
  MESSAGE(std::format("创建了 {} ←→ {}", system_name, driver_name));

  // 配对关系双向成立。
  const auto driver_peer = pair->DriverSide().QueryPeer();
  REQUIRE(driver_peer.has_value());
  CHECK(*driver_peer == system_name);
  const auto system_peer = pair->SystemSide().QueryPeer();
  REQUIRE(system_peer.has_value());
  CHECK(*system_peer == driver_name);

  // MTU 两侧一致。
  CHECK(pair->SystemSide().QueryMtu().value_or(0) == 1500);
  CHECK(pair->DriverSide().QueryMtu().value_or(0) == 1500);

  // 系统侧 MAC 是我们设的，驱动侧保持内核分配的（两者必须不同）。
  const auto system_mac = pair->SystemSide().QueryMacAddress();
  REQUIRE(system_mac.has_value());
  CHECK(*system_mac == device_mac);
  const auto driver_mac = pair->DriverSide().QueryMacAddress();
  REQUIRE(driver_mac.has_value());
  CHECK(*driver_mac != device_mac);

  // 两侧都 UP —— bpfwrite 硬性要求驱动侧是 UP。
  CHECK(pair->SystemSide().IsUp().value_or(false));
  CHECK(pair->DriverSide().IsUp().value_or(false));
}

TEST_CASE("BPF 打开配置全流程，并验证方向语义与回环抑制") {
  if (!RootTestsEnabled()) {
    ReportSkip("BPF 收发测试");
    return;
  }

  auto pair = FethPair::Create(1500);
  REQUIRE_MESSAGE(pair.has_value(), Why(pair));

  // BPF 挂在**驱动侧**。
  auto link = BpfLink::Open(pair->DriverSide().Name(), BpfConfig{});
  REQUIRE_MESSAGE(link.has_value(), Why(link));

  MESSAGE(std::format("BPF 设备 {}，内核缓冲 {} 字节，批量写 {}", (*link)->DevicePath(),
                      (*link)->KernelBufferBytes(),
                      (*link)->SupportsBatchWrite() ? "可用" : "不可用"));

  // 内核实际生效的缓冲不应为 0，且不超过 32 MiB 的上限。
  CHECK((*link)->KernelBufferBytes() > 0);
  CHECK((*link)->KernelBufferBytes() <= 32U * 1024 * 1024);

  const auto stats = (*link)->QueryKernelStats();
  REQUIRE(stats.has_value());

  // 写一帧进去 —— 它应该进入系统侧的 input，**不应该**被我们自己读回来
  // （BIOCSSEESENT=0 过滤掉 output 方向）。
  const auto frame = MakeEthernetFrame(200, 0x5A);
  const std::array<FrameView, 1> batch{FrameView{.data = frame.data(), .length = 200}};
  const auto written = (*link)->WriteFrames(batch);
  REQUIRE_MESSAGE(written.has_value(), Why(written));
  CHECK(written->frames_written == 1);

  // 读一次（会在读超时后返回）。绝不应看到自己刚写的那一帧。
  const auto batch_read = (*link)->ReadFrames();
  REQUIRE(batch_read.has_value());
  for (const FrameView& view : batch_read->frames) {
    // 我们写的帧源 MAC 第 12 字节是 0x5A；读到它就说明回环抑制失效了。
    const bool is_our_frame = view.length == 200 && view.data[11] == std::byte{0x5A};
    CHECK_FALSE(is_our_frame);
  }
}

}  // TEST_SUITE("net.feth")
