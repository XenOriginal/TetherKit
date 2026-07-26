// 缓存相关的编译期常量。
#pragma once

#include <cstddef>

namespace tetherkit {

/// 缓存行大小。
///
/// **不要**改用 std::hardware_destructive_interference_size —— Apple libc++
/// 没有提供这个常量（实测编译报错）。
///
/// 取 128 而非习惯性的 64：Apple Silicon 的 `sysctl hw.cachelinesize` 报 128。
/// 按 64 对齐的话，生产者与消费者的索引仍可能落在同一条 128 字节缓存行上，
/// false sharing 依然存在，无锁队列的吞吐会掉一个数量级。
///
/// x86-64 上是 64，但本项目仅支持 macOS/arm64，统一取 128 不会浪费太多
/// （多出的填充只影响少数几个队列对象，不影响数据缓冲区）。
inline constexpr std::size_t kCacheLineSize = 128;

/// 让成员独占一条缓存行的对齐说明符。
#define TETHERKIT_CACHE_ALIGNED alignas(::tetherkit::kCacheLineSize)

}  // namespace tetherkit
