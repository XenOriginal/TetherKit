# AGENTS.md —— TetherKit 实现备忘

> 本文件是给 AI agent（以及接手的人类）看的**工作记忆**。
> 每完成一个提交都要更新对应章节。开始任何工作前先读一遍本文件，避免重复踩坑。

---

## 1. 项目一句话

macOS **用户态** RNDIS 驱动：USB 侧用 libusb 与 RNDIS 设备（Android 手机 USB 网络共享等）
通话，网卡侧用 `feth` 虚拟网卡对 + BPF 直接读写原始以太帧，把设备变成一张系统可见的网卡。

---

## 2. 已实测确认的环境事实（**不要重复验证，直接引用**）

实测机器：macOS 26.5.1 (Darwin 25.5.0)、Apple Silicon arm64、Apple clang 21.0.0。

### 2.1 工具链

| 事实 | 结论 | 验证方式 |
|---|---|---|
| Apple clang 21 的 C++23 | **可用**：`std::expected`、`std::byteswap`、`std::format`、`jthread`、`stop_token`、`latch`、`counting_semaphore` 全部通过编译+运行 | 实测编译运行 |
| `std::expected` / `std::byteswap` 在 `-std=c++20` 下 | **不可用**，是 C++23 库特性。项目因此定为 C++23 | 实测编译报错 |
| `std::format` 浮点格式化 | 依赖 libc++ 的 `std::to_chars`，带 availability 标注，**部署目标必须 ≥ macOS 13.3**，否则编译失败 | 实测 `-mmacosx-version-min=13.0` 报 `'to_chars' is unavailable: introduced in macOS 13.3` |
| `std::hardware_destructive_interference_size` | Apple libc++ **未提供**。必须自己定义缓存行常量 | 实测编译报错 |
| **缓存行大小** | **128 字节**（不是 64！）`hw.cachelinesize: 128`。SPSC 队列的 false-sharing 填充必须按 128 对齐 | `sysctl hw.cachelinesize` |
| L1D 缓存 | 65536 字节 | `sysctl hw.l1dcachesize` |
| CPU | 10 逻辑核，其中 **4 个性能核**（`hw.perflevel0.logicalcpu = 4`）。数据路径线程需要用 QoS 争取性能核 | `sysctl hw.ncpu hw.perflevel0.logicalcpu` |
| `-mcpu=apple-m1` / `-mcpu=native` | 都可用；但默认**不开**（见 `cmake/Optimizations.cmake` 里的取舍说明） | 实测编译 |
| ninja | **未安装**，用默认 Unix Makefiles 生成器 | `which ninja` |
| CMake | 4.3.3 | `cmake --version` |

### 2.2 libusb

| 事实 | 结论 |
|---|---|
| 版本 | 1.0.30.12037，`/opt/homebrew/opt/libusb` |
| pkg-config | 可用。注意头文件目录是 `.../include/libusb-1.0`（非常规），`FindLibUSB.cmake` 已处理 |
| hotplug | `libusb_has_capability(LIBUSB_CAP_HAS_HOTPLUG)` 返回 **1**，支持 |
| 链接依赖 | darwin 后端需要 `IOKit`、`CoreFoundation`、`Security` 三个 framework |
| **本机 USB 设备数** | **0**（`libusb_get_device_list` 返回 0，`ioreg -c IOUSBHostDevice` 也是 0 条）。**开发机上没有任何 USB 设备可用于真机测试** → 所有 USB 逻辑必须能用 mock 后端离线测试 |

### 2.3 BPF（Darwin）

| 事实 | 结论 |
|---|---|
| **零拷贝 BPF** | **不存在**。SDK 的 `net/bpf.h` 里**没有** `BIOCSETZBUF` / `BIOCGETZMAX` / `BIOCROTZBUF`（FreeBSD 有，Darwin 没有）。只能用经典 BPF：大 `BIOCSBLEN` + 批量 `read()` |
| 可用 ioctl 全集 | `BIOCGBLEN`(102R) `BIOCSBLEN`(102WR) `BIOCSETF`(103) `BIOCFLUSH`(104) `BIOCPROMISC`(105) `BIOCGDLT`(106) `BIOCGETIF`(107) `BIOCSETIF`(108) `BIOCSRTIMEOUT`(109) `BIOCGRTIMEOUT`(110) `BIOCGSTATS`(111) `BIOCIMMEDIATE`(112) `BIOCVERSION`(113) `BIOCGRSIG`(114) `BIOCSRSIG`(115) `BIOCGHDRCMPLT`(116) `BIOCSHDRCMPLT`(117) `BIOCGSEESENT`(118) `BIOCSSEESENT`(119) `BIOCSDLT`(120) `BIOCGDLTLIST`(121) `BIOCSETFNR`(126) |
| `struct bpf_hdr` | `{ struct BPF_TIMEVAL bh_tstamp; bpf_u_int32 bh_caplen; bpf_u_int32 bh_datalen; u_short bh_hdrlen; }` —— 遍历时**必须**用 `bh_hdrlen` 而非 `sizeof(bpf_hdr)` |
| 对齐宏 | `BPF_ALIGNMENT = sizeof(int32_t) = 4`，`BPF_WORDALIGN(x) = ((x)+3) & ~3` |
| 设备节点 | `/dev/bpf0..3` 存在（Darwin 按需克隆更多节点） |
| **批量写** | Darwin BPF **不支持**批量写，`write()` 一次一帧。这是 RX 方向的主要成本，架构上必须正视 |

