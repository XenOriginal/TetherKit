#include "tetherkit/net/feth_device.h"

#include <ifaddrs.h>
#include <net/if_dl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <format>
#include <memory>
#include <utility>

#include "tetherkit/common/logging.h"
#include "tetherkit/net/darwin_abi.h"

namespace tetherkit::net {
namespace {

/// 一个只用来发 ioctl 的临时套接字。
///
/// 接口相关的 ioctl 需要一个 socket 作为句柄；用 AF_INET/SOCK_DGRAM 是惯例
/// （ifconfig 也是这么做的），并不真的收发数据。
class IoctlSocket {
 public:
  [[nodiscard]] static Result<IoctlSocket> Open() {
    const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
      return std::unexpected(Error::FromErrno(0, "创建用于接口 ioctl 的套接字失败"));
    }
    return IoctlSocket{fd};
  }

  IoctlSocket(const IoctlSocket&) = delete;
  IoctlSocket& operator=(const IoctlSocket&) = delete;

  IoctlSocket(IoctlSocket&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}

  IoctlSocket& operator=(IoctlSocket&& other) noexcept {
    if (this != &other) {
      Close();
      fd_ = std::exchange(other.fd_, -1);
    }
    return *this;
  }

  ~IoctlSocket() { Close(); }

  [[nodiscard]] int Fd() const noexcept { return fd_; }

  /// 发一次 ioctl，失败时把 errno 与调用名包进 Error。
  [[nodiscard]] Status Call(unsigned long request, void* argument, std::string_view what) const {
    if (::ioctl(fd_, request, argument) < 0) {
      return std::unexpected(Error::FromErrno(0, std::string{what}));
    }
    return Ok();
  }

 private:
  explicit IoctlSocket(int fd) : fd_(fd) {}

  void Close() noexcept {
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
  }

  int fd_ = -1;
};

/// 填一个只带接口名的 ifreq。
[[nodiscard]] Result<::ifreq> MakeIfreq(std::string_view name) {
  if (name.size() >= kInterfaceNameCapacity) {
    return std::unexpected(Error::Generic(
        std::format("接口名 \"{}\" 超过 {} 字节上限", name, kInterfaceNameCapacity - 1)));
  }
  ::ifreq request{};
  std::memcpy(request.ifr_name, name.data(), name.size());
  return request;
}

/// 读一个 32 位整型 sysctl。
[[nodiscard]] Result<std::int32_t> ReadInt32Sysctl(const char* name) {
  std::int32_t value = 0;
  std::size_t size = sizeof(value);
  if (::sysctlbyname(name, &value, &size, nullptr, 0) != 0) {
    return std::unexpected(Error::FromErrno(0, std::format("读取 sysctl {} 失败", name)));
  }
  return value;
}

/// 对 feth 发一次驱动私有 ioctl。
[[nodiscard]] Status CallFethDriverIoctl(const IoctlSocket& socket, std::string_view interface_name,
                                        unsigned long ioctl_request, unsigned long command,
                                        FethRequest& payload, std::string_view what) {
  if (interface_name.size() >= kInterfaceNameCapacity) {
    return std::unexpected(Error::Generic(std::format("接口名 \"{}\" 过长", interface_name)));
  }

  IfDrv driver{};
  std::memcpy(driver.ifd_name, interface_name.data(), interface_name.size());
  driver.ifd_cmd = command;
  // 内核校验 ifd_len >= sizeof(struct if_fake_request)，短了直接 EINVAL。
  driver.ifd_len = sizeof(payload);
  driver.ifd_data = &payload;

  return socket.Call(ioctl_request, &driver, what);
}

}  // namespace

std::array<char, 18> FormatMac(const MacAddress& mac) noexcept {
  std::array<char, 18> text{};
  std::snprintf(text.data(), text.size(), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2],
                mac[3], mac[4], mac[5]);
  return text;
}

bool IsRunningAsRoot() noexcept {
  return ::geteuid() == 0;
}

Result<std::uint32_t> QueryFethMaxMtu() {
  TETHERKIT_ASSIGN_OR_RETURN(const std::int32_t value, ReadInt32Sysctl("net.link.fake.max_mtu"));
  if (value <= 0) {
    return std::unexpected(
        Error::Generic(std::format("net.link.fake.max_mtu 返回了非法值 {}", value)));
  }
  return static_cast<std::uint32_t>(value);
}

