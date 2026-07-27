// C ABI 实现层的内部工具。**不对外安装**，只在 src/capi 内部使用。
//
// 这里集中处理「C++ 世界 ↔ C 世界」的三件重复劳动：把 std::string_view 拷进
// 定长缓冲、把 tetherkit::Error 翻译成 tk_error_t、取墙上时间。
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string_view>

#include "tetherkit/capi/tetherkit_c.h"
#include "tetherkit/common/error.h"

namespace tetherkit::capi {

/// 把文本拷进定长缓冲并保证 NUL 结尾，超长时截断。
///
/// ★ 截断必须落在 UTF-8 的字符边界上 ★
///   本项目的错误消息全是中文，一个汉字 3 字节。按字节硬切会在缓冲末尾留下
///   半个字符，Swift 侧 `String(cString:)` 遇到非法序列会**整串变成替换字符**，
///   等于把整条错误信息毁掉。所以截断后要退回到最近的字符起点。
inline void CopyText(char* destination, std::size_t capacity, std::string_view text) noexcept {
  if (destination == nullptr || capacity == 0) {
    return;
  }
  std::size_t length = text.size() < capacity - 1 ? text.size() : capacity - 1;

  // length < text.size() 说明发生了截断：若切点落在了某个多字节序列的中间
  // （text[length] 是 0b10xxxxxx 的续接字节），就一路退到该序列的起点。
  while (length > 0 && length < text.size() &&
         (static_cast<unsigned char>(text[length]) & 0xC0U) == 0x80U) {
    --length;
  }

  std::memcpy(destination, text.data(), length);
  destination[length] = '\0';
}

/// 数组版本，省掉每处都写 sizeof。
template <std::size_t N>
inline void CopyText(char (&destination)[N], std::string_view text) noexcept {
  CopyText(destination, N, text);
}

/// 把 C++ 侧的错误翻译成 C 结构体。`out_error` 可为 nullptr（调用方不关心原因）。
inline void FillError(tk_error_t* out_error, const Error& error) noexcept {
  if (out_error == nullptr) {
    return;
  }
  out_error->domain = static_cast<std::int32_t>(error.Domain());
  out_error->code = error.Code();
  // 用 ToString() 而非 Context()：前者带上了「[libusb: LIBUSB_ERROR_ACCESS(-3)]」
  // 这样的域与码，用户报错时能直接贴给我们。
  CopyText(out_error->message, error.ToString());
}

/// 填一条没有底层错误码的纯逻辑错误。
inline void FillGenericError(tk_error_t* out_error, std::string_view message) noexcept {
  if (out_error == nullptr) {
    return;
  }
  out_error->domain = TK_ERROR_DOMAIN_GENERIC;
  out_error->code = 0;
  CopyText(out_error->message, message);
}

/// 把错误结构体清成「无错误」。成功路径上调用，避免调用方读到上一次的残留。
inline void ClearError(tk_error_t* out_error) noexcept {
  if (out_error == nullptr) {
    return;
  }
  out_error->domain = TK_ERROR_DOMAIN_GENERIC;
  out_error->code = 0;
  out_error->message[0] = '\0';
}

/// 自 Unix 纪元的墙上时间（纳秒）。
///
/// 事件与日志用墙上时间而非单调时间：它们要显示给人看，并且要能和 Console.app
/// 里的系统日志对齐。速率计算另有单调时间，见 tk_session_status.monotonic_nanos。
[[nodiscard]] std::int64_t WallNanos() noexcept;

/// 校验网卡名：只接受 `feth<数字>`。
///
/// 这不是洁癖 —— 网卡名会被拼进 `ipconfig` / `route` 的 argv。虽然我们用
/// posix_spawn 传数组而非过 shell（本身已经杜绝了注入），但把接口名限制成
/// 我们自己创建过的那种形态，还能挡住「误把 en0 传进来，把用户的 Wi-Fi 配置
/// 冲掉」这类更现实的事故。
[[nodiscard]] bool IsValidFethName(std::string_view name) noexcept;

}  // namespace tetherkit::capi
