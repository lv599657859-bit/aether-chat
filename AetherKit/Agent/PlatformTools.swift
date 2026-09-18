import Foundation

/// 平台专属工具 —— 依赖苹果框架、进不了内核的那些能力。
///
/// 内核负责「怎么想、怎么调工具」，外壳负责「这台设备能做什么」。
/// 加一个平台能力 = 在这里写一个 struct + 注册一行，
/// 内核、流水线、界面全都不用改。
enum PlatformTools {
    static func install(into registry: ToolRegistry = .builtin) {
        registry.register(DesignVoiceTool())
        // 远程桥接的工具。没配对 / 没开开关时，它们会在调用时直接返回
        // 「还没有连接电脑上的桥接」，而不是从工具表里消失 ——
        // 这样代理知道有这么个东西存在，只是现在用不了。
        RemoteBridgeTools.install(into: registry)
    }
}

/// 给角色配声音。用 AVFoundation 的音色清单，所以只能待在外壳。
struct DesignVoiceTool: AgentTool {
    let name = "design_voice"
    let summary = "给一个角色自动配声音（音高、语速、音色），并保存。"
    let parameters = [
        ToolParameter(name: "persona", description: "角色名"),
    ]
    let isReadOnly = false

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let name = arguments["persona"], !name.isBlank else {
            return .fail("缺少 persona")
        }
        let personas = await WorldStore.shared.allPersonas()
        guard let persona = personas.first(where: { $0.name == name }) else {
            return .fail("没有叫「\(name)」的角色")
        }

        let designer = VoiceDesigner()
        let design = await designer.design(for: persona)
        let profile = designer.resolve(design)
        await WorldStore.shared.updatePersona(persona.id) { p in
            p.presentation.voice = profile
        }

        let voiceName = VoiceCatalog.entry(for: profile.systemVoiceID)?.name ?? "未指定"
        return .ok(
            "音色：\(design.timbrePrompt)\n语速 \(String(format: "%.2f", profile.rate))，音高 \(String(format: "%.2f", profile.pitch))，选中「\(voiceName)」（\(design.note)）",
            display: "配好了声音"
        )
    }
}