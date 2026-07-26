cmake_minimum_required(VERSION 3.24)

project(
  TetherKit
  VERSION 0.1.0
  DESCRIPTION "macOS 用户态 RNDIS 驱动：libusb + feth + BPF"
  LANGUAGES CXX)

# ------------------------------------------------------------------------------
# 平台前置检查
#
# 本项目依赖 macOS 私有的 feth(if_fake) 虚拟网卡与 Darwin BPF，无法跨平台。
# ------------------------------------------------------------------------------
if(NOT APPLE)
  message(FATAL_ERROR "TetherKit 仅支持 macOS：依赖 feth(if_fake) 与 Darwin BPF。")
endif()

# ------------------------------------------------------------------------------
# 全局语言标准
#
# 选 C++23 的理由（实测于 Apple clang 21 / macOS 26.5）：
#   * std::expected —— 初始化路径的错误传播主力，避免异常与错误码混用。
#   * std::byteswap —— RNDIS 线格式是小端，跨端序时需要显式转换。
# 部署目标必须 >= 13.3：libc++ 的 std::to_chars（std::format 浮点格式化的底层）
# 带 availability 标注，低于 13.3 会编译失败。
# ------------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET
      "13.3"
      CACHE STRING "最低 macOS 版本（libc++ std::to_chars 要求 >= 13.3）" FORCE)
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE
      "RelWithDebInfo"
      CACHE STRING "构建类型" FORCE)
endif()

# 始终导出 compile_commands.json，供 clangd / clang-tidy 使用。
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# 可执行文件与库统一输出到 build/bin、build/lib，方便脚本引用。
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ------------------------------------------------------------------------------
# 构建选项
# ------------------------------------------------------------------------------
option(TETHERKIT_BUILD_TESTS "构建单元测试" ON)
option(TETHERKIT_BUILD_BENCHMARKS "构建性能基准" ON)
option(TETHERKIT_WARNINGS_AS_ERRORS "把编译警告当作错误" OFF)
option(TETHERKIT_NATIVE_ARCH "为本机 CPU 微架构优化（-mcpu=native，产物不可移植）" OFF)
option(TETHERKIT_ENABLE_LTO "启用链接时优化（Release 类构建）" OFF)
option(TETHERKIT_ENABLE_ASAN "启用 AddressSanitizer" OFF)
option(TETHERKIT_ENABLE_UBSAN "启用 UndefinedBehaviorSanitizer" OFF)
option(TETHERKIT_ENABLE_TSAN "启用 ThreadSanitizer（验证无锁队列与线程模型）" OFF)

include(CompilerWarnings)
include(Sanitizers)
include(Optimizations)

# ------------------------------------------------------------------------------
# 依赖
# ------------------------------------------------------------------------------
find_package(LibUSB REQUIRED)

# ------------------------------------------------------------------------------
# 子目录
#
# 依赖方向严格单向：common <- rndis/net <- usb <- core <- app
# ------------------------------------------------------------------------------
add_subdirectory(third_party)
add_subdirectory(src)

if(TETHERKIT_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()

if(TETHERKIT_BUILD_BENCHMARKS)
  add_subdirectory(benchmarks)
endif()

# ------------------------------------------------------------------------------
# 构建配置摘要
# ------------------------------------------------------------------------------
message(STATUS "")
message(STATUS "==== TetherKit ${PROJECT_VERSION} 构建配置 ====")
message(STATUS "  构建类型          : ${CMAKE_BUILD_TYPE}")
message(STATUS "  C++ 标准          : C++${CMAKE_CXX_STANDARD}")
message(STATUS "  部署目标          : macOS ${CMAKE_OSX_DEPLOYMENT_TARGET}")
message(STATUS "  编译器            : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "  libusb            : ${LibUSB_VERSION} (${LibUSB_LIBRARY})")
message(STATUS "  单元测试          : ${TETHERKIT_BUILD_TESTS}")
message(STATUS "  性能基准          : ${TETHERKIT_BUILD_BENCHMARKS}")
message(STATUS "  本机微架构优化    : ${TETHERKIT_NATIVE_ARCH}")
message(STATUS "  LTO               : ${TETHERKIT_ENABLE_LTO}")
message(STATUS "  ASan/UBSan/TSan   : ${TETHERKIT_ENABLE_ASAN}/${TETHERKIT_ENABLE_UBSAN}/${TETHERKIT_ENABLE_TSAN}")
message(STATUS "=========================================")
message(STATUS "")