Status VerifyFethSysctls() {
  for (const RequiredFethSysctl& entry : kRequiredFethSysctls) {
    const auto value = ReadInt32Sysctl(entry.name);
    if (!value) {
      // 某些 sysctl 在特定 macOS 版本上可能不存在；缺失不算错误，只记一条。
      TETHERKIT_DEBUG("sysctl {} 不可读（{}），跳过校验", entry.name, value.error().ToString());
      continue;
    }
    if (*value != entry.required_value) {
      return std::unexpected(Error::Generic(std::format(
          "sysctl {} 当前是 {}，要求 {}。原因：{}。\n"
          "  这个开关在 feth 创建时被快照进接口，创建后再改无效，因此必须先修正：\n"
          "    sudo sysctl -w {}={}",
          entry.name, *value, entry.required_value, entry.why, entry.name,
          entry.required_value)));
    }
  }
  return Ok();
}

// =============================================================================
// FethInterface
// =============================================================================

FethInterface::FethInterface(FethInterface&& other) noexcept
    : name_(std::exchange(other.name_, {})) {}

FethInterface& FethInterface::operator=(FethInterface&& other) noexcept {
  if (this != &other) {
    Destroy();
    name_ = std::exchange(other.name_, {});
  }
  return *this;
}

FethInterface::~FethInterface() {
  Destroy();
}

void FethInterface::Destroy() noexcept {
  if (name_.empty()) {
    return;
  }
  const std::string name = std::exchange(name_, {});

  const auto socket = IoctlSocket::Open();
  if (!socket) {
    TETHERKIT_ERROR("销毁 {} 失败：{}", name, socket.error().ToString());
    return;
  }
  auto request = MakeIfreq(name);
  if (!request) {
    TETHERKIT_ERROR("销毁 {} 失败：{}", name, request.error().ToString());
    return;
  }
  // feth_clone_destroy 内部会自动先解绑 peer，无需我们先 Unpeer。
  if (const auto status = socket->Call(SIOCIFDESTROY, &*request, "ioctl(SIOCIFDESTROY)"); !status) {
    TETHERKIT_ERROR("销毁 {} 失败：{}", name, status.error().ToString());
    return;
  }
  TETHERKIT_INFO("已销毁虚拟网卡 {}", name);
}

Result<FethInterface> FethInterface::Create(std::string_view requested_name) {
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());

  // 名字为空 → 填驱动名 "feth" 作为通配，内核选最小空闲编号并写回完整名字。
  const std::string_view name_to_request =
      requested_name.empty() ? std::string_view{kFethCloneName} : requested_name;
  TETHERKIT_ASSIGN_OR_RETURN(::ifreq request, MakeIfreq(name_to_request));

  // SIOCIFCREATE 与 SIOCIFCREATE2 对 feth 完全等价 —— feth_clone_create 忽略
  // params，而 SIOCIFCREATE2 唯一的区别就是多传一个 params 指针。用简单的那个。
  if (const auto status = socket.Call(SIOCIFCREATE, &request, "ioctl(SIOCIFCREATE)"); !status) {
    Error error = status.error();
    if (error.Code() == EPERM) {
      return std::unexpected(std::move(error).WithContext(
          "创建 feth 虚拟网卡需要 root 权限，请用 sudo 运行"));
    }
    if (error.Code() == EEXIST) {
      return std::unexpected(std::move(error).WithContext(
          std::format("接口 {} 已存在，请换一个名字或先销毁它", name_to_request)));
    }
    return std::unexpected(std::move(error).WithContext(
        std::format("创建 feth 虚拟网卡 {} 失败", name_to_request)));
  }

  // 通配创建时内核把完整名字（含编号）写回 ifr_name。
  std::string created_name(request.ifr_name,
                           ::strnlen(request.ifr_name, kInterfaceNameCapacity));
  TETHERKIT_INFO("已创建虚拟网卡 {}", created_name);
  return FethInterface{std::move(created_name)};
}

