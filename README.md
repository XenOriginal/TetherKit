# TetherKit

**macOS 用户态 RNDIS 驱动** —— 不写内核扩展，把 RNDIS 设备（Android 手机的 USB 网络共享、
Windows Phone、嵌入式 Linux gadget 等）变成一张 macOS 系统可见的网卡。

- **USB 侧**：[libusb](https://libusb.info/) 异步批量传输，完整实现 RNDIS 主机侧状态机。
- **网卡侧**：macOS 的 `feth`（`if_fake`）虚拟网卡对 + BPF，直接读写原始以太帧。
- **无内核代码**：纯用户态 C++23，不需要 kext、不需要 DriverKit、不需要关 SIP。

> ⚠️ 项目正在开发中。当前进度见 [AGENTS.md](AGENTS.md) 第 5 节。

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

## 运行与权限

TetherKit 需要 **root** 权限，原因有三：

1. 创建 / 销毁 `feth` 虚拟网卡需要 root（非 root 下 `SIOCIFCREATE2` 返回 `EPERM`）。
2. 打开 `/dev/bpf*` 需要 root（默认属主 `root:wheel`，模式 `0600`）。
3. 在 macOS 上通过 libusb 独占声明 USB 接口通常也需要 root。

```bash
sudo ./build/bin/tetherkit
```

详细的权限说明与故障排查见 [docs/](docs/)（开发中）。

---

## 文档

| 文档 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 实现备忘：已验证的环境事实、进度、已知坑、待验证清单 |
| [docs/DESIGN.md](docs/DESIGN.md) | 总体设计：模块划分、并发模型、性能取舍 |
| [docs/RNDIS-PROTOCOL.md](docs/RNDIS-PROTOCOL.md) | RNDIS 线格式与状态机参考 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | 性能设计与调优参数 |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | 基准结果汇总 |

---

## 许可

见 [LICENSE](LICENSE)。
