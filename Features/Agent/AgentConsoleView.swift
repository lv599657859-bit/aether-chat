import SwiftUI

/// 代理控制台。
///
/// 「内置 DSH」在界面上的样子：你给它一件活，它自己决定用什么工具、
/// 用几步、什么时候收尾 —— 你能看见它每一步在做什么。
struct AgentConsoleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var task = ""
    @State private var steps: [Step] = []
    @State private var isRunning = false
    @State private var runner: Task<Void, Never>?

    struct Step: Identifiable {
        let id = UUID()
        var kind: Kind
        var text: String

        enum Kind { case started, thinking, call, result, answer, failed }
    }

    private let suggestions = [
        "搜一下《原神》的钟离，把她的资料建成角色卡",
        "给我现有的角色都配上合适的声音",
        "查一下最近有什么值得聊的科技新闻，整理三条",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(steps) { step in
                                row(step).id(step.id)
                            }
                            if steps.isEmpty {
                                emptyState
                            }
                            Color.clear.frame(height: 4).id("bottom")
                        }
                        .padding(16)
                    }
                    .onChange(of: steps.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }

                Divider()

                VStack(spacing: 8) {
                    if steps.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestions, id: \.self) { item in
                                    Button {
                                        task = item
                                    } label: {
                                        Text(item)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("给代理一件活…", text: $task, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))

                        Button {
                            if isRunning { stop() } else { start() }
                        } label: {
                            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(isRunning ? Color(hex: "#FF4D6D") : Color(hex: "#6C5CE7")))
                        }
                        .disabled(!isRunning && task.trimmed.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .background(.bar)
            }
            .navigationTitle("代理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空") { steps = []; AgentScratch.shared.clear() }
                        .disabled(isRunning)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .onDisappear { stop() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("它会自己决定怎么干")
                .font(.system(size: 15, weight: .semibold))
            Text("你给一句话，它分解成步骤、挑工具、看结果、再决定下一步。中途每一步都显示在这里。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("可用工具 \(ToolRegistry.builtin.all.count) 个：\(ToolRegistry.builtin.all.map { $0.name }.joined(separator: "、"))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func row(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: step.kind))
                .font(.system(size: 11))
                .foregroundStyle(color(for: step.kind))
                .frame(width: 16)
                .padding(.top, 2)
            Text(step.text)
                .font(.system(size: step.kind == .answer ? 14 : 12))
                .foregroundStyle(step.kind == .answer ? .primary : .secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func icon(for kind: Step.Kind) -> String {
        switch kind {
        case .started: return "flag"
        case .thinking: return "brain"
        case .call: return "arrow.right.circle"
        case .result: return "checkmark.circle"
        case .answer: return "text.bubble.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func color(for kind: Step.Kind) -> Color {
        switch kind {
        case .started: return .secondary
        case .thinking: return Color(hex: "#8A7BFF")
        case .call: return Color(hex: "#F5A623")
        case .result: return .green
        case .answer: return Color(hex: "#6C5CE7")
        case .failed: return .red
        }
    }

    private func start() {
        let payload = task.trimmed
        guard !payload.isEmpty else { return }
        task = ""
        isRunning = true
        steps = []

        let runtime = AgentRuntime(maxSteps: 6)
        let context = AgentContext(actor: "用户")

        runner = Task {
            for await event in runtime.run(task: payload, context: context) {
                switch event {
                case .started(let text):
                    steps.append(Step(kind: .started, text: text))
                case .thinking(let text):
                    steps.append(Step(kind: .thinking, text: text))
                case .toolCall(let name, let arguments):
                    let args = arguments.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
                    steps.append(Step(kind: .call, text: "调用 \(name)  \(args)"))
                case .toolResult(let name, let ok, let summary):
                    steps.append(Step(kind: .result, text: "\(name) \(ok ? "完成" : "失败")：\(summary)"))
                case .answer(let text):
                    steps.append(Step(kind: .answer, text: text))
                case .failed(let reason):
                    steps.append(Step(kind: .failed, text: reason))
                case .finished(let count):
                    steps.append(Step(kind: .result, text: "用了 \(count) 步"))
                }
            }
            isRunning = false
        }
    }

    private func stop() {
        runner?.cancel()
        runner = nil
        isRunning = false
    }
}
