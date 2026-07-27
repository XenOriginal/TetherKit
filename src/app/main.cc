// TetherKit 命令行入口。
//
// 职责刻意保持很薄：解析参数 → 装配 RuntimeConfig → 交给 core::Runtime →
// 处理信号。所有实质逻辑都在库里，这样才能被单元测试覆盖。
#include <signal.h>  // NOLINT(modernize-deprecated-headers) —— sigaction 只在此头文件里
#include <unistd.h>

#include <atomic>
#include <charconv>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <string>
#include <string_view>
#include <thread>

#include "tetherkit/common/logging.h"
#include "tetherkit/core/runtime.h"
#include "tetherkit/version.h"

namespace {

using tetherkit::Error;
using tetherkit::LogLevel;
using tetherkit::Result;
using tetherkit::Status;

/// 全局停机标志。
///
/// 进程级的信号状态天然是全局的，无法避免；用无锁原子保证安全后不再包装。
// NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
/// **信号处理器里只能碰 volatile sig_atomic_t 或无锁原子**，绝不能加锁、
/// 分配内存或打日志 —— 那些都不是异步信号安全的。这里只写一个原子，
/// 真正的停机由主线程在看到它之后执行。
std::atomic<bool> g_stop_requested{false};

extern "C" void HandleSignal(int /*signal_number*/) {
  g_stop_requested.store(true, std::memory_order_release);
}

/// 安装信号处理器。
///
/// 用 sigaction 而非 signal()：后者的语义在各 Unix 上不一致，
/// 而且默认会在处理器执行期间重置为 SIG_DFL。
[[nodiscard]] Status InstallSignalHandlers() {
  struct sigaction action{};
  action.sa_handler = &HandleSignal;
  // 注意：macOS 上 sigemptyset 是**宏**（#define sigemptyset(set) (*(set)=0,0)），
  // 不能写成 ::sigemptyset —— 宏名无法被作用域限定。
  sigemptyset(&action.sa_mask);
  // 刻意**不设** SA_RESTART：我们希望信号能打断阻塞的系统调用（例如 BPF 的
  // read()），让线程有机会看到停机标志。
  action.sa_flags = 0;

  for (const int signal_number : {SIGINT, SIGTERM, SIGHUP}) {
    if (::sigaction(signal_number, &action, nullptr) != 0) {
      return std::unexpected(
          Error::FromErrno(0, std::format("安装信号 {} 的处理器失败", signal_number)));
    }
  }

  // 忽略 SIGPIPE：往已关闭的 BPF 描述符写会触发它，默认行为是终止进程。
  struct sigaction ignore{};
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  if (::sigaction(SIGPIPE, &ignore, nullptr) != 0) {
    return std::unexpected(Error::FromErrno(0, "忽略 SIGPIPE 失败"));
  }
  return tetherkit::Ok();
}

// =============================================================================
// 命令行解析
// =============================================================================

void PrintUsage() {
  std::fputs(
      "用法：sudo tetherkit-cli [选项]\n"
      "\n"
      "  macOS 用户态 RNDIS 驱动：把 RNDIS 设备（Android USB 网络共享等）\n"
      "  变成一张系统可见的网卡。\n"
      "\n"
      "设备选择：\n"
      "  --vid <十六进制>      只匹配指定 USB 厂商 ID（如 18d1）\n"
      "  --pid <十六进制>      只匹配指定 USB 产品 ID（如 4ee4）\n"
      "  --list               列出识别到的 RNDIS 设备后退出（**不需要 root**）\n"
      "\n"
      "网卡：\n"
      "  --mtu <字节>          期望 MTU，默认 1500（设备装不下时会自动下调；\n"
      "                       上限受 sysctl net.link.fake.max_mtu 约束）\n"
      "  --keep-feth-mac      不把系统侧网卡的 MAC 改成设备汇报的地址\n"
      "\n"
      "性能调优：\n"
      "  --rx-transfers <n>    并发在飞的 bulk IN 传输数，默认 16\n"
      "  --tx-transfers <n>    并发在飞的 bulk OUT 传输数，默认 4。设备若汇报\n"
      "                       MaxPacketsPerMessage=1，则每帧都是一次独立 USB\n"
      "                       传输，调大此值无益；仅对可聚合多包的设备有意义\n"
      "  --rx-transfer-kb <n>  每个 bulk IN 缓冲的 KiB 数，默认 16\n"
      "  --max-transfer-kb <n> 在 INITIALIZE 里宣称的 MaxTransferSize（KiB），\n"
      "                       默认 16。这是让设备聚合多包的唯一手段，是吞吐的\n"
      "                       主要杠杆；报大一点通常更快\n"
      "  --bpf-buffer-kb <n>   BPF 内核抓包缓冲的 KiB 数，默认 4096\n"
      "\n"
      "其它：\n"
      "  --stats <毫秒>        统计报告周期，0 表示关闭，默认 5000\n"
      "  --log <级别>          trace|debug|info|warn|error|off，默认 info\n"
      "  --no-color           关闭日志彩色输出\n"
      "  -h, --help           显示本帮助\n"
      "  -V, --version        显示版本\n"
      "\n"
      "为什么需要 root：创建 feth 虚拟网卡与打开 /dev/bpf* 都需要 root。\n"
      "USB 侧本身不需要 —— macOS 没有 RNDIS 内核驱动，libusb 能直接声明接口。\n",
      stdout);
}

/// 解析一个无符号整数参数。
[[nodiscard]] Result<std::uint32_t> ParseUint(std::string_view text, int base = 10) {
  std::uint32_t value = 0;
  const char* begin = text.data();
  const char* end = begin + text.size();
  const auto [ptr, error_code] = std::from_chars(begin, end, value, base);
  if (error_code != std::errc{} || ptr != end) {
    return std::unexpected(Error::Generic(std::format("无法解析数值 \"{}\"", text)));
  }
  return value;
}

[[nodiscard]] Result<LogLevel> ParseLogLevel(std::string_view text) {
  if (text == "trace") {
    return LogLevel::kTrace;
  }
  if (text == "debug") {
    return LogLevel::kDebug;
  }
  if (text == "info") {
    return LogLevel::kInfo;
  }
  if (text == "warn") {
    return LogLevel::kWarn;
  }
  if (text == "error") {
    return LogLevel::kError;
  }
  if (text == "off") {
    return LogLevel::kOff;
  }
  return std::unexpected(Error::Generic(std::format("未知日志级别 \"{}\"", text)));
}

/// 解析结果。
struct ParsedArguments {
  tetherkit::core::RuntimeConfig config;
  bool show_help = false;
  bool show_version = false;
  bool list_devices = false;
};

[[nodiscard]] Result<ParsedArguments> ParseArguments(int argc, char** argv) {
  ParsedArguments parsed;

  // 取一个需要值的选项的值。
  const auto take_value = [argc, argv](int& index,
                                       std::string_view option) -> Result<std::string_view> {
    if (index + 1 >= argc) {
      return std::unexpected(Error::Generic(std::format("选项 {} 缺少参数", option)));
    }
    ++index;
    return std::string_view{argv[index]};
  };

  for (int i = 1; i < argc; ++i) {
    const std::string_view argument{argv[i]};

    if (argument == "-h" || argument == "--help") {
      parsed.show_help = true;
      return parsed;
    }
    if (argument == "-V" || argument == "--version") {
      parsed.show_version = true;
      return parsed;
    }
    if (argument == "--list") {
      parsed.list_devices = true;
      continue;
    }
    if (argument == "--keep-feth-mac") {
      parsed.config.adopt_device_mac = false;
      continue;
    }
    if (argument == "--no-color") {
      tetherkit::SetLogColorEnabled(false);
      continue;
    }

    if (argument == "--vid") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(const auto value, ParseUint(text, 16));
      parsed.config.device_filter.vendor_id = static_cast<std::uint16_t>(value);
      continue;
    }
    if (argument == "--pid") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(const auto value, ParseUint(text, 16));
      parsed.config.device_filter.product_id = static_cast<std::uint16_t>(value);
      continue;
    }
    if (argument == "--mtu") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(parsed.config.mtu, ParseUint(text));
      continue;
    }
    if (argument == "--rx-transfers") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(parsed.config.data_channel.rx_transfer_count, ParseUint(text));
      continue;
    }
    if (argument == "--tx-transfers") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(parsed.config.data_channel.tx_transfer_count, ParseUint(text));
      continue;
    }
    if (argument == "--rx-transfer-kb") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(const auto kilobytes, ParseUint(text));
      parsed.config.data_channel.rx_transfer_bytes = kilobytes * 1024;
      continue;
    }
    if (argument == "--max-transfer-kb") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(const auto kilobytes, ParseUint(text));
      parsed.config.rndis.host_max_transfer_size = kilobytes * 1024;
      continue;
    }
    if (argument == "--bpf-buffer-kb") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(const auto kilobytes, ParseUint(text));
      parsed.config.bpf.kernel_buffer_bytes = kilobytes * 1024;
      continue;
    }
    if (argument == "--stats") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(parsed.config.stats_interval_millis, ParseUint(text));
      continue;
    }
    if (argument == "--log") {
      TETHERKIT_ASSIGN_OR_RETURN(const auto text, take_value(i, argument));
      TETHERKIT_ASSIGN_OR_RETURN(const auto level, ParseLogLevel(text));
      tetherkit::SetLogLevel(level);
      continue;
    }

    return std::unexpected(Error::Generic(
        std::format("未知选项 \"{}\"，用 --help 查看用法", argument)));
  }
  return parsed;
}

