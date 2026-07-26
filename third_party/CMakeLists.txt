# third_party —— 内置（vendored）第三方依赖
#
# 刻意选择 vendoring 而非 FetchContent：configure 阶段不联网，保证任何时候、
# 任何网络环境下 `cmake -B build` 都可重复成功。

# doctest 2.4.12 —— 单头文件测试框架。
# 选它而不是 GoogleTest/Catch2 的理由：单个头文件、编译速度快、断言表达力足够、
# 原生支持 SUBCASE 做参数化、且能安全用于多线程测试断言。
add_library(doctest INTERFACE)
target_include_directories(doctest SYSTEM INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/doctest")
