#include "capi_support.h"

#include <algorithm>
#include <ctime>

namespace tetherkit::capi {

std::int64_t WallNanos() noexcept {
  ::timespec now{};
  ::clock_gettime(CLOCK_REALTIME, &now);
  return (static_cast<std::int64_t>(now.tv_sec) * 1'000'000'000) +
         static_cast<std::int64_t>(now.tv_nsec);
}

bool IsValidFethName(std::string_view name) noexcept {
  constexpr std::string_view kPrefix = "feth";
  // 名字还要塞得进内核的 IFNAMSIZ 缓冲。
  if (name.size() <= kPrefix.size() || name.size() >= TK_INTERFACE_NAME_CAPACITY) {
    return false;
  }
  if (!name.starts_with(kPrefix)) {
    return false;
  }
  return std::ranges::all_of(name.substr(kPrefix.size()),
                             [](char character) { return character >= '0' && character <= '9'; });
}

}  // namespace tetherkit::capi
