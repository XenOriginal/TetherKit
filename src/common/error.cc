#include "tetherkit/common/error.h"

#include <libusb.h>

#include <cstring>
#include <format>

namespace tetherkit {
namespace {

/// 把 RNDIS_STATUS_* 翻译成名字。
///
/// 这里只覆盖 host 侧真正会收到的状态码；未知值回落到十六进制输出。
/// 数值定义与 include/tetherkit/rndis/protocol.h 保持一致，此处刻意不 include
/// rndis 头文件 —— tk_common 不允许依赖上层模块。
std::string_view RndisStatusName(std::uint32_t status) {
  switch (status) {
    case 0x00000000U:
      return "RNDIS_STATUS_SUCCESS";
    case 0x00000103U:
      return "RNDIS_STATUS_PENDING";
    case 0x4001000BU:
      return "RNDIS_STATUS_MEDIA_CONNECT";
    case 0x4001000CU:
      return "RNDIS_STATUS_MEDIA_DISCONNECT";
    case 0x40010012U:
      return "RNDIS_STATUS_LINK_SPEED_CHANGE";
    case 0x80000005U:
      return "RNDIS_STATUS_BUFFER_TOO_SHORT";
    case 0xC0000001U:
      return "RNDIS_STATUS_FAILURE";
    case 0xC0000010U:
      return "RNDIS_STATUS_INVALID_LENGTH";
    case 0xC000000DU:
      return "RNDIS_STATUS_INVALID_DATA";
    case 0xC00000BBU:
      return "RNDIS_STATUS_NOT_SUPPORTED";
    case 0xC000009AU:
      return "RNDIS_STATUS_RESOURCES";
    case 0xC0010015U:
      return "RNDIS_STATUS_INVALID_OID";
    default:
      return {};
  }
}

}  // namespace

std::string Error::ToString() const {
  switch (domain_) {
    case ErrorDomain::kGeneric:
      return context_;

    case ErrorDomain::kErrno: {
      const int err = static_cast<int>(code_);
      return std::format("{} [errno: {}({})]", context_, std::strerror(err), err);
    }

    case ErrorDomain::kLibUsb: {
      const int rc = static_cast<int>(code_);
      return std::format("{} [libusb: {}({})]", context_, libusb_error_name(rc), rc);
    }

    case ErrorDomain::kRndis: {
      const auto status = static_cast<std::uint32_t>(code_);
      const std::string_view name = RndisStatusName(status);
      if (name.empty()) {
        return std::format("{} [RNDIS_STATUS: {:#010x}]", context_, status);
      }
      return std::format("{} [RNDIS_STATUS: {}({:#010x})]", context_, name, status);
    }
  }
  return context_;
}

}  // namespace tetherkit
