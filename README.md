# TetherKit

[English](README.en.md) | **简体中文**

**macOS 用户态 RNDIS 驱动** —— 不写内核扩展，把 RNDIS 设备（Android 手机的 USB 网络共享、
Windows Phone、嵌入式 Linux gadget 等）变成一张 macOS 系统可见的网卡。

- **USB 侧**：[libusb](https://libusb.info/) 异步批量传输，完整实现 RNDIS 主机侧状态机。
- **网卡侧**：macOS 的 `feth`（`if_fake`）虚拟网卡对 + BPF，直接读写原始以太帧。
- **无内核代码**：纯用户态 C++23，不需要 kext、不需要 DriverKit、不需要关 SIP。

> ⚠️ **状态**：全部模块已实现，169 个测试用例（6458 条断言）在
> 普通构建与 ThreadSanitizer 构建下均通过。已在一台真实 RNDIS 设备上跑通
> RNDIS 握手、feth 建对、BPF 挂载与优雅停机；`feth` 私有 ABI 与
> 「BPF 写入能让对侧 IP 栈收到帧」这个核心前提也已实测确认。
> **端到端吞吐尚未做过任何压测。** 验证清单见 [AGENTS.md](AGENTS.md) 第 6 节。

---

## 为什么需要它

macOS 内核**没有** RNDIS 驱动。插上开了 USB 网络共享的 Android 手机，系统不会出现新网卡。
既有方案要么写 kext（需要关 SIP、签名门槛高、系统更新易失效），要么走 Network Extension
（需要开发者账号 + 系统扩展审批）。TetherKit 选择第三条路：**在用户态同时扮演 USB 主机和
网卡驱动**。

---

## 架构

```
        ┌──────────────────────────── macOS 内核 ────────────────────────────┐
        │                                                                    │
        │   IP 栈 / 路由 / DHCP 客户端                                        │
        │        │                                                           │
        │        ▼                                                           │
        │   ┌─────────┐   if_fake peer 对   ┌─────────┐                       │
        │   │  feth0  │ ◄─────────────────► │  feth1  │                       │
        │   │(系统侧) │                     │(驱动侧) │                       │
        │   └─────────┘                     └────┬────┘                      │
        │    配 IP/路由                          │ BPF                       │
        └────────────────────────────────────────┼───────────────────────────┘
                                                 │ read()/write() 原始以太帧
        ┌────────────────────────────────────────┼───────────────────────────┐
        │                     TetherKit（用户态） │                           │
        │                                        ▼                           │
        │   ┌──────────────────── 数据路径桥接 ─────────────────────┐         │
        │   │  TX: BPF 批量读 → 聚合多帧 → RNDIS_PACKET_MSG → bulk OUT│        │
        │   │  RX: bulk IN → 拆 RNDIS_PACKET_MSG → SPSC 队列 → BPF 写 │        │
        │   └───────────────────────────┬───────────────────────────┘         │
        │                               │                                     │
        │   ┌──────────── RNDIS 状态机 ──┴──────────────┐                      │
        │   │ INITIALIZE / QUERY / SET / KEEPALIVE /   │                      │
        │   │ RESET / INDICATE_STATUS / HALT           │                      │
        │   └───────────────────────────┬──────────────┘                      │
        │                               │                                     │
        │   ┌────────── libusb ─────────┴──────────────┐                      │
        │   │ 控制通道：SEND_ENCAPSULATED_COMMAND /     │                      │
        │   │           GET_ENCAPSULATED_RESPONSE      │                      │
        │   │ 通知通道：中断 IN（RESPONSE_AVAILABLE）    │                      │
        │   │ 数据通道：bulk IN / bulk OUT（异步池化）   │                      │
        │   └───────────────────────────┬──────────────┘                      │
        └───────────────────────────────┼─────────────────────────────────────┘
                                        │ USB
                                   ┌────┴─────┐
                                   │ RNDIS 设备 │
                                   └──────────┘
```

---

## 安装

```bash
brew install XiaoMiku01/tap/tetherkit
```

从源码构建，十几秒装完，`libusb` 会被自动带上。tap 仓库在
[XiaoMiku01/homebrew-tap](https://github.com/XiaoMiku01/homebrew-tap)。

升级：

```bash
brew upgrade tetherkit
```

也可以从 [Releases](https://github.com/XiaoMiku01/TetherKit/releases) 直接下预编译二进制
（仅 arm64）。但它**没有签名**，浏览器下载后会被 Gatekeeper 隔离，得手动解除：

```bash
xattr -d com.apple.quarantine tetherkit
```

介意这一步的话就走上面的 Homebrew，或者按下一节自己构建 —— 本地构建的产物不带隔离属性。

---

## 从源码构建

依赖：macOS 13.3+、Xcode 命令行工具（Apple clang 支持 C++23）、CMake ≥ 3.24、libusb 1.0。

```bash
brew install libusb cmake
```

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

产物：`build/bin/tetherkit`。

### 构建选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `TETHERKIT_BUILD_TESTS` | `ON` | 构建单元测试 |
| `TETHERKIT_BUILD_BENCHMARKS` | `ON` | 构建性能基准 |
| `TETHERKIT_WARNINGS_AS_ERRORS` | `OFF` | 警告当错误 |
| `TETHERKIT_NATIVE_ARCH` | `OFF` | `-mcpu=native`，产物不可移植 |
| `TETHERKIT_ENABLE_LTO` | `OFF` | 链接时优化 |
| `TETHERKIT_ENABLE_ASAN` | `OFF` | AddressSanitizer |
| `TETHERKIT_ENABLE_UBSAN` | `OFF` | UndefinedBehaviorSanitizer |
| `TETHERKIT_ENABLE_TSAN` | `OFF` | ThreadSanitizer（**验证无锁数据结构必备**） |

---

## 测试

```bash
ctest --test-dir build --output-on-failure
```

无锁队列与多线程数据路径的正确性用 ThreadSanitizer 单独验证：

```bash
cmake -S . -B build-tsan -DTETHERKIT_ENABLE_TSAN=ON
cmake --build build-tsan -j
ctest --test-dir build-tsan --output-on-failure
```

---

## 性能基准

```bash
cmake -S . -B build-rel -DCMAKE_BUILD_TYPE=Release
cmake --build build-rel -j
./build-rel/bin/tetherkit_bench
```

汇总结果见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)。

---

## 运行

```bash
# 先看看设备有没有被识别（**不需要 root**）
tetherkit --list

# 启动驱动
sudo tetherkit

# 另开一个终端，给新出现的网卡配 IP（RNDIS 设备通常自带 DHCP 服务器）
sudo ipconfig set feth0 DHCP
ipconfig getifaddr feth0
```

> 下面的命令都按已安装（`tetherkit` 在 PATH 里）来写。从源码构建的话把
> `tetherkit` 换成 `./build/bin/tetherkit` 即可。

启动成功后程序会打印它创建的网卡名与后续命令。按 `Ctrl-C` 优雅退出
（会先让设备退出 RNDIS，再销毁网卡）。

常用选项（完整列表见 `--help`）：

| 选项 | 说明 |
|---|---|
| `--list` | 列出识别到的 RNDIS 设备后退出，不需要 root |
| `--vid` / `--pid` | 指定设备（十六进制），用于多设备场景 |
| `--stats 1000` | 每秒打印一行吞吐/丢包统计 |
| `--log debug` | 打开协议交互细节日志 |
| `--max-transfer-kb` | 吞吐的主要调优旋钮，见 [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |

### 为什么需要 root

| 操作 | 需要 root？ | 原因 |
|---|---|---|
| 创建 / 销毁 `feth` | ✔ | 内核对 `SIOCIFCREATE2` / `SIOCSDRVSPEC` 有 `proc_suser` 检查 |
| 打开 `/dev/bpf*` | ✔ | 节点是 `0600 root:wheel`，且 macOS **没有** FreeBSD 的 `access_bpf` 组 |
| libusb 声明 RNDIS 接口 | ✘ | macOS 内核**没有** RNDIS 驱动，接口本来就没人占。非沙箱命令行程序不需要 root、也不需要 entitlement |

也就是说 root 是网卡侧的要求，不是 USB 侧的。`--list` 因此不需要 root。

---

## 故障排查

| 现象 | 原因与对策 |
|---|---|
| `--list` 找不到设备 | ① 换一根**数据线**（很多线只供电）；② 在设备上开启「USB 网络共享 / USB tethering」；③ 解锁手机并信任本机。用 `system_profiler SPUSBDataType` 确认系统是否看到该设备 |
| `声明 RNDIS 数据接口失败 [libusb: LIBUSB_ERROR_ACCESS]` | 接口被别的东西占了。检查是否装过 HoRNDIS 之类的第三方 kext，或有别的用户态程序在用该设备 |
| `创建 feth 虚拟网卡需要 root` | 用 `sudo` 运行 |
| `sysctl net.link.fake.hwcsum 当前是 1，要求 0` | 这批开关在 feth **创建时被快照**，创建后改无效。按提示先 `sudo sysctl -w net.link.fake.hwcsum=0` 再启动 |
| `ipconfig set feth0 DHCP` 拿不到地址 | 确认设备侧的网络共享真的开着；用 `--stats 1000` 看 TX 有没有帧发出去、RX 有没有回包 |
| 网卡配好了但上不了网 | 默认路由还指向原来的网卡。`sudo route -n change default $(ipconfig getoption feth0 router)`，注意这会顶掉现有默认路由 |
| 吞吐远低于预期 | 看启动日志里的「设备聚合上限 N 包」与「链路批量写」两项，再对照 [docs/PERFORMANCE.md](docs/PERFORMANCE.md) 的排查表 |
| 重启后网卡不见了 | `ipconfig set` 建立的是**临时**服务，只存活到下一次网络配置变更，且不出现在系统设置里。这是 macOS 的限制，不是 bug |

---

## 图形界面

命令行之外还有一个 SwiftUI 图形界面，把「选设备 → 连接 → 配 IP」做成了三步点击，
并实时显示吞吐与日志。

它由两部分组成：`TetherKit.app` 以**普通用户身份**运行，需要 root 的操作交给一个
由 launchd 按需拉起的特权组件 `tetherkit-helper`，每次调用都附带一份用户刚确认过
的授权凭据。App 本身不需要任何 entitlement。

```bash
# 1. 先构建 C++ 部分（产出 libtetherkit.dylib）
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j

# 2. 构建界面与特权组件（需要 Xcode 工具链）
cmake --build build --target gui        # 等价于 ./gui/Scripts/build-gui.sh

# 3. 运行
open dist/TetherKit.app
```

首次运行界面会引导安装特权组件：点「安装特权组件」、在系统授权框里输一次
管理员密码即可，装好后界面自动恢复。特权组件的安装载荷内嵌在 .app 里
（`Contents/Library/HelperTools/`），偏好终端的话效果完全相同：

```bash
sudo ./gui/Scripts/install-helper.sh
```

卸载：仪表盘底部有「卸载特权组件…」按钮（终端等价命令
`sudo ./gui/Scripts/uninstall-helper.sh`）。

界面里可以配置**上网方式**：

| 方式 | 说明 |
|---|---|
| 自动（DHCP） | 交给系统的 IPConfiguration，租约、DNS、路由全部自动配好。绝大多数手机都自带 DHCP 服务器，推荐 |
| 静态 IP | 手动指定 IP、子网掩码、网关与 DNS。输入时即时校验（含子网掩码的连续性） |

另有一个「让所有流量默认走这张网卡」开关。不开时只有绑定到本网卡的流量走它；
本机没有别的可用网络时通常不需要开 —— 系统会自己把它选为主服务。

**后台运行**：关闭主窗口后 App 驻留菜单栏（程序坞图标隐藏），菜单栏项实时
显示上/下行速率；点开是一块小面板，可随时回到主窗口或退出。已建立的连接由
特权组件持有，即使退出界面也不会断。

**要求**：macOS 14+（命令行部分仍支持 13.3+）。实现细节与设计取舍见
[docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md)。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **总体设计**：为什么选 feth+BPF、模块划分、并发模型、拆除顺序、私有 ABI 的风险评估 |
| [docs/RNDIS-PROTOCOL.md](docs/RNDIS-PROTOCOL.md) | **协议参考**：字段偏移、状态码、OID、状态机、设备 quirk。含三条最容易搞错的规则 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | **调优指南**：旋钮、怎么判断瓶颈、已知限制 |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | **基准结果**（自动生成）+ 测量方法与已知局限 |
| [docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md) | **图形界面**：进程与信任模型、数据流、实现约束、已实现/未实现清单 |
| [docs/GUI-SPIKE.md](docs/GUI-SPIKE.md) | **可行性验证**：为什么这么做特权提升，以及被排除的三条路线 |
| [AGENTS.md](AGENTS.md) | 实现备忘：已实测确认的环境事实、进度、**踩过的坑**、待验证清单 |

---

## 许可

见 [LICENSE](LICENSE)。
