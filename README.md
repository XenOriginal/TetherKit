# TetherKit

**macOS 用户态 RNDIS 驱动** —— 不写内核扩展，把 RNDIS 设备（Android 手机的 USB 网络共享、
Windows Phone、嵌入式 Linux gadget 等）变成一张 macOS 系统可见的网卡。

- **USB 侧**：[libusb](https://libusb.info/) 异步批量传输，完整实现 RNDIS 主机侧状态机。
- **网卡侧**：macOS 的 `feth`（`if_fake`）虚拟网卡对 + BPF，直接读写原始以太帧。
- **无内核代码**：纯用户态 C++23，不需要 kext、不需要 DriverKit、不需要关 SIP。

> ⚠️ **状态**：全部模块已实现，168 个测试用例（6453 条断言）在
> 普通构建与 ThreadSanitizer 构建下均通过。但**尚未在真实 RNDIS 设备上联调过**
> —— 开发机没有任何 USB 设备。待验证清单见 [AGENTS.md](AGENTS.md) 第 6 节。

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

## 构建

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
./build/bin/tetherkit --list

# 启动驱动
sudo ./build/bin/tetherkit

# 另开一个终端，给新出现的网卡配 IP（RNDIS 设备通常自带 DHCP 服务器）
sudo ipconfig set feth0 DHCP
ipconfig getifaddr feth0
```

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

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **总体设计**：为什么选 feth+BPF、模块划分、并发模型、拆除顺序、私有 ABI 的风险评估 |
| [docs/RNDIS-PROTOCOL.md](docs/RNDIS-PROTOCOL.md) | **协议参考**：字段偏移、状态码、OID、状态机、设备 quirk。含三条最容易搞错的规则 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | **调优指南**：旋钮、怎么判断瓶颈、已知限制 |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | **基准结果**（自动生成）+ 测量方法与已知局限 |
| [AGENTS.md](AGENTS.md) | 实现备忘：已实测确认的环境事实、进度、**踩过的坑**、待验证清单 |

---

## 许可

见 [LICENSE](LICENSE)。