Status FethInterface::PeerWith(const FethInterface& peer) {
  if (!Valid() || !peer.Valid()) {
    return std::unexpected(Error::Generic("配对失败：接口对象无效"));
  }
  if (peer.Name().size() >= kInterfaceNameCapacity) {
    return std::unexpected(Error::Generic(std::format("peer 接口名 \"{}\" 过长", peer.Name())));
  }

  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());

  // reserved 字段保持全零 —— 内核会校验，非零直接 EINVAL。
  FethRequest payload{};
  std::memcpy(payload.u.peer_name, peer.Name().data(), peer.Name().size());

  if (const auto status =
          CallFethDriverIoctl(socket, name_, kSetDriverSpec,
                              static_cast<unsigned long>(FethSetCommand::kSetPeer), payload,
                              "ioctl(SIOCSDRVSPEC, IF_FAKE_S_CMD_SET_PEER)");
      !status) {
    Error error = status.error();
    if (error.Code() == EPERM) {
      return std::unexpected(
          std::move(error).WithContext("配对 feth 需要 root 权限，请用 sudo 运行"));
    }
    if (error.Code() == EINVAL) {
      return std::unexpected(std::move(error).WithContext(std::format(
          "把 {} 与 {} 配对被内核拒绝。可能原因：其中一方已有 peer、"
          "对端不是 feth 接口、或当前 macOS 版本的 if_fake 私有 ABI 有变动",
          name_, peer.Name())));
    }
    return std::unexpected(
        std::move(error).WithContext(std::format("把 {} 与 {} 配对失败", name_, peer.Name())));
  }

  TETHERKIT_INFO("已把 {} 与 {} 配对", name_, peer.Name());
  return Ok();
}

Status FethInterface::Unpeer() {
  if (!Valid()) {
    return std::unexpected(Error::Generic("解绑失败：接口对象无效"));
  }
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());

  // 空 peer 名（首字节 '\0'）即表示解绑。
  FethRequest payload{};
  TETHERKIT_RETURN_IF_ERROR(CallFethDriverIoctl(
      socket, name_, kSetDriverSpec, static_cast<unsigned long>(FethSetCommand::kSetPeer), payload,
      "ioctl(SIOCSDRVSPEC, IF_FAKE_S_CMD_SET_PEER) 解绑"));
  return Ok();
}

Result<std::string> FethInterface::QueryPeer() const {
  if (!Valid()) {
    return std::unexpected(Error::Generic("查询 peer 失败：接口对象无效"));
  }
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());

  FethRequest payload{};
  TETHERKIT_RETURN_IF_ERROR(CallFethDriverIoctl(
      socket, name_, kGetDriverSpec, static_cast<unsigned long>(FethGetCommand::kGetPeer), payload,
      "ioctl(SIOCGDRVSPEC, IF_FAKE_G_CMD_GET_PEER)"));

  return std::string(payload.u.peer_name,
                     ::strnlen(payload.u.peer_name, kInterfaceNameCapacity));
}

Status FethInterface::SetMtu(std::uint32_t mtu) {
  if (!Valid()) {
    return std::unexpected(Error::Generic("设置 MTU 失败：接口对象无效"));
  }
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());
  TETHERKIT_ASSIGN_OR_RETURN(::ifreq request, MakeIfreq(name_));
  request.ifr_mtu = static_cast<int>(mtu);

  if (const auto status = socket.Call(SIOCSIFMTU, &request, "ioctl(SIOCSIFMTU)"); !status) {
    Error error = status.error();
    if (error.Code() == EINVAL) {
      const auto limit = QueryFethMaxMtu();
      return std::unexpected(std::move(error).WithContext(std::format(
          "把 {} 的 MTU 设为 {} 被拒绝（feth 的 MTU 上限是 {}，由 sysctl "
          "net.link.fake.max_mtu 决定，且该值在接口创建时已被快照）",
          name_, mtu, limit ? std::format("{}", *limit) : "未知")));
    }
    return std::unexpected(
        std::move(error).WithContext(std::format("把 {} 的 MTU 设为 {} 失败", name_, mtu)));
  }
  return Ok();
}