### 2.4 feth（if_fake）

| 事实 | 结论 |
|---|---|
| 是否存在 | **存在**，`sysctl net.link.fake.*` 可见 |
| 关键 sysctl | `net.link.fake.max_mtu = 2048`、`tx_headroom = 32`、`buflet_size = 512`、`qset_cnt = 4`、`link_layer_aggregation_factor = 96` |
| 创建权限 | **需要 root**：非 root 下 `ifconfig feth0 create` 返回 `SIOCIFCREATE2: Operation not permitted` |
| `struct ifdrv` | **不在**公开 SDK 的 `net/if.h` 中，必须自行声明 |
| `net/if_fake_var.h` | **不在**公开 SDK 中，`struct if_fake_request` 与 `IF_FAKE_S_CMD_*` 必须自行声明（私有 ABI，有版本漂移风险 → 需要降级到 `/sbin/ifconfig` 的方案） |
| 相关 ioctl（**在**公开 `sys/sockio.h` 中） | `SIOCSIFFLAGS`(i,16) `SIOCGIFFLAGS`(i,17) `SIOCSIFMTU`(i,52) `SIOCSIFLLADDR`(i,60) `SIOCIFCREATE`(i,120) `SIOCIFDESTROY`(i,121) `SIOCIFCREATE2`(i,122) `SIOCSDRVSPEC`(i,123) `SIOCGDRVSPEC`(i,123) |
| `IFNAMSIZ` | 16 |

### 2.5 开发环境的限制（影响测试策略）

- **无 root**：当前会话以 uid 501 运行，无法创建 feth、无法打开 `/dev/bpf*`。
  → 需要 root 的测试必须**可选、可跳过**，并在 CI/本地用 `TETHERKIT_ROOT_TESTS=1` 之类的开关控制。
- **无 USB 设备**：无法做真机 RNDIS 联调。
  → USB 后端必须抽象成接口，提供内存 loopback mock，端到端测试与吞吐基准都跑在 mock 上。
- 未验证的事项统一记录在本文件第 6 节「待验证清单」。

---

## 3. 目录结构

```
TetherKit/
├── AGENTS.md              本文件：agent 工作记忆
├── README.md              用户向文档：构建、运行、权限、故障排查
├── CMakeLists.txt         顶层构建脚本
├── .clang-format          代码格式（Google 基线，100 列）
├── .clang-tidy            静态检查与命名约定
├── cmake/
│   ├── FindLibUSB.cmake        libusb-1.0 查找（pkg-config 优先 + Homebrew 回退）
│   ├── CompilerWarnings.cmake  警告选项 INTERFACE 目标
│   ├── Sanitizers.cmake        ASan/UBSan/TSan 开关
│   └── Optimizations.cmake     数据路径优化选项与取舍说明
├── include/tetherkit/     公开头文件（按模块分子目录）
├── src/                   实现
│   ├── version.cc.in           CMake 注入版本号的模板
│   └── app/                    命令行入口
├── tests/                 doctest 单元测试（单一二进制 + test-suite 过滤）
├── benchmarks/            自带轻量 harness 的性能基准
├── third_party/doctest/   vendored doctest 2.4.12 单头文件
└── docs/                  设计文档、协议笔记、性能报告
```

依赖方向**严格单向**，禁止反向或循环：

```
tk_common  ←（无依赖）
   ↑
tk_rndis / tk_net / tk_usb  ← tk_common
   ↑
tk_core    ← common + rndis + net + usb
   ↑
tetherkit（可执行）← core
```

---

## 4. 代码规范（与 `.clang-tidy` 中的 CheckOptions 一致）

| 类别 | 约定 | 例 |
|---|---|---|
| 命名空间 | `lower_case` | `tetherkit`、`tetherkit::rndis` |
| 类型（class/struct/enum/别名） | `CamelCase` | `RndisStateMachine`、`BpfLink` |
| 函数与方法 | `CamelCase` | `SendEncapsulatedCommand()` |
| 局部变量与参数 | `lower_case` | `frame_len`、`max_transfer_size` |
| 私有/保护成员变量 | `lower_case_` 后缀下划线 | `handle_`、`request_id_` |
| 常量（全局/constexpr/枚举值） | `k` + `CamelCase` | `kMaxFrameSize`、`kCacheLineSize` |
| 宏 | `UPPER_CASE`（尽量不用宏） | |
| 文件名 | `snake_case`，实现用 `.cc`，头用 `.h` | `spsc_ring.h`、`bpf_link.cc` |

