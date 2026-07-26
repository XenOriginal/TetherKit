# app —— 命令行可执行程序 tetherkit

add_executable(tetherkit main.cc)

# tk_core PUBLIC 链接了其余全部模块。
target_link_libraries(tetherkit PRIVATE tetherkit_base tk_version tk_core)

install(TARGETS tetherkit RUNTIME DESTINATION bin)
