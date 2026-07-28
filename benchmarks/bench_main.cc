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
#include "bench_net.h"
#include "bench_rndis.h"
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

  std::fprintf(stderr, "开始测量……\n");

  {
    tetherkit::bench::Runner runner;
    tetherkit::bench::RegisterCommonBenchmarks(runner);
    tetherkit::bench::PrintMarkdownReport(runner.RunAll(), "基础设施层（tk_common）");
  }
  {
    tetherkit::bench::Runner runner;
    tetherkit::bench::RegisterRndisBenchmarks(runner);
    tetherkit::bench::PrintMarkdownReport(runner.RunAll(), "RNDIS 编解码（tk_rndis）");
  }
  {
    // 链路层需要 root。跳过时也要在报告里留痕 —— 否则读者无从判断这份报告
    // 到底是「测过了没问题」还是「压根没测」。
    tetherkit::bench::Runner runner;
    std::string skip_reason;
    if (tetherkit::bench::RegisterNetBenchmarks(runner, skip_reason)) {
      tetherkit::bench::PrintMarkdownReport(runner.RunAll(), "feth / BPF 链路层（tk_net，需 root）");
      // 必须在这里拆，不能留给静态析构 —— 原因见 bench_net.h。
      tetherkit::bench::ShutdownNetBenchmarks();
    } else {
      std::printf("## feth / BPF 链路层（tk_net，需 root）\n\n");
      std::printf("**本次未测量** —— %s。\n\n", skip_reason.c_str());
      std::printf("补测方法：`sudo ./build/bin/tetherkit_bench > docs/BENCHMARKS.md`\n\n");
      std::fprintf(stderr, "  跳过链路层基准：%s\n", skip_reason.c_str());
    }
  }

  std::fprintf(stderr, "测量完成。\n");
  return 0;
}
