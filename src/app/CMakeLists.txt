# app —— 命令行可执行程序 tetherkit

add_executable(tetherkit main.cc)

target_link_libraries(tetherkit PRIVATE tetherkit_base tk_version tk_common)

install(TARGETS tetherkit RUNTIME DESTINATION bin)