Result<std::uint32_t> FethInterface::QueryMtu() const {
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());
  TETHERKIT_ASSIGN_OR_RETURN(::ifreq request, MakeIfreq(name_));
  TETHERKIT_RETURN_IF_ERROR(socket.Call(SIOCGIFMTU, &request, "ioctl(SIOCGIFMTU)"));
  return static_cast<std::uint32_t>(request.ifr_mtu);
}

Status FethInterface::SetMacAddress(const MacAddress& mac) {
  if (!Valid()) {
    return std::unexpected(Error::Generic("设置 MAC 失败：接口对象无效"));
  }
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());
  TETHERKIT_ASSIGN_OR_RETURN(::ifreq request, MakeIfreq(name_));

  // feth_ioctl 直接把 ifr_addr 转给 ifnet_set_lladdr(ifp, sa_data, sa_len)，
  // 只看 sa_len 与 sa_data，不校验 sa_family。
  request.ifr_addr.sa_len = static_cast<std::uint8_t>(mac.size());
  request.ifr_addr.sa_family = AF_LINK;
  std::memcpy(request.ifr_addr.sa_data, mac.data(), mac.size());

  if (const auto status = socket.Call(SIOCSIFLLADDR, &request, "ioctl(SIOCSIFLLADDR)"); !status) {
    Error error = status.error();
    if (error.Code() == EPERM) {
      return std::unexpected(
          std::move(error).WithContext("修改接口 MAC 需要 root 权限，请用 sudo 运行"));
    }
    return std::unexpected(std::move(error).WithContext(
        std::format("把 {} 的 MAC 设为 {} 失败", name_, FormatMac(mac).data())));
  }
  TETHERKIT_INFO("已把 {} 的 MAC 设为 {}", name_, FormatMac(mac).data());
  return Ok();
}

Result<MacAddress> FethInterface::QueryMacAddress() const {
  // 读 MAC 走 getifaddrs + AF_LINK 而非 ioctl：macOS 的 SDK 只提供
  // SIOCSIFLLADDR（写），没有对应的读 ioctl。getifaddrs 是 BSD 上读链路地址的
  // 标准做法，且不需要额外权限。
  ::ifaddrs* list = nullptr;
  if (::getifaddrs(&list) != 0) {
    return std::unexpected(Error::FromErrno(0, "getifaddrs 失败"));
  }
  // 用 RAII 保证任何返回路径都释放链表。
  const std::unique_ptr<::ifaddrs, decltype(&::freeifaddrs)> guard(list, &::freeifaddrs);

  for (const ::ifaddrs* entry = list; entry != nullptr; entry = entry->ifa_next) {
    if (entry->ifa_addr == nullptr || entry->ifa_addr->sa_family != AF_LINK) {
      continue;
    }
    if (name_ != entry->ifa_name) {
      continue;
    }
    const auto* link = reinterpret_cast<const ::sockaddr_dl*>(entry->ifa_addr);
    if (link->sdl_alen != sizeof(MacAddress)) {
      return std::unexpected(Error::Generic(std::format(
          "{} 的链路地址长度是 {} 字节，不是 6 字节 MAC", name_, link->sdl_alen)));
    }
    MacAddress mac{};
    std::memcpy(mac.data(), LLADDR(link), mac.size());
    return mac;
  }
  return std::unexpected(
      Error::Generic(std::format("在 getifaddrs 结果里找不到接口 {} 的链路地址", name_)));
}

Status FethInterface::SetUp(bool up) {
  if (!Valid()) {
    return std::unexpected(Error::Generic("设置接口状态失败：接口对象无效"));
  }
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());
  TETHERKIT_ASSIGN_OR_RETURN(::ifreq request, MakeIfreq(name_));

  // 先读回当前 flags 再改，避免把别的标志位清掉。
  TETHERKIT_RETURN_IF_ERROR(socket.Call(SIOCGIFFLAGS, &request, "ioctl(SIOCGIFFLAGS)"));

  // ifr_flags 是 short，而 IFF_* 在 64 位下可能超出 short 范围，
  // 因此按 macOS 的惯例用 uint16 掩码运算。
  auto flags = static_cast<std::uint16_t>(request.ifr_flags);
  if (up) {
    flags |= static_cast<std::uint16_t>(IFF_UP);
  } else {
    flags &= static_cast<std::uint16_t>(~static_cast<std::uint16_t>(IFF_UP));
  }
  request.ifr_flags = static_cast<short>(flags);

  if (const auto status = socket.Call(SIOCSIFFLAGS, &request, "ioctl(SIOCSIFFLAGS)"); !status) {
    Error error = status.error();
    if (error.Code() == EPERM) {
      return std::unexpected(
          std::move(error).WithContext("修改接口 UP/DOWN 需要 root 权限，请用 sudo 运行"));
    }
    return std::unexpected(std::move(error).WithContext(
        std::format("把 {} 置为 {} 失败", name_, up ? "UP" : "DOWN")));
  }
  return Ok();
}

