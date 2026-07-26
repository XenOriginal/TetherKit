// 性能基准入口。
//
// 当前仅为脚手架阶段的占位实现；后续提交会接入 harness 与各项基准。
#include <cstdio>

#include "tetherkit/version.h"

int main() {
  std::printf("%s —— 基准尚未实现\n", tetherkit::GetVersionString().data());
  return 0;
}
