import Charts
import SwiftUI
import TetherKitIPC

/// 吞吐与计数器。
///
/// 图表刻意只画**速率**而不画累计量：累计曲线永远单调上升，看不出任何东西；
/// 而速率能一眼看出卡顿、抖动和被限速。累计量放在下面的指标格里，需要时能读到。
struct ThroughputCard: View {
    @Bindable var model: AppModel

    private var hasData: Bool { !model.throughputHistory.isEmpty }

    var body: some View {
        Card(title: "吞吐", systemImage: "chart.line.uptrend.xyaxis", accessory: AnyView(liveBadge)) {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                rateRow
                chart
                Divider()
                counterRow
                if hasDrops {
                    dropHint
                }
            }
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        if model.status.runState == .running {
            StatusBadge(text: "实时", color: .green)
        }
    }

    // 速率四格排成 2×2 而不是一行：这卡现在住在半栏里，一行四格会把
    // 「下行（设备 → 本机）」这类说明挤到截断。
    private var rateRow: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Spacing.medium,
             verticalSpacing: Design.Spacing.small) {
            GridRow {
                MetricTile(caption: "下行（设备 → 本机）",
                           value: Format.bitrate(model.throughput.receiveBitsPerSecond),
                           systemImage: "arrow.down",
                           tint: .blue)
                MetricTile(caption: "上行（本机 → 设备）",
                           value: Format.bitrate(model.throughput.transmitBitsPerSecond),
                           systemImage: "arrow.up",
                           tint: .purple)
            }
            GridRow {
                MetricTile(caption: "下行帧率",
                           value: "\(Format.packetsPerSecond(model.throughput.receivePacketsPerSecond)) pps",
                           systemImage: "square.stack.3d.up")
                MetricTile(caption: "上行帧率",
                           value: "\(Format.packetsPerSecond(model.throughput.transmitPacketsPerSecond)) pps",
                           systemImage: "square.stack.3d.up")
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if hasData {
            Chart {
                ForEach(model.throughputHistory) { sample in
                    AreaMark(x: .value("时间", sample.timestamp),
                             y: .value("速率", sample.receiveBitsPerSecond))
                        .foregroundStyle(
                            .linearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)

                    LineMark(x: .value("时间", sample.timestamp),
                             y: .value("速率", sample.receiveBitsPerSecond),
                             series: .value("方向", "下行"))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)

                    LineMark(x: .value("时间", sample.timestamp),
                             y: .value("速率", sample.transmitBitsPerSecond),
                             series: .value("方向", "上行"))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bits = value.as(Double.self) {
                            Text(Format.bitrate(bits)).font(.caption2)
                        }
                    }
                }
            }
            // 横轴不画刻度：这是一条「最近 60 秒」的滚动曲线，具体时刻没有意义，
            // 画上去只会挤占本来就不高的绘图区。
            .chartXAxis(.hidden)
            .frame(height: 120)
        } else {
            RoundedRectangle(cornerRadius: Design.Radius.control)
                .fill(.quaternary.opacity(0.35))
                .frame(height: 120)
                .overlay(
                    Text(model.status.runState == .running ? "正在采集…" : "连接后显示实时吞吐")
                        .font(.callout)
                        .foregroundStyle(.secondary))
        }
    }

    private var counterRow: some View {
        HStack(spacing: Design.Spacing.medium) {
            MetricTile(caption: "累计下行", value: Format.bytes(model.status.rxBytes))
            MetricTile(caption: "累计上行", value: Format.bytes(model.status.txBytes))
            MetricTile(caption: "下行帧数", value: Format.count(model.status.rxFrames))
            MetricTile(caption: "上行帧数", value: Format.count(model.status.txFrames))
        }
    }

    private var hasDrops: Bool {
        model.status.rxDropped > 0 || model.status.txDropped > 0
            || model.status.linkKernelDrops > 0 || model.status.txBackpressure > 0
    }

    /// 丢包提示。
    ///
    /// 分开列四个数字而不是合成一个「丢包率」：它们指向完全不同的瓶颈 ——
    /// 队列满是下游写不过来，内核丢是我们读得不够快，背压是 USB 侧发不出去。
    /// 合并之后就分不清该调哪个参数了。
    private var dropHint: some View {
        HStack(spacing: Design.Spacing.medium) {
            MetricTile(caption: "下行丢弃", value: Format.count(model.status.rxDropped), tint: .orange)
            MetricTile(caption: "上行丢弃", value: Format.count(model.status.txDropped), tint: .orange)
            MetricTile(caption: "内核丢包", value: Format.count(model.status.linkKernelDrops), tint: .orange)
            MetricTile(caption: "发送背压", value: Format.count(model.status.txBackpressure), tint: .orange)
        }
    }
}
