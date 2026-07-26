# tests —— 单元测试
#
# 全部测试链接进单个可执行文件 tetherkit_tests，理由：
#  * doctest 的注册是全局的，单一二进制启动开销最低；
#  * 通过 doctest 的 --test-suite 过滤即可按模块运行；
#  * CTest 侧按 test-suite 注册多个用例，失败定位仍然精确。

add_executable(tetherkit_tests test_main.cc test_version.cc)

target_link_libraries(tetherkit_tests PRIVATE tetherkit_base doctest tk_version)

# 按 test-suite 注册 CTest 用例，方便 `ctest -R rndis` 之类的过滤。
set(TETHERKIT_TEST_SUITES version)

foreach(_suite IN LISTS TETHERKIT_TEST_SUITES)
  add_test(NAME "${_suite}" COMMAND tetherkit_tests --test-suite="${_suite}" --no-intro=true)
endforeach()
