// C ABI 层的单元测试。
//
// 覆盖那些「写错了不会当场崩、但会在 GUI 上表现成乱码或安全漏洞」的地方：
// UTF-8 边界截断、网卡名校验、日志环形缓冲的丢弃语义。
//
// 会话与网卡配置需要 root 与真实设备，不在这里测 —— 只测它们的参数校验分支。
#include <array>
#include <cstring>
#include <string>

#include <doctest.h>

#include "capi_support.h"
#include "tetherkit/capi/tetherkit_c.h"
#include "tetherkit/common/logging.h"

using tetherkit::capi::CopyText;
using tetherkit::capi::IsValidFethName;

TEST_SUITE("capi.support") {

TEST_CASE("CopyText 正常拷贝并补终止符") {
  std::array<char, 16> buffer{};
  CopyText(buffer.data(), buffer.size(), "feth0");
  CHECK(std::string{buffer.data()} == "feth0");
}

TEST_CASE("CopyText 容量为 0 或目标为空时不写内存") {
  CopyText(nullptr, 16, "x");  // 不崩即通过
  std::array<char, 4> buffer{'a', 'b', 'c', 'd'};
  CopyText(buffer.data(), 0, "xyz");
  CHECK(buffer[0] == 'a');
}

TEST_CASE("CopyText 截断落在 UTF-8 字符边界上") {
  // 「设备」= 6 字节（每字 3 字节）。给 6 字节容量（可用 5 字节 + 终止符）时，
  // 只能装下第一个字；若按字节硬切会留下半个「备」，Swift 侧整串会变成替换字符。
  std::array<char, 6> buffer{};
  CopyText(buffer.data(), buffer.size(), "设备");
  CHECK(std::string{buffer.data()} == "设");
  CHECK(std::strlen(buffer.data()) == 3);
}

TEST_CASE("CopyText 恰好装得下时不截断") {
  std::array<char, 7> buffer{};
  CopyText(buffer.data(), buffer.size(), "设备");
  CHECK(std::string{buffer.data()} == "设备");
}

TEST_CASE("CopyText 首字符就装不下时得到空串而非半个字符") {
  std::array<char, 3> buffer{};  // 可用 2 字节，装不下 3 字节的「设」
  CopyText(buffer.data(), buffer.size(), "设备");
  CHECK(std::string{buffer.data()}.empty());
}

TEST_CASE("IsValidFethName 只接受 feth+数字") {
  CHECK(IsValidFethName("feth0"));
  CHECK(IsValidFethName("feth12"));

  SUBCASE("拒绝真实物理网卡 —— 防止误把用户的 Wi-Fi 配置冲掉") {
    CHECK_FALSE(IsValidFethName("en0"));
    CHECK_FALSE(IsValidFethName("bridge0"));
  }
  SUBCASE("拒绝缺少编号与非数字后缀") {
    CHECK_FALSE(IsValidFethName("feth"));
    CHECK_FALSE(IsValidFethName("fethX"));
    CHECK_FALSE(IsValidFethName("feth0a"));
  }
  SUBCASE("拒绝壳元字符与路径分隔符") {
    CHECK_FALSE(IsValidFethName("feth0; rm -rf /"));
    CHECK_FALSE(IsValidFethName("../feth0"));
    CHECK_FALSE(IsValidFethName(""));
  }
  SUBCASE("拒绝超过 IFNAMSIZ 的名字") {
    CHECK_FALSE(IsValidFethName("feth123456789012345"));
  }
}

}  // TEST_SUITE("capi.support")

TEST_SUITE("capi.basics") {

TEST_CASE("tk_version 填出非空的版本串") {
  tk_version_info_t version{};
  tk_version(&version);
  CHECK(std::strlen(version.text) > 0);
  CHECK(std::strlen(version.build) > 0);
  CHECK(std::strlen(version.libusb) > 0);
  CHECK(version.major + version.minor + version.patch > 0);

  SUBCASE("传 nullptr 是空操作而非崩溃") {
    tk_version(nullptr);
  }
}

TEST_CASE("tk_check_environment 永远成功，只在字段里表达结论") {
  tk_environment_t environment{};
  CHECK(tk_check_environment(&environment) == TK_OK);
  // 测试进程不是 root，这一条是确定的。
  CHECK_FALSE(environment.is_root);
  // sysctl 合格时不应该同时带着说明文字。
  if (environment.sysctls_ok) {
    CHECK(std::strlen(environment.sysctl_detail) == 0);
  }

  SUBCASE("传 nullptr 返回参数错误") {
    CHECK(tk_check_environment(nullptr) == TK_ERR_INVALID_ARGUMENT);
  }
}

TEST_CASE("tk_list_devices 允许只统计数量") {
  std::size_t count = 0;
  tk_error_t error{};
  // 开发机上通常没插 RNDIS 设备，这里只验证「调用成功且不写越界」，
  // 不断言具体数量。
  const tk_result_t result = tk_list_devices(nullptr, 0, &count, false, &error);
  CHECK(result == TK_OK);
  CHECK(std::strlen(error.message) == 0);

  SUBCASE("缺少 out_count 时拒绝调用") {
    CHECK(tk_list_devices(nullptr, 0, nullptr, false, nullptr) == TK_ERR_INVALID_ARGUMENT);
  }
}

}  // TEST_SUITE("capi.basics")

