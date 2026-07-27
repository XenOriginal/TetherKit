# tk_capi —— C ABI 层
#
# 全项目**唯一**的 extern "C" 边界，存在的唯一理由是给 Swift GUI 用。
# 它站在依赖链的最顶端（和 app 同层），依赖 core 及其下的全部模块。
#
# 编成静态库；对外分发的共享库 libtetherkit 在 src/CMakeLists.txt 里由它整体
# 打包而成（见那里的 --whole-archive 说明）。

add_library(
  tk_capi STATIC
  capi_support.cc
  environment.cc
  log_ring.cc
  session.cc)

target_link_libraries(tk_capi PUBLIC tetherkit_base tk_version tk_core)

# 共享库的组成部分必须是位置无关代码。静态模块那边由顶层统一开启 PIC，
# 这里只需保证自己也开着。
set_target_properties(tk_capi PROPERTIES POSITION_INDEPENDENT_CODE ON)

# C ABI 头对外安装：Homebrew formula 装完之后，别的项目也能拿它做绑定。
install(DIRECTORY "${PROJECT_SOURCE_DIR}/include/tetherkit/capi"
        DESTINATION include/tetherkit
        FILES_MATCHING
        PATTERN "*.h")