错误处理分层：

- **初始化 / 控制路径**：`std::expected<T, Error>`，错误可携带 errno / libusb 错误码 / 上下文串。
- **数据热路径**：**绝不**返回 `expected`、绝不抛异常、绝不分配。用返回计数 + 原子统计计数器表达失败。
- 全程 `-fno-exceptions`？**不**关异常（doctest 需要），但项目自身代码不 `throw`。

---

## 5. 实现进度

图例：`✅ 已完成` `🚧 进行中` `⬜ 未开始`

| # | 提交 | 状态 | 备注 |
|---|---|---|---|
| 1 | `chore: 初始化项目脚手架与构建系统` | ✅ | CMake + 规范配置 + vendored doctest + 版本注入 + 冒烟测试，`-Werror` 干净通过 |
| 2 | 基础设施：错误处理与日志 | ⬜ | |
| 3 | 基础设施：无锁 SPSC 队列与帧池 | ⬜ | |
| 4 | RNDIS 协议：线格式与编解码 | ⬜ | |
| 5 | USB：设备发现与控制通道 | ⬜ | |
| 6 | USB：异步 transfer 池与事件循环 | ⬜ | |
| 7 | RNDIS：状态机 | ⬜ | |
| 8 | 网卡：feth 生命周期 | ⬜ | |
| 9 | 链路：BPF 读写 | ⬜ | |
| 10 | 核心：数据路径桥接 | ⬜ | |
| 11 | 应用：CLI 与运行时编排 | ⬜ | |
| 12 | 测试补全 | ⬜ | |
| 13 | 基准与汇总报告 | ⬜ | |
| 14 | 文档 | ⬜ | |

---

## 6. 待验证清单（需要 root 或真实 RNDIS 设备）

这些事项在当前开发机上**无法验证**，实现时按设计文档的结论编码，并在代码里留下
清晰的 `// 待真机验证:` 注释。

- [ ] `feth` peer 配对的私有 ABI（`SIOCSDRVSPEC` + `struct if_fake_request`）在 macOS 26 上是否可用。
- [ ] BPF 挂在 `feth1` 上时的方向语义：`write()` 是否真能让 `feth0` 侧的 IP 栈收到帧；
      `BIOCSSEESENT=0` 是否正确过滤掉自己写入的帧。
- [ ] `BIOCSBLEN` 在 macOS 上的实际上限值。
- [ ] macOS 是否会有内核驱动（AppleUSBCDC 等）抢占 RNDIS 设备的 CDC 通信接口，
      导致 `libusb_claim_interface` 失败。
- [ ] 非 root 下 `libusb_open` 是否返回 `LIBUSB_ERROR_ACCESS`。
- [ ] 真机吞吐（USB 2.0 high-speed 下能否接近 ~300 Mbps 实测上限）。
- [ ] Android 各版本的 RNDIS quirk（`MaxTransferSize` / `PacketAlignmentFactor` 异常值）。

---

## 7. 已知坑与规避（**踩过的坑写在这里，不要重复踩**）

1. **缓存行是 128 字节**，不是习惯性的 64。SPSC 队列若按 64 对齐，生产者/消费者索引仍会
   落在同一缓存行上，false sharing 依旧存在。项目统一用 `kCacheLineSize = 128`。
2. **`std::format` 需要部署目标 ≥ 13.3**，否则报 `to_chars unavailable`。CMake 已强制。
3. **`std::hardware_destructive_interference_size` 在 Apple libc++ 上不存在**，别用。
4. **BPF 没有零拷贝**，别去找 `BIOCSETZBUF`。
5. **BPF `BIOCSBLEN` 必须在 `BIOCSETIF` 之前设置**，顺序错了缓冲区大小不生效。
6. **BPF 遍历必须用 `bh_hdrlen`**，不能用 `sizeof(struct bpf_hdr)` —— 头部后面有对齐填充。
7. **libusb 在 macOS 上没有 `detach_kernel_driver`**。若接口被内核驱动占用，只能走
   codeless kext / dext 或 re-enumerate，不能靠 libusb 解决。
8. 开发机上**既无 USB 设备也无 root**，所以「跑不起来」不等于「代码错了」；
   离线可验证的部分必须全部覆盖到 mock 测试里。

---

## 8. 常用命令

```bash
# 配置 + 构建（警告当错误）
cmake -S . -B build -DTETHERKIT_WARNINGS_AS_ERRORS=ON && cmake --build build -j10

# 跑测试
ctest --test-dir build --output-on-failure

# ThreadSanitizer 验证无锁队列（重要！）
cmake -S . -B build-tsan -DTETHERKIT_ENABLE_TSAN=ON && cmake --build build-tsan -j10 \
  && ctest --test-dir build-tsan --output-on-failure

# 性能基准（务必用未开消毒器的 Release 构建）
cmake -S . -B build-rel -DCMAKE_BUILD_TYPE=Release && cmake --build build-rel -j10 \
  && ./build-rel/bin/tetherkit_bench
```