TEST_SUITE("capi.log_ring") {

TEST_CASE("日志捕获关闭时不产生记录") {
  tk_enable_log_capture(false);
  TETHERKIT_ERROR("这条不该被捕获");

  std::array<tk_log_record_t, 4> records{};
  std::uint64_t dropped = 0;
  CHECK(tk_drain_logs(records.data(), records.size(), &dropped) == 0);
}

TEST_CASE("开启捕获后能按序取回日志") {
  tk_enable_log_capture(true);
  const tetherkit::LogLevel saved_level = tetherkit::GetLogLevel();
  tetherkit::SetLogLevel(tetherkit::LogLevel::kInfo);

  TETHERKIT_INFO("第一条");
  TETHERKIT_WARN("第二条");

  std::array<tk_log_record_t, 8> records{};
  std::uint64_t dropped = 0;
  const std::size_t taken = tk_drain_logs(records.data(), records.size(), &dropped);

  CHECK(taken == 2);
  CHECK(dropped == 0);
  CHECK(std::string{records[0].message} == "第一条");
  CHECK(records[0].level == TK_LOG_INFO);
  CHECK(std::string{records[1].message} == "第二条");
  CHECK(records[1].level == TK_LOG_WARN);
  CHECK(records[0].wall_nanos > 0);

  SUBCASE("取空之后再取返回 0") {
    CHECK(tk_drain_logs(records.data(), records.size(), &dropped) == 0);
  }

  tetherkit::SetLogLevel(saved_level);
  tk_enable_log_capture(false);
}

TEST_CASE("缓冲写满时丢最旧的并汇报丢弃数") {
  tk_enable_log_capture(true);
  const tetherkit::LogLevel saved_level = tetherkit::GetLogLevel();
  tetherkit::SetLogLevel(tetherkit::LogLevel::kInfo);

  // 容量是 256（见 log_ring.cc），多打 10 条把最旧的挤掉。
  constexpr int kOverflow = 10;
  constexpr int kTotal = 256 + kOverflow;
  for (int i = 0; i < kTotal; ++i) {
    TETHERKIT_INFO("第 {} 条", i);
  }

  std::array<tk_log_record_t, 512> records{};
  std::uint64_t dropped = 0;
  const std::size_t taken = tk_drain_logs(records.data(), records.size(), &dropped);

  CHECK(taken == 256);
  CHECK(dropped == kOverflow);
  // 留下来的应该是**最新**的那 256 条，所以第一条是第 10 条。
  CHECK(std::string{records[0].message} == "第 10 条");
  CHECK(std::string{records[taken - 1].message} == "第 265 条");

  SUBCASE("丢弃计数取走后归零") {
    std::uint64_t again = 1;
    tk_drain_logs(records.data(), records.size(), &again);
    CHECK(again == 0);
  }

  tetherkit::SetLogLevel(saved_level);
  tk_enable_log_capture(false);
}

}  // TEST_SUITE("capi.log_ring")

TEST_SUITE("capi.session") {

TEST_CASE("tk_session_config_init 填出可直接使用的默认值") {
  tk_session_config_t config{};
  tk_session_config_init(&config);

  CHECK(config.mtu == 1500);
  CHECK(config.adopt_device_mac);
  CHECK(config.rx_transfer_count > 0);
  CHECK(config.tx_transfer_count > 0);
  CHECK(config.rx_transfer_kib > 0);
  CHECK(config.max_transfer_kib > 0);
  CHECK(config.bpf_buffer_kib > 0);
  // 设备筛选默认不限，否则 GUI 一上来就筛不到任何设备。
  CHECK(config.vendor_id == 0);
  CHECK(config.product_id == 0);
}

TEST_CASE("会话可创建、可查状态、可销毁（不需要 root）") {
  tk_session_config_t config{};
  tk_session_config_init(&config);

  tk_error_t error{};
  tk_session_t* session = tk_session_create(&config, &error);
  REQUIRE(session != nullptr);
  CHECK(std::strlen(error.message) == 0);

  SUBCASE("未启动时是 IDLE，且各字段都是干净的零值") {
    tk_session_status_t status{};
    REQUIRE(tk_session_status_get(session, &status) == TK_OK);
    CHECK(status.run_state == TK_RUN_IDLE);
    CHECK(status.rndis_state == TK_RNDIS_UNINITIALIZED);
    CHECK_FALSE(status.link_up);
    CHECK(std::strlen(status.system_interface) == 0);
    CHECK(std::strlen(status.fatal) == 0);
    CHECK(status.rx_frames == 0);
    CHECK(status.monotonic_nanos > 0);
  }

  SUBCASE("未启动时事件队列是空的") {
    std::array<tk_event_t, 8> events{};
    CHECK(tk_session_poll_events(session, events.data(), events.size()) == 0);
  }

  SUBCASE("非 root 启动返回 TK_ERR_PERMISSION 而不是笼统的失败") {
    // GUI 靠这个码区分「该弹授权」和「真的出错了」。
    CHECK(tk_session_start(session, &error) == TK_ERR_PERMISSION);
    CHECK(std::strlen(error.message) > 0);
  }

  SUBCASE("重复 stop 是幂等的") {
    CHECK(tk_session_stop(session) == TK_OK);
    CHECK(tk_session_stop(session) == TK_OK);
  }

  tk_session_destroy(session);
}

TEST_CASE("会话接口对空指针一律安全") {
  tk_error_t error{};
  CHECK(tk_session_create(nullptr, &error) == nullptr);
  CHECK(std::strlen(error.message) > 0);

  CHECK(tk_session_start(nullptr, nullptr) == TK_ERR_INVALID_ARGUMENT);
  CHECK(tk_session_stop(nullptr) == TK_ERR_INVALID_ARGUMENT);
  CHECK(tk_session_status_get(nullptr, nullptr) == TK_ERR_INVALID_ARGUMENT);
  CHECK(tk_session_poll_events(nullptr, nullptr, 4) == 0);
  tk_session_destroy(nullptr);  // 不崩即通过
  tk_session_config_init(nullptr);
}

}  // TEST_SUITE("capi.session")
