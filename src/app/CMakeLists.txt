# app —— 命令行可执行程序 tetherkit-cli
#
# CMake 目标名保持 tetherkit（`cmake --build build --target tetherkit` 的用法
# 与缓存都不受影响），**产物文件名**是 tetherkit-cli：Homebrew 上的 `tetherkit`
# 这个名字让位给了图形界面 formula，命令行以 tetherkit-cli 分发。
add_executable(tetherkit main.cc)
set_target_properties(tetherkit PROPERTIES OUTPUT_NAME tetherkit-cli)

# tk_core PUBLIC 链接了其余全部模块。
target_link_libraries(tetherkit PRIVATE tetherkit_base tk_version tk_core)

install(TARGETS tetherkit RUNTIME DESTINATION bin)
