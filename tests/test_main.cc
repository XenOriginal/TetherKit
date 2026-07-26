// doctest 的 main() 实现单独占一个翻译单元。
//
// 这样修改任何测试文件都不必重编译 doctest 那 7000 行头文件的实现部分，
// 显著缩短增量构建时间。
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest.h>
