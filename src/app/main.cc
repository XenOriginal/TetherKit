// TetherKit 命令行入口。
//
// 当前仅为脚手架阶段的占位实现：打印版本并退出。
// 后续提交会在此接入 CLI 解析、权限检查与运行时编排。
#include <cstdio>

#include "tetherkit/version.h"

int main() {
  std::printf("%s\n", tetherkit::GetVersionString().data());
  return 0;
}
