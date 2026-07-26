# tests —— 单元测试
#
# 全部测试链接进单个可执行文件 tetherkit_tests，理由：
#  * doctest 的注册是全局的，单一二进制启动开销最低；
#  * 通过 doctest 的 --test-suite 过滤即可按模块运行；
#  * CTest 侧按 test-suite 注册多个用例，失败定位仍然精确。

add_executable(
  tetherkit_tests
  test_main.cc
  test_version.cc
  test_common_byte_order.cc
  test_common_error.cc
  test_common_frame_ring.cc
  test_common_spsc_ring.cc
  test_common_stats.cc
  test_rndis_messages.cc
  test_rndis_packet_codec.cc)

# tk_rndis 已经 PUBLIC 链接了 tk_common，无需重复列出（否则链接器报
# "ignoring duplicate libraries"）。
target_link_libraries(tetherkit_tests PRIVATE tetherkit_base doctest tk_version tk_rndis)

# 按 test-suite 注册 CTest 用例，方便 `ctest -R common` 之类的过滤。
set(TETHERKIT_TEST_SUITES
    version
    common.byte_order
    common.error
    common.frame_ring
    common.spsc_ring
    common.stats
    rndis.messages
    rndis.packet_codec)

foreach(_suite IN LISTS TETHERKIT_TEST_SUITES)
  add_test(NAME "${_suite}" COMMAND tetherkit_tests --test-suite="${_suite}" --no-intro=true)
endforeach()
