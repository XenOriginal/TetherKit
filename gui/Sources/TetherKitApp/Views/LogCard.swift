import SwiftUI
import TetherKitIPC

/// 日志面板。默认折叠 —— 一切正常时用户不需要看它。
///
/// 但出问题时它是唯一有用的东西，所以做了三件事：可按级别过滤、自动滚到底、
/// 一键复制全部（用户报 issue 时能直接贴过来）。
struct LogCard: View {
    @Bindable var model: AppModel
    @State private var isExpanded = false
    @State private var autoScroll = true

    var body: some View {
        Card(title: "运行日志", systemImage: "text.alignleft", accessory: AnyView(header)) {
            if isExpanded {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    toolbar
                    logList
                    if model.droppedLogCount > 0 {
                        Label("有 \(model.droppedLogCount) 条日志因缓冲写满被丢弃",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Design.Spacing.small) {
            if !isExpanded, let latest = model.filteredLogs.last {
                // 折叠时也把最新一条摘要显示出来 —— 用户不用展开就能察觉异常。
                Text(latest.message)
                    .font(.caption)
                    .foregroundStyle(Design.logColor(for: latest.level))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(isExpanded ? "收起" : "展开") {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Design.Spacing.small) {
            Picker("级别", selection: $model.logLevelFilter) {
                Text("全部").tag(LogLevel.trace)
                Text("调试").tag(LogLevel.debug)
                Text("信息").tag(LogLevel.info)
                Text("警告").tag(LogLevel.warning)
                Text("错误").tag(LogLevel.error)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer()

            Toggle("自动滚动", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.callout)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plainText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制全部日志")

            Button {
                model.clearLogs()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("清空日志")
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filteredLogs) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(Design.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: Design.Radius.control))
            .onChange(of: model.filteredLogs.last?.id) { _, newValue in
                guard autoScroll, let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    private var plainText: String {
        model.filteredLogs
            .map { "\(Format.time($0.timestamp)) [\($0.level.label)] [\($0.thread)] \($0.message)" }
            .joined(separator: "\n")
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Text(Format.time(entry.timestamp))
                .foregroundStyle(.tertiary)
            Text(entry.level.label)
                .foregroundStyle(Design.logColor(for: entry.level))
                // 固定宽度让级别列对齐，扫读时眼睛不用横向找。
                .frame(width: 46, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(Design.logColor(for: entry.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}