/// `--list`：列出识别到的 RNDIS 设备。**不需要 root**。
[[nodiscard]] Status ListDevices(const tetherkit::usb::DeviceFilter& filter) {
  TETHERKIT_ASSIGN_OR_RETURN(const auto context, tetherkit::usb::Context::Create());
  TETHERKIT_ASSIGN_OR_RETURN(const auto candidates,
                             tetherkit::usb::FindRndisDevices(*context, filter));

  if (candidates.empty()) {
    std::fputs("没有找到 RNDIS 设备。\n", stdout);
    std::fputs(
        "请检查：① 用的是数据线而非只供电的线；② 设备上已开启 USB 网络共享；\n"
        "        ③ 手机已解锁并信任本机。\n",
        stdout);
    return tetherkit::Ok();
  }

  std::fputs("识别到的 RNDIS 设备：\n", stdout);
  for (const auto& candidate : candidates) {
    const std::string line = std::format(
        "  {}  通信接口 {} / 数据接口 {}  签名 {:02x}/{:02x}/{:02x}{}\n",
        candidate.Describe(), candidate.control_interface, candidate.data_interface,
        candidate.signature.interface_class, candidate.signature.interface_subclass,
        candidate.signature.interface_protocol,
        candidate.used_android_quirk ? "  （走 Android quirk 兜底）" : "");
    std::fputs(line.c_str(), stdout);
  }
  return tetherkit::Ok();
}

}  // namespace

