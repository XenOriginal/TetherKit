// FrameRing 的单元测试。
//
// FrameRing 是 RX 路径的核心：libusb 回调线程把拆出的以太帧写进去，
// BPF 写线程取出来 write()。因此这里既测语义，也测并发。
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>
#include <thread>
#include <vector>

#include <doctest.h>

#include "tetherkit/common/cache.h"
#include "tetherkit/common/frame_ring.h"

using tetherkit::FrameRing;
using tetherkit::FrameView;
using tetherkit::kCacheLineSize;

namespace {

/// 造一个内容可自校验的帧：首字节是序号，其余按序号推导。
std::vector<std::byte> MakeFrame(std::uint32_t length, std::uint8_t tag) {
  std::vector<std::byte> frame(length);
  for (std::uint32_t i = 0; i < length; ++i) {
    frame[i] = std::byte{static_cast<unsigned char>((tag + i) & 0xFFU)};
  }
  return frame;
}

bool VerifyFrame(std::span<const std::byte> frame, std::uint8_t tag) {
  for (std::size_t i = 0; i < frame.size(); ++i) {
    if (frame[i] != std::byte{static_cast<unsigned char>((tag + i) & 0xFFU)}) {
      return false;
    }
  }
  return true;
}

}  // namespace

TEST_SUITE("common.frame_ring") {

TEST_CASE("容量向上取整并报告存储开销") {
  FrameRing ring(100, 1514);
  CHECK(ring.Capacity() == 128);
  CHECK(ring.MaxFrameBytes() == 1514);
  // 每槽 = 128 字节头 + 1514 字节数据 = 1642，向上对齐到 128 的倍数 = 1664。
  CHECK(ring.StorageBytes() == 128 * 1664);
}

TEST_CASE("空队列读取返回空视图") {
  FrameRing ring(4, 1514);
  const FrameView view = ring.BeginRead();
  CHECK(view.Empty());
  CHECK(view.data == nullptr);
}

TEST_CASE("单帧入队出队内容一致") {
  FrameRing ring(4, 1514);
  const std::vector<std::byte> frame = MakeFrame(1514, 0x42);
  REQUIRE(ring.TryPush(frame));

  const FrameView view = ring.BeginRead();
  REQUIRE(view.length == 1514);
  CHECK(VerifyFrame(view.Bytes(), 0x42));
  ring.CommitRead();

  CHECK(ring.BeginRead().Empty());
}

TEST_CASE("超长帧被拒绝且不占用槽位") {
  FrameRing ring(4, 128);
  const std::vector<std::byte> too_long = MakeFrame(129, 0x01);
  CHECK_FALSE(ring.TryPush(too_long));
  CHECK(ring.SizeSnapshot() == 0);
  // 拒绝一次之后队列仍然可用。
  CHECK(ring.TryPush(MakeFrame(128, 0x02)));
}

TEST_CASE("队列满后拒绝入队") {
  FrameRing ring(4, 64);
  for (std::uint8_t i = 0; i < 4; ++i) {
    REQUIRE(ring.TryPush(MakeFrame(64, i)));
  }
  CHECK(ring.SizeSnapshot() == 4);
  CHECK_FALSE(ring.TryPush(MakeFrame(64, 9)));
}

TEST_CASE("BeginWrite/CommitWrite 零拷贝路径") {
  FrameRing ring(4, 1514);
  const std::span<std::byte> dst = ring.BeginWrite();
  REQUIRE(dst.size() == 1514);
  // 直接在预留槽位上原地构造，模拟从 USB 缓冲 memcpy 进来。
  for (std::size_t i = 0; i < 100; ++i) {
    dst[i] = std::byte{static_cast<unsigned char>((0x77 + i) & 0xFFU)};
  }
  ring.CommitWrite(100);

  const FrameView view = ring.BeginRead();
  REQUIRE(view.length == 100);
  CHECK(VerifyFrame(view.Bytes(), 0x77));
  ring.CommitRead();
}

TEST_CASE("变长帧混合、反复绕环不串数据") {
  FrameRing ring(4, 2048);
  // 容量 4，跑 500 轮，每轮长度不同，逼迫索引回绕并复用槽位。
  for (std::uint32_t round = 0; round < 500; ++round) {
    const auto length = static_cast<std::uint32_t>(14 + (round * 37) % 2000);
    const auto tag = static_cast<std::uint8_t>(round & 0xFFU);
    REQUIRE(ring.TryPush(MakeFrame(length, tag)));

    const FrameView view = ring.BeginRead();
    REQUIRE(view.length == length);
    CHECK(VerifyFrame(view.Bytes(), tag));
    ring.CommitRead();
  }
}

TEST_CASE("每帧数据区起始地址按缓存行对齐") {
  // 性能正确性断言：帧数据必须落在缓存行边界，memcpy 与 write() 才走最优路径。
  FrameRing ring(8, 1514);
  for (int i = 0; i < 8; ++i) {
    const std::span<std::byte> dst = ring.BeginWrite();
    REQUIRE_FALSE(dst.empty());
    CHECK(reinterpret_cast<std::uintptr_t>(dst.data()) % kCacheLineSize == 0);
    ring.CommitWrite(64);
  }
}

TEST_CASE("并发搬运 20 万帧不丢不乱序") {
  constexpr std::uint32_t kTotal = 200'000;
  FrameRing ring(512, 512);

  std::atomic<bool> corrupted{false};

  std::thread producer([&] {
    std::uint32_t sent = 0;
    while (sent < kTotal) {
      const std::span<std::byte> dst = ring.BeginWrite();
      if (dst.empty()) {
        std::this_thread::yield();
        continue;
      }
      // 长度与内容都由序号决定，消费者可独立校验。
      const auto length = static_cast<std::uint32_t>(14 + (sent % 400));
      const auto tag = static_cast<std::uint8_t>(sent & 0xFFU);
      for (std::uint32_t i = 0; i < length; ++i) {
        dst[i] = std::byte{static_cast<unsigned char>((tag + i) & 0xFFU)};
      }
      ring.CommitWrite(length);
      ++sent;
    }
  });

  std::uint32_t received = 0;
  while (received < kTotal) {
    const FrameView view = ring.BeginRead();
    if (view.Empty()) {
      std::this_thread::yield();
      continue;
    }
    const auto expected_length = static_cast<std::uint32_t>(14 + (received % 400));
    const auto expected_tag = static_cast<std::uint8_t>(received & 0xFFU);
    if (view.length != expected_length || !VerifyFrame(view.Bytes(), expected_tag)) {
      corrupted.store(true, std::memory_order_relaxed);
      ring.CommitRead();
      break;
    }
    ring.CommitRead();
    ++received;
  }

  producer.join();
  CHECK_FALSE(corrupted.load());
  CHECK(received == kTotal);
  CHECK(ring.TotalEnqueued() == kTotal);
  CHECK(ring.TotalDequeued() == kTotal);
}

}  // TEST_SUITE("common.frame_ring")