Result<bool> FethInterface::IsUp() const {
  TETHERKIT_ASSIGN_OR_RETURN(const auto socket, IoctlSocket::Open());
  TETHERKIT_ASSIGN_OR_RETURN(::ifreq request, MakeIfreq(name_));
  TETHERKIT_RETURN_IF_ERROR(socket.Call(SIOCGIFFLAGS, &request, "ioctl(SIOCGIFFLAGS)"));
  return (static_cast<std::uint16_t>(request.ifr_flags) & static_cast<std::uint16_t>(IFF_UP)) != 0;
}

// =============================================================================
// FethPair
// =============================================================================

Result<FethPair> FethPair::Create(std::uint32_t mtu, const MacAddress* system_mac) {
  if (!IsRunningAsRoot()) {
    return std::unexpected(Error::Generic(
        "创建 feth 虚拟网卡需要 root 权限。请用 sudo 运行 TetherKit。"));
  }

  // 1. 校验创建期会被快照的 sysctl —— **必须在创建之前**。
  TETHERKIT_RETURN_IF_ERROR(VerifyFethSysctls());

  TETHERKIT_ASSIGN_OR_RETURN(const std::uint32_t max_mtu, QueryFethMaxMtu());
  if (mtu > max_mtu) {
    return std::unexpected(Error::Generic(std::format(
        "请求的 MTU {} 超过 feth 上限 {}（sysctl net.link.fake.max_mtu）", mtu, max_mtu)));
  }

  // 2. 创建两张接口。
  TETHERKIT_ASSIGN_OR_RETURN(FethInterface system_side, FethInterface::Create());
  TETHERKIT_ASSIGN_OR_RETURN(FethInterface driver_side, FethInterface::Create());

  // 3. 配对 —— 在 UP 之前做，这样链路从一开始就是 up 的。
  TETHERKIT_RETURN_IF_ERROR(driver_side.PeerWith(system_side));

  // 4. 两侧 MTU 必须一致，否则一侧能发的帧另一侧收不下。
  TETHERKIT_RETURN_IF_ERROR(system_side.SetMtu(mtu));
  TETHERKIT_RETURN_IF_ERROR(driver_side.SetMtu(mtu));

  // 5. 设系统侧 MAC —— **必须在 UP 之前**。
  //    驱动侧刻意保留内核分配的地址：两侧 MAC 必须不同，否则 IPv6 链路本地
  //    地址相同会触发 DAD 冲突。
  if (system_mac != nullptr) {
    TETHERKIT_RETURN_IF_ERROR(system_side.SetMacAddress(*system_mac));

    const auto driver_mac = driver_side.QueryMacAddress();
    if (driver_mac && *driver_mac == *system_mac) {
      return std::unexpected(Error::Generic(std::format(
          "两侧 MAC 相同（{}），会触发 IPv6 DAD 地址冲突", FormatMac(*system_mac).data())));
    }
  }

  // 6. 两侧都置 UP。
  //    bpfwrite 里有硬检查：接口不是 IFF_UP 就返回 ENETDOWN。
  TETHERKIT_RETURN_IF_ERROR(driver_side.SetUp(true));
  TETHERKIT_RETURN_IF_ERROR(system_side.SetUp(true));

  TETHERKIT_INFO("虚拟网卡对就绪：系统侧 {} ←→ 驱动侧 {}（MTU {}）", system_side.Name(),
                 driver_side.Name(), mtu);
  return FethPair{std::move(system_side), std::move(driver_side)};
}

}  // namespace tetherkit::net