int main(int argc, char** argv) {
  auto parsed = ParseArguments(argc, argv);
  if (!parsed) {
    const std::string message = std::format("参数错误：{}\n", parsed.error().ToString());
    std::fputs(message.c_str(), stderr);
    return 2;
  }

  if (parsed->show_help) {
    PrintUsage();
    return 0;
  }
  if (parsed->show_version) {
    const std::string line = std::format("{}\n{}\n", tetherkit::GetVersionString(),
                                         tetherkit::GetBuildDescription());
    std::fputs(line.c_str(), stdout);
    return 0;
  }

  if (parsed->list_devices) {
    if (const auto status = ListDevices(parsed->config.device_filter); !status) {
      const std::string message = std::format("枚举设备失败：{}\n", status.error().ToString());
      std::fputs(message.c_str(), stderr);
      return 1;
    }
    return 0;
  }

  if (const auto status = InstallSignalHandlers(); !status) {
    TETHERKIT_ERROR("{}", status.error().ToString());
    return 1;
  }

  TETHERKIT_INFO("{}", tetherkit::GetVersionString());

  auto runtime = tetherkit::core::Runtime::Create(parsed->config);
  if (!runtime) {
    TETHERKIT_ERROR("{}", runtime.error().ToString());
    return 1;
  }

  if (const auto status = (*runtime)->Start(); !status) {
    TETHERKIT_ERROR("启动失败：{}", status.error().ToString());
    return 1;
  }

  // 信号处理器里只能置一个原子（异步信号安全的唯一做法），所以需要有人把它
  // 转达给运行时。用一个轻量的守望线程而不是让 Runtime 直接读进程级全局变量 ——
  // 这样 Runtime 不依赖任何全局状态，便于测试。
  std::thread signal_watcher([&runtime] {
    while (!g_stop_requested.load(std::memory_order_acquire)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    TETHERKIT_INFO("收到停机信号");
    (*runtime)->RequestStop();
  });

  // 控制循环跑在 Runtime 自己的线程上（见 core/runtime.h 的线程模型说明），
  // 主线程只需要在这里挂起等它结束。
  (*runtime)->WaitUntilStopped();

  // 控制循环可能是因为内部致命错误退出的（而不是收到信号），
  // 这时也要让守望线程结束。
  g_stop_requested.store(true, std::memory_order_release);
  signal_watcher.join();

  (*runtime)->Stop();

  // 启动序列是异步跑的，失败不会体现在 Start() 的返回值里 —— 从快照里取。
  // 错误内容运行时已经打过日志，这里只负责把退出码带出去，好让脚本能判断。
  const auto snapshot = (*runtime)->Snapshot();
  return snapshot.fatal_message.empty() ? 0 : 1;
}
