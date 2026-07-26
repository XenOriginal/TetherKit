// 轻量分级日志。
//
// 设计约束：
//   1. **禁止出现在数据热路径上。** Trace/Debug 级别在 Release 构建下被
//      预处理器整段删掉（连参数求值都不会发生），所以在热路径写 TETHERKIT_TRACE
//      是安全的；但 Info 及以上会真的做格式化与加锁写 stderr，热路径禁用。
//   2. 线程安全：多线程同时写 stderr 会交错，因此在一把互斥锁下整行输出。
//      日志不在热路径，锁竞争无所谓。
//   3. 不引入第三方日志库：只需要「时间 + 级别 + 线程名 + 位置 + 消息」，
//      std::format 已经够了。
#pragma once

#include <cstdint>
#include <format>
#include <string_view>
#include <utility>

namespace tetherkit {

enum class LogLevel : std::uint8_t {
  kTrace = 0,  ///< 逐帧级别的细节，Release 构建下编译期删除。
  kDebug = 1,  ///< 协议交互细节（每条 RNDIS 控制消息），Release 下编译期删除。
  kInfo = 2,   ///< 生命周期事件（设备连接、状态机迁移、统计报告）。
  kWarn = 3,   ///< 可恢复异常（USB stall、BPF 丢包、保活超时重试）。
  kError = 4,  ///< 不可恢复错误。
  kOff = 5,    ///< 全部关闭。
};

/// 编译期日志下限。低于此级别的日志调用被预处理器整段删除。
///
/// Release 构建（NDEBUG）下把 Trace/Debug 删掉，确保热路径上的
/// TETHERKIT_TRACE 连参数都不求值。
#ifndef TETHERKIT_COMPILED_MIN_LOG_LEVEL
#ifdef NDEBUG
#define TETHERKIT_COMPILED_MIN_LOG_LEVEL 2  // kInfo
#else
#define TETHERKIT_COMPILED_MIN_LOG_LEVEL 0  // kTrace
#endif
#endif

/// 运行期日志下限，默认 kInfo。
void SetLogLevel(LogLevel level) noexcept;

LogLevel GetLogLevel() noexcept;

/// 是否启用彩色输出。默认仅当 stderr 是 tty 时启用。
void SetLogColorEnabled(bool enabled) noexcept;

/// 给当前线程起个短名字，出现在日志行里，便于区分 usb-event / bpf-rx / bpf-tx。
/// 同时调用 pthread_setname_np，使其在 Instruments / lldb 里也可见。
void SetCurrentThreadName(std::string_view name) noexcept;

namespace detail {

[[nodiscard]] bool IsLogLevelEnabled(LogLevel level) noexcept;

/// 输出一整行日志。`message` 已格式化完毕。
void EmitLogLine(LogLevel level, std::string_view file, unsigned line,
                 std::string_view message) noexcept;

/// 从 __FILE__ 里截出文件名，避免日志里出现长路径。
constexpr std::string_view BaseName(std::string_view path) noexcept {
  const auto pos = path.find_last_of('/');
  return pos == std::string_view::npos ? path : path.substr(pos + 1);
}

/// 格式化并输出。故意做成函数模板而非宏内联，缩小宏展开体积。
template <typename... Args>
void LogFormatted(LogLevel level, std::string_view file, unsigned line,
                  std::format_string<Args...> fmt, Args&&... args) noexcept {
  // std::format 可能因内存不足抛异常；日志失败绝不应该拖垮驱动。
  try {
    EmitLogLine(level, file, line, std::format(fmt, std::forward<Args>(args)...));
  } catch (...) {  // NOLINT(bugprone-empty-catch)
    EmitLogLine(LogLevel::kError, file, line, "<日志格式化失败>");
  }
}

}  // namespace detail

/// 日志宏。先做编译期级别裁剪，再做运行期级别判断（分支预测友好）。
#define TETHERKIT_LOG(level, ...)                                                          \
  do {                                                                                     \
    if constexpr (static_cast<int>(level) >= TETHERKIT_COMPILED_MIN_LOG_LEVEL) {            \
      if (::tetherkit::detail::IsLogLevelEnabled(level)) [[unlikely]] {                     \
        ::tetherkit::detail::LogFormatted((level), ::tetherkit::detail::BaseName(__FILE__), \
                                          __LINE__, __VA_ARGS__);                           \
      }                                                                                     \
    }                                                                                       \
  } while (false)

#define TETHERKIT_TRACE(...) TETHERKIT_LOG(::tetherkit::LogLevel::kTrace, __VA_ARGS__)
#define TETHERKIT_DEBUG(...) TETHERKIT_LOG(::tetherkit::LogLevel::kDebug, __VA_ARGS__)
#define TETHERKIT_INFO(...) TETHERKIT_LOG(::tetherkit::LogLevel::kInfo, __VA_ARGS__)
#define TETHERKIT_WARN(...) TETHERKIT_LOG(::tetherkit::LogLevel::kWarn, __VA_ARGS__)
#define TETHERKIT_ERROR(...) TETHERKIT_LOG(::tetherkit::LogLevel::kError, __VA_ARGS__)

}  // namespace tetherkit
