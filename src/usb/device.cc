#include "tetherkit/usb/device.h"

#include <cstring>
#include <format>

#include "tetherkit/common/byte_order.h"
#include "tetherkit/common/logging.h"

namespace tetherkit::usb {
namespace {

/// CDC 功能描述符类型（bDescriptorType = CS_INTERFACE）。
constexpr std::uint8_t kCsInterfaceDescriptorType = 0x24;
/// CDC Union 功能描述符子类型。
constexpr std::uint8_t kUnionFunctionalSubtype = 0x06;
/// CDC ACM 功能描述符子类型（用于识别真 cdc-acm 调制解调器）。
constexpr std::uint8_t kAcmFunctionalSubtype = 0x02;

/// Android quirk 的硬编码接口号（与 Linux 的 android_rndis_quirk 一致）。
constexpr std::uint8_t kAndroidQuirkControlInterface = 0;
constexpr std::uint8_t kAndroidQuirkDataInterface = 1;

/// 取接口的 class/subclass/protocol 三元组。
[[nodiscard]] rndis::InterfaceSignature SignatureOf(
    const ::libusb_interface_descriptor& descriptor) {
  return rndis::InterfaceSignature{descriptor.bInterfaceClass, descriptor.bInterfaceSubClass,
                                   descriptor.bInterfaceProtocol};
}

/// 在接口的 extra 描述符里找 CDC 功能描述符。
///
/// 返回 nullptr 表示没找到。`out_length` 输出该描述符的总长度。
[[nodiscard]] const std::uint8_t* FindCdcFunctional(const ::libusb_interface_descriptor& descriptor,
                                                    std::uint8_t subtype,
                                                    std::uint8_t& out_length) {
  const std::uint8_t* cursor = descriptor.extra;
  int remaining = descriptor.extra_length;

  // CDC 功能描述符链的通用格式：[bLength][bDescriptorType][bDescriptorSubtype][...]
  while (remaining >= 3) {
    const std::uint8_t length = cursor[0];
    if (length < 3 || length > remaining) {
      break;  // 描述符链损坏，停止解析
    }
    if (cursor[1] == kCsInterfaceDescriptorType && cursor[2] == subtype) {
      out_length = length;
      return cursor;
    }
    cursor += length;
    remaining -= length;
  }
  out_length = 0;
  return nullptr;
}

/// 判断是不是「伪 RNDIS」—— 真正的 CDC ACM 调制解调器。
///
/// 判据：class == 0x02 且带**非零** bmCapabilities 的 ACM 功能描述符。
/// **这条检查只能对 class == 0x02 生效** —— 无线类（0xE0）的 RNDIS function
/// 会把 bmCapabilities 字段挪作自用，对它套这条规则会把真 RNDIS 误判掉。
[[nodiscard]] bool LooksLikeRealAcmModem(const ::libusb_interface_descriptor& descriptor) {
  if (descriptor.bInterfaceClass != 0x02) {
    return false;
  }
  std::uint8_t length = 0;
  const std::uint8_t* acm = FindCdcFunctional(descriptor, kAcmFunctionalSubtype, length);
  if (acm == nullptr || length < 4) {
    return false;
  }
  // 布局：[bLength][CS_INTERFACE][ACM subtype][bmCapabilities]
  return acm[3] != 0;
}

/// 从 CDC Union 功能描述符里取第一个 slave 接口号。
///
/// 布局：[bLength][CS_INTERFACE][UNION subtype][bMasterInterface][bSlaveInterface0]...
[[nodiscard]] bool TryReadUnionSlaveInterface(const ::libusb_interface_descriptor& descriptor,
                                             std::uint8_t& out_slave) {
  std::uint8_t length = 0;
  const std::uint8_t* onion = FindCdcFunctional(descriptor, kUnionFunctionalSubtype, length);
  if (onion == nullptr || length < 5) {
    return false;
  }
  out_slave = onion[4];
  return true;
}

/// 某个配置里是否存在指定接口号，且它的签名是 RNDIS 数据接口。
[[nodiscard]] bool HasDataInterface(const ::libusb_config_descriptor& config,
                                    std::uint8_t interface_number) {
  for (std::uint8_t i = 0; i < config.bNumInterfaces; ++i) {
    const ::libusb_interface& interface = config.interface[i];
    for (int alt = 0; alt < interface.num_altsetting; ++alt) {
      const ::libusb_interface_descriptor& descriptor = interface.altsetting[alt];
      if (descriptor.bInterfaceNumber != interface_number) {
        continue;
      }
      if (SignatureOf(descriptor) == rndis::kDataSignature) {
        return true;
      }
    }
  }
  return false;
}

}  // namespace

std::string DeviceCandidate::Describe() const {
  return std::format("Bus {:03d} Device {:03d}: {:04x}:{:04x}", bus_number, device_address,
                     vendor_id, product_id);
}

// =============================================================================
// 设备发现
// =============================================================================

Result<std::vector<DeviceCandidate>> FindRndisDevices(const Context& context,
                                                      const DeviceFilter& filter) {
  ::libusb_device** raw_list = nullptr;
  const ssize_t count = ::libusb_get_device_list(context.Raw(), &raw_list);
  if (count < 0) {
    return std::unexpected(
        Error::FromLibUsb(static_cast<int>(count), "libusb_get_device_list 失败"));
  }
  // RAII 释放设备列表（unref_devices = 1）。
  const std::unique_ptr<::libusb_device*, void (*)(::libusb_device**)> list_guard(
      raw_list, [](::libusb_device** list) { ::libusb_free_device_list(list, 1); });

  std::vector<DeviceCandidate> candidates;

  for (ssize_t index = 0; index < count; ++index) {
    ::libusb_device* device = raw_list[index];

    ::libusb_device_descriptor device_descriptor{};
    if (::libusb_get_device_descriptor(device, &device_descriptor) != LIBUSB_SUCCESS) {
      continue;
    }

    if (filter.vendor_id != 0 && device_descriptor.idVendor != filter.vendor_id) {
      continue;
    }
    if (filter.product_id != 0 && device_descriptor.idProduct != filter.product_id) {
      continue;
    }
    const std::uint8_t bus = ::libusb_get_bus_number(device);
    const std::uint8_t address = ::libusb_get_device_address(device);
    if (filter.bus_number != 0 && (bus != filter.bus_number || address != filter.device_address)) {
      continue;
    }

    // 逐个配置找 RNDIS 通信接口。多数设备只有一个配置，但也有例外。
    for (std::uint8_t config_index = 0; config_index < device_descriptor.bNumConfigurations;
         ++config_index) {
      ::libusb_config_descriptor* config = nullptr;
      if (::libusb_get_config_descriptor(device, config_index, &config) != LIBUSB_SUCCESS) {
        continue;
      }
      const std::unique_ptr<::libusb_config_descriptor, void (*)(::libusb_config_descriptor*)>
          config_guard(config, &::libusb_free_config_descriptor);

      for (std::uint8_t i = 0; i < config->bNumInterfaces; ++i) {
        const ::libusb_interface& interface = config->interface[i];
        for (int alt = 0; alt < interface.num_altsetting; ++alt) {
          const ::libusb_interface_descriptor& descriptor = interface.altsetting[alt];
          const rndis::InterfaceSignature signature = SignatureOf(descriptor);

          if (!rndis::IsRndisControlSignature(signature)) {
            continue;
          }
          if (LooksLikeRealAcmModem(descriptor)) {
            TETHERKIT_DEBUG(
                "{:04x}:{:04x} 接口 {} 签名像 RNDIS，但带非零 ACM bmCapabilities，"
                "判定为真 cdc-acm 调制解调器，跳过",
                device_descriptor.idVendor, device_descriptor.idProduct,
                descriptor.bInterfaceNumber);
            continue;
          }

          DeviceCandidate candidate;
          candidate.vendor_id = device_descriptor.idVendor;
          candidate.product_id = device_descriptor.idProduct;
          candidate.bus_number = bus;
          candidate.device_address = address;
          candidate.control_interface = descriptor.bInterfaceNumber;
          candidate.signature = signature;

          // 找配对的数据接口：优先 CDC Union 描述符。
          std::uint8_t slave = 0;
          bool resolved = false;
          if (TryReadUnionSlaveInterface(descriptor, slave) &&
              HasDataInterface(*config, slave)) {
            candidate.data_interface = slave;
            resolved = true;
          }

          // Android quirk：许多 Android 设备的 CDC Union 指向不存在的接口号，
          // 或者干脆没有 CDC 功能描述符。Linux 的 android_rndis_quirk 在这种
          // 情况下硬编码「接口 0 = control、接口 1 = data」，并要求被 probe 的
          // 通信接口确实是 0。这里照做。
          if (!resolved && candidate.control_interface == kAndroidQuirkControlInterface &&
              HasDataInterface(*config, kAndroidQuirkDataInterface)) {
            candidate.data_interface = kAndroidQuirkDataInterface;
            candidate.used_android_quirk = true;
            resolved = true;
          }

          if (!resolved) {
            TETHERKIT_DEBUG(
                "{} 的接口 {} 是 RNDIS 通信接口，但找不到配对的数据接口，跳过",
                candidate.Describe(), candidate.control_interface);
            continue;
          }

          TETHERKIT_INFO(
              "发现 RNDIS 设备 {}：通信接口 {}、数据接口 {}，签名 {:02x}/{:02x}/{:02x}{}",
              candidate.Describe(), candidate.control_interface, candidate.data_interface,
              signature.interface_class, signature.interface_subclass,
              signature.interface_protocol,
              candidate.used_android_quirk ? "（走了 Android quirk 兜底）" : "");
          candidates.push_back(candidate);
          // 一个设备只取第一个匹配的通信接口。
          goto next_device;
        }
      }
    }
  next_device:;
  }

  return candidates;
}

// =============================================================================
// Device
// =============================================================================

Result<std::unique_ptr<Device>> Device::Open(const Context& context,
                                             const DeviceCandidate& candidate) {
  ::libusb_device** raw_list = nullptr;
  const ssize_t count = ::libusb_get_device_list(context.Raw(), &raw_list);
  if (count < 0) {
    return std::unexpected(
        Error::FromLibUsb(static_cast<int>(count), "libusb_get_device_list 失败"));
  }
  const std::unique_ptr<::libusb_device*, void (*)(::libusb_device**)> list_guard(
      raw_list, [](::libusb_device** list) { ::libusb_free_device_list(list, 1); });

  // 按总线 + 地址定位设备（比 VID:PID 精确，能区分同型号的多个设备）。
  ::libusb_device* target = nullptr;
  for (ssize_t index = 0; index < count; ++index) {
    if (::libusb_get_bus_number(raw_list[index]) == candidate.bus_number &&
        ::libusb_get_device_address(raw_list[index]) == candidate.device_address) {
      target = raw_list[index];
      break;
    }
  }
  if (target == nullptr) {
    return std::unexpected(
        Error::Generic(std::format("设备 {} 已不在总线上", candidate.Describe())));
  }

  auto device = std::unique_ptr<Device>(new Device());
  device->candidate_ = candidate;
  device->description_ = candidate.Describe();
  device->speed_ = ::libusb_get_device_speed(target);

  const int open_rc = ::libusb_open(target, &device->handle_);
  if (open_rc != LIBUSB_SUCCESS) {
    return std::unexpected(Error::FromLibUsb(
        open_rc, std::format("打开设备 {} 失败", device->description_)));
  }

  // **刻意不调用 libusb_set_auto_detach_kernel_driver** —— 见头文件说明：
  // 在 macOS 上它会触发破坏性的整设备重新枚举，而 RNDIS 接口本来就没人占。

  // 声明两个接口。通信接口在前，因为控制通道要用它。
  const auto claim = [&device](std::uint8_t interface_number, std::string_view role,
                               bool& claimed_flag) -> Status {
    const int rc = ::libusb_claim_interface(device->handle_, interface_number);
    if (rc == LIBUSB_SUCCESS) {
      claimed_flag = true;
      return Ok();
    }
    Error error = Error::FromLibUsb(
        rc, std::format("声明{}（接口 {}）失败", role, interface_number));
    if (rc == LIBUSB_ERROR_ACCESS) {
      return std::unexpected(std::move(error).WithContext(
          "接口被内核驱动独占。macOS 本身没有 RNDIS 驱动，出现这种情况通常意味着"
          "装了 HoRNDIS 之类的第三方 kext，或有别的用户态程序已经声明了该接口"));
    }
    if (rc == LIBUSB_ERROR_NOT_FOUND) {
      return std::unexpected(std::move(error).WithContext(
          "接口不存在。可能是设备切换了配置，或描述符解析有误"));
    }
    return std::unexpected(std::move(error));
  };

  TETHERKIT_RETURN_IF_ERROR(
      claim(candidate.control_interface, "RNDIS 通信接口", device->control_interface_claimed_));
  TETHERKIT_RETURN_IF_ERROR(
      claim(candidate.data_interface, "RNDIS 数据接口", device->data_interface_claimed_));

  // 解析端点。
  ::libusb_config_descriptor* config = nullptr;
  const int config_rc = ::libusb_get_active_config_descriptor(target, &config);
  if (config_rc != LIBUSB_SUCCESS) {
    return std::unexpected(Error::FromLibUsb(config_rc, "读取活动配置描述符失败"));
  }
  const std::unique_ptr<::libusb_config_descriptor, void (*)(::libusb_config_descriptor*)>
      config_guard(config, &::libusb_free_config_descriptor);

  TETHERKIT_RETURN_IF_ERROR(device->ResolveEndpoints(*config));

  TETHERKIT_INFO(
      "已声明 {}（{}）：bulk IN 0x{:02x} / OUT 0x{:02x}（wMaxPacketSize {}），"
      "中断 IN {}",
      device->description_, device->SpeedName(), device->bulk_in_endpoint_,
      device->bulk_out_endpoint_, device->bulk_max_packet_size_,
      device->interrupt_in_endpoint_ == 0
          ? std::string{"无（将退化为轮询控制端点）"}
          : std::format("0x{:02x}", device->interrupt_in_endpoint_));

  return device;
}

Device::~Device() {
  if (handle_ == nullptr) {
    return;
  }
  // 顺序：释放接口 → 关闭句柄。
  //
  // ⚠️ 前置条件：所有异步 transfer 必须已经全部回收。libusb_close **不会**帮你
  // 回收在飞 transfer（只是把 dev_handle 置空并打日志），之后 IOKit 中止仍会让
  // 回调在 libusb 内部线程上跑 —— 那时若 transfer 已被 free 就是 UAF。
  // 保证这一点是 TransferPool 的责任，见它的 Shutdown()。
  if (data_interface_claimed_) {
    ::libusb_release_interface(handle_, candidate_.data_interface);
  }
  if (control_interface_claimed_) {
    ::libusb_release_interface(handle_, candidate_.control_interface);
  }
  ::libusb_close(handle_);
  handle_ = nullptr;
  TETHERKIT_DEBUG("已关闭设备 {}", description_);
}

Status Device::ResolveEndpoints(const ::libusb_config_descriptor& config) {
  for (std::uint8_t i = 0; i < config.bNumInterfaces; ++i) {
    const ::libusb_interface& interface = config.interface[i];
    for (int alt = 0; alt < interface.num_altsetting; ++alt) {
      const ::libusb_interface_descriptor& descriptor = interface.altsetting[alt];
      const bool is_data = descriptor.bInterfaceNumber == candidate_.data_interface;
      const bool is_control = descriptor.bInterfaceNumber == candidate_.control_interface;
      if (!is_data && !is_control) {
        continue;
      }

      for (std::uint8_t e = 0; e < descriptor.bNumEndpoints; ++e) {
        const ::libusb_endpoint_descriptor& endpoint = descriptor.endpoint[e];
        const auto type = static_cast<std::uint8_t>(endpoint.bmAttributes &
                                                    LIBUSB_TRANSFER_TYPE_MASK);
        const bool is_in = (endpoint.bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                           LIBUSB_ENDPOINT_IN;

        if (is_data && type == LIBUSB_TRANSFER_TYPE_BULK) {
          if (is_in && bulk_in_endpoint_ == 0) {
            bulk_in_endpoint_ = endpoint.bEndpointAddress;
            bulk_max_packet_size_ = endpoint.wMaxPacketSize;
          } else if (!is_in && bulk_out_endpoint_ == 0) {
            bulk_out_endpoint_ = endpoint.bEndpointAddress;
            if (bulk_max_packet_size_ == 0) {
              bulk_max_packet_size_ = endpoint.wMaxPacketSize;
            }
          }
        } else if (is_control && type == LIBUSB_TRANSFER_TYPE_INTERRUPT && is_in &&
                   interrupt_in_endpoint_ == 0) {
          interrupt_in_endpoint_ = endpoint.bEndpointAddress;
          interrupt_max_packet_size_ = endpoint.wMaxPacketSize;
        }
      }
    }
  }

  if (bulk_in_endpoint_ == 0 || bulk_out_endpoint_ == 0) {
    return std::unexpected(Error::Generic(std::format(
        "数据接口 {} 上找不到成对的 bulk 端点（IN=0x{:02x}, OUT=0x{:02x}）",
        candidate_.data_interface, bulk_in_endpoint_, bulk_out_endpoint_)));
  }
  if (bulk_max_packet_size_ == 0) {
    return std::unexpected(Error::Generic("bulk 端点的 wMaxPacketSize 为 0"));
  }
  // 中断端点缺失是合法的：Linux 的 host 驱动干脆完全忽略它，改为轮询控制端点。
  return Ok();
}

std::string_view Device::SpeedName() const noexcept {
  switch (speed_) {
    case LIBUSB_SPEED_LOW:
      return "low-speed 1.5Mbps";
    case LIBUSB_SPEED_FULL:
      return "full-speed 12Mbps";
    case LIBUSB_SPEED_HIGH:
      return "high-speed 480Mbps";
    case LIBUSB_SPEED_SUPER:
      return "SuperSpeed 5Gbps";
    case LIBUSB_SPEED_SUPER_PLUS:
      return "SuperSpeed+ 10Gbps";
    default:
      return "未知速度";
  }
}

Status Device::ClearHalt(std::uint8_t endpoint) {
  const int rc = ::libusb_clear_halt(handle_, endpoint);
  if (rc != LIBUSB_SUCCESS) {
    return std::unexpected(
        Error::FromLibUsb(rc, std::format("清除端点 0x{:02x} 的 halt 状态失败", endpoint)));
  }
  return Ok();
}

// =============================================================================
// UsbControlChannel
// =============================================================================

UsbControlChannel::UsbControlChannel(Device& device, std::uint32_t timeout_millis)
    : device_(&device), timeout_millis_(timeout_millis) {
  response_buffer_.resize(rndis::kControlBufferBytes);
  notification_buffer_.resize(rndis::kNotificationBytes);
}

Status UsbControlChannel::SendMessage(std::span<const std::byte> message) {
  if (message.empty() || message.size() > 0xFFFF) {
    return std::unexpected(
        Error::Generic(std::format("控制消息长度 {} 非法", message.size())));
  }

  // SEND_ENCAPSULATED_COMMAND：bmRequestType=0x21（OUT|Class|Interface）,
  // bRequest=0x00, wValue=0, wIndex=通信类接口号, wLength=消息长度。
  const int transferred = ::libusb_control_transfer(
      device_->Handle(), rndis::kControlOutRequestType, rndis::kRequestSendEncapsulatedCommand,
      /*wValue=*/0, device_->Candidate().control_interface,
      // libusb 的 C 接口要 unsigned char*，此处不修改内容。
      const_cast<unsigned char*>(reinterpret_cast<const unsigned char*>(message.data())),
      static_cast<std::uint16_t>(message.size()), timeout_millis_);

  if (transferred < 0) {
    return std::unexpected(Error::FromLibUsb(
        transferred, "SEND_ENCAPSULATED_COMMAND 失败"));
  }
  if (static_cast<std::size_t>(transferred) != message.size()) {
    return std::unexpected(Error::Generic(
        std::format("SEND_ENCAPSULATED_COMMAND 只发出 {} / {} 字节", transferred,
                    message.size())));
  }
  return Ok();
}

Result<std::span<const std::byte>> UsbControlChannel::ReceiveMessage() {
  // 每次读之前清零：设备可能只写一部分，残留的旧数据会让解析器读到幻影字段。
  std::memset(response_buffer_.data(), 0, response_buffer_.size());

  // GET_ENCAPSULATED_RESPONSE：bmRequestType=0xA1（IN|Class|Interface）,
  // bRequest=0x01, wValue=0, wIndex=通信类接口号。
  const int transferred = ::libusb_control_transfer(
      device_->Handle(), rndis::kControlInRequestType, rndis::kRequestGetEncapsulatedResponse,
      /*wValue=*/0, device_->Candidate().control_interface,
      reinterpret_cast<unsigned char*>(response_buffer_.data()),
      static_cast<std::uint16_t>(response_buffer_.size()), timeout_millis_);

  if (transferred < 0) {
    return std::unexpected(
        Error::FromLibUsb(transferred, "GET_ENCAPSULATED_RESPONSE 失败"));
  }

  // 规范：设备尚无有效响应时返回 **1 字节 0x00**，而不是 STALL。
  // 因此不足一个 RNDIS 消息头（8 字节）的结果一律当作「还没准备好」，
  // 返回空视图让调用方重试 —— 这**不是**错误。
  if (static_cast<std::uint32_t>(transferred) < rndis::kMessageHeaderBytes) {
    return std::span<const std::byte>{};
  }
  return std::span<const std::byte>{response_buffer_.data(),
                                    static_cast<std::size_t>(transferred)};
}

rndis::NotificationResult UsbControlChannel::WaitForNotification(std::uint32_t timeout_millis) {
  if (device_->InterruptInEndpoint() == 0) {
    return rndis::NotificationResult::kNotSupported;
  }

  int transferred = 0;
  const int rc = ::libusb_interrupt_transfer(
      device_->Handle(), device_->InterruptInEndpoint(),
      reinterpret_cast<unsigned char*>(notification_buffer_.data()),
      static_cast<int>(notification_buffer_.size()), &transferred, timeout_millis);

  if (rc == LIBUSB_ERROR_TIMEOUT) {
    return rndis::NotificationResult::kTimeout;
  }
  if (rc != LIBUSB_SUCCESS) {
    // 中断端点出错不该让整条链路失败 —— Linux 的 host 驱动干脆完全不用它。
    // 降级为「当作超时」，调用方会去轮询控制端点。
    TETHERKIT_DEBUG("中断 IN 传输返回 {}，退化为轮询控制端点", ::libusb_error_name(rc));
    return rndis::NotificationResult::kTimeout;
  }
  if (static_cast<std::uint32_t>(transferred) < rndis::kNotificationBytes) {
    TETHERKIT_DEBUG("中断 IN 只收到 {} 字节（期望 {}），退化为轮询", transferred,
                    rndis::kNotificationBytes);
    return rndis::NotificationResult::kTimeout;
  }

  // 通知是两个 LE32：[0] = Notification，[4] = Reserved。
  // 注意这**不是** CDC 的 usb_cdc_notification 结构，而是 RNDIS 自有格式。
  const std::uint32_t notification =
      LoadLe32(notification_buffer_.data() + rndis::kNotificationValueOffset);
  if (notification != rndis::kNotificationResponseAvailable) {
    TETHERKIT_DEBUG("中断 IN 收到未知通知 {:#010x}，忽略", notification);
    return rndis::NotificationResult::kTimeout;
  }
  return rndis::NotificationResult::kResponseAvailable;
}

}  // namespace tetherkit::usb
