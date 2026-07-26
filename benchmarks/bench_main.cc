// 性能基准入口。
//
// 输出是一份完整的 Markdown 文档（标准输出），可以直接重定向进
// docs/BENCHMARKS.md：
//
//   ./build-rel/bin/tetherkit_bench > docs/BENCHMARKS.md
//
// 进度信息走标准错误，不会污染报告。
#include <cstdio>
#include <string>
#include <vector>

#include "bench_common.h"
#include "harness.h"
#include "tetherkit/common/scheduling.h"
#include "tetherkit/version.h"

int main() {
  // 基准线程本身也按数据路径的 QoS 运行，否则可能被调度到效率核，
  // 测出来的数字会比实际运行时更差。
  tetherkit::ConfigureCurrentThread("bench", tetherkit::ThreadRole::kDataPath);

  const std::string version{tetherkit::GetVersionString()};
  std::printf("# TetherKit 性能基准\n\n");
  std::printf("由 `tetherkit_bench` 自动生成 —— %s\n\n", version.c_str());
  std::printf("> 重新生成：`./build-rel/bin/tetherkit_bench > docs/BENCHMARKS.md`\n");
  std::printf("> 必须使用 **未启用消毒器的 Release 构建**，否则数字无参考价值。\n\n");

  tetherkit::bench::PrintEnvironment();

  tetherkit::bench::Runner runner;
  tetherkit::bench::RegisterCommonBenchmarks(runner);

  std::fprintf(stderr, "开始测量……\n");
  const std::vector<tetherkit::bench::Result> results = runner.RunAll();
  std::fprintf(stderr, "测量完成。\n");

  tetherkit::bench::PrintMarkdownReport(results, "基础设施层（tk_common）");
  return 0;
}
