import Foundation

/// 内置工具集。
///
/// 每一个都是一件「角色本来做不了、现在能做了」的事。
/// 想让角色多会一件事，就在这里加一个 struct 然后 install 进去 ——
/// 流水线、prompt、界面都不用动。
enum BuiltinTools {
    static func install(into registry: ToolRegistry) {
        registry.register(WebSearchTool())
        registry.register(FetchPageTool())
        registry.register(ResearchCharacterTool())
        registry.register(CreateCharacterTool())
        registry.register(ListCharactersTool())
        registry.register(RecallMemoryTool())
        registry.register(RememberTool())
        registry.register(DesignVoiceTool())
    }
}

// MARK: - 联网

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let summary = "联网搜索。不需要密钥。用来查资料、查设定、查最新的东西。"
    let parameters = [
        ToolParameter(name: "query", description: "搜索词。中文即可，越具体越好。"),
    ]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let query = arguments["query"], !query.isBlank else {
            return .fail("缺少 query")
        }
        let hits = await WebSearch.search(query, limit: 6)
        guard !hits.isEmpty else {
            return .ok("没有搜到结果。换个关键词试试，或者直接用你已知的信息。")
        }
        let body = hits.enumerated().map { index, hit in
            "\(index + 1). \(hit.title)\n   \(hit.url)\n   \(hit.snippet)"
        }.joined(separator: "\n")
        return .ok(body, display: "搜到 \(hits.count) 条")
    }
}

struct FetchPageTool: AgentTool {
    let name = "fetch_page"
    let summary = "打开一个网页并读它的正文。配合 web_search 用它，读完再下结论。"
    let parameters = [
        ToolParameter(name: "url", description: "完整网址，通常来自 web_search 的结果。"),
    ]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let url = arguments["url"], url.hasPrefix("http") else {
            return .fail("url 不合法")
        }
        guard let text = await WebSearch.fetchText(url, limit: 3500) else {
            return .fail("打不开这个页面")
        }
        return .ok(text, display: "读了 \(text.count) 字")
    }
}

// MARK: - 角色

struct ResearchCharacterTool: AgentTool {
    let name = "research_character"
    let summary = "检索一个虚构角色的公开设定（萌娘百科 / 维基 / Fandom），整理成带出处的设定条目。"
    let parameters = [
        ToolParameter(name: "name", description: "角色名"),
        ToolParameter(name: "work", description: "出自哪部作品", required: false),
        ToolParameter(name: "fandom", description: "Fandom 子域，如 genshin-impact", required: false),
    ]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let character = arguments["name"], !character.isBlank else {
            return .fail("缺少 name")
        }
        let options = ResearchAgent.Options(
            workTitle: arguments["work"]?.isEmpty == false ? arguments["work"]! : "未知作品",
            characterName: character,
            aliases: [],
            fidelity: .faithful,
            manualText: "",
            fandomSubdomain: arguments["fandom"] ?? "",
            includeEnglish: false,
            maxFacts: 40
        )

        let draft = await ResearchAgent().research(options) { _ in }
        guard let bundle = draft.bundle, !bundle.facts.isEmpty else {
            return .ok("没有查到「\(character)」的公开资料。可以试试换成更常见的译名，或者直接让用户提供设定文本。")
        }

        let lines = bundle.facts.prefix(24).map { fact in
            "[\(fact.category.displayName)] \(fact.title)：\(fact.body)"
        }.joined(separator: "\n")

        var extra = ""
        if !draft.warnings.isEmpty { extra += "\n注意：" + draft.warnings.joined(separator: "；") }

        // 把档案暂存起来，下一步 create_character 可以直接用
        await AgentScratch.shared.put(key: "draft:\(character)", value: draft)

        return .ok(
            "《\(bundle.workTitle)》\(bundle.characterName)：共 \(bundle.facts.count) 条\n\(lines)\(extra)",
            display: "查到 \(bundle.facts.count) 条设定"
        )
    }
}

struct CreateCharacterTool: AgentTool {
    let name = "create_character"
    let summary = "创建一个角色。如果之前 research_character 查过同名角色，会自动用上那份档案。"
    let parameters = [
        ToolParameter(name: "name", description: "角色名"),
        ToolParameter(name: "one_line", description: "一句话说清她是谁"),
        ToolParameter(name: "background", description: "她的来历", required: false),
        ToolParameter(name: "desire", description: "她最想要什么", required: false),
        ToolParameter(name: "wound", description: "她最怕什么", required: false),
        ToolParameter(name: "speech_style", description: "她怎么说话", required: false),
    ]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let name = arguments["name"], !name.isBlank else {
            return .fail("缺少 name")
        }

        var persona: Persona
        if let draft = await AgentScratch.shared.get(key: "draft:\(name)") as? PersonaDraft {
            persona = PersonaFactory.forge(draft: draft)
        } else {
            let seed = PersonaSeed(
                oneLine: arguments["one_line"] ?? "",
                background: arguments["background"] ?? "",
                coreDesire: arguments["desire"] ?? "",
                wound: arguments["wound"] ?? "",
                speechStyle: arguments["speech_style"] ?? "",
                relationshipStance: "",
                interests: [],
                taboos: []
            )
            persona = PersonaFactory.forgeOriginal(name: name, seed: seed)
        }

        persona.presentation.avatarKind = .orb
        persona.presentation.voice = VoiceDesigner().resolve(await VoiceDesigner().design(for: persona))
        await WorldStore.shared.upsert(persona)

        if let bundleID = persona.core.canonBundleID, let draft = await AgentScratch.shared.get(key: "draft:\(name)") as? PersonaDraft, let bundle = draft.bundle {
            await WorldStore.shared.saveBundle(bundle)
            _ = bundleID
        }

        return .ok(
            "已创建「\(persona.name)」，人格指纹 \(persona.core.fingerprint.prefix(8))，并自动配好了声音。",
            display: "创建了 \(persona.name)",
            artifacts: [persona.id.uuidString]
        )
    }
}

struct ListCharactersTool: AgentTool {
    let name = "list_characters"
    let summary = "列出手机里现有的所有角色，以及和他们的关系状态。"
    let parameters: [ToolParameter] = []

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        let personas = await WorldStore.shared.allPersonas()
        guard !personas.isEmpty else { return .ok("目前还没有任何角色。") }
        var lines: [String] = []
        for persona in personas {
            let edge = await WorldStore.shared.edge(from: persona.id, to: nil)
            lines.append("· \(persona.name)（\(persona.fidelity.displayName)，关系：\(edge.kind.displayName)，好感 \(String(format: "%.2f", edge.affinity))）")
        }
        return .ok(lines.joined(separator: "\n"), display: "\(personas.count) 个角色")
    }
}

// MARK: - 记忆

struct RecallMemoryTool: AgentTool {
    let name = "recall_memory"
    let summary = "读取某个角色记住的事。"
    let parameters = [
        ToolParameter(name: "persona", description: "角色名"),
        ToolParameter(name: "query", description: "想找什么", required: false),
    ]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let name = arguments["persona"] else { return .fail("缺少 persona") }
        let personas = await WorldStore.shared.allPersonas()
        guard let persona = personas.first(where: { $0.name == name }) else {
            return .fail("没有叫「\(name)」的角色")
        }
        let memories = await WorldStore.shared.memories(stream: persona.memoryStreamID)
        guard !memories.isEmpty else { return .ok("\(name) 目前什么都没记住。") }

        let query = arguments["query"] ?? ""
        let relevant = query.isBlank
            ? memories.sorted { $0.salience > $1.salience }.prefix(12)
            : memories.filter { $0.text.contains(query) }.prefix(12)

        let lines = relevant.map { "· [\($0.kind.displayName)] \($0.text)（重要度 \(String(format: "%.2f", $0.salience))）" }
        return .ok(lines.isEmpty ? "没找到相关的记忆。" : lines.joined(separator: "\n"), display: "\(relevant.count) 条")
    }
}

struct RememberTool: AgentTool {
    let name = "remember"
    let summary = "让某个角色记住一件事。"
    let parameters = [
        ToolParameter(name: "persona", description: "角色名"),
        ToolParameter(name: "text", description: "要记住的内容，一句话"),
        ToolParameter(name: "kind", description: "fact / preference / event / feeling / promise / secret", required: false),
    ]
    let isReadOnly = false

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let name = arguments["persona"], let text = arguments["text"], !text.isBlank else {
            return .fail("缺少 persona 或 text")
        }
        let personas = await WorldStore.shared.allPersonas()
        guard let persona = personas.first(where: { $0.name == name }) else {
            return .fail("没有叫「\(name)」的角色")
        }
        let kind = MemoryItem.Kind(rawValue: arguments["kind"] ?? "fact") ?? .fact
        let item = MemoryItem(
            streamID: persona.memoryStreamID,
            kind: kind,
            text: text,
            salience: 0.7,
            annotation: "由代理写入"
        )
        await WorldStore.shared.upsertMemories([item])
        return .ok("已写入记忆：\(text)", display: "记住了")
    }
}

// MARK: - 声音

struct DesignVoiceTool: AgentTool {
    let name = "design_voice"
    let summary = "给一个角色自动配声音（音高、语速、音色），并保存。"
    let parameters = [
        ToolParameter(name: "persona", description: "角色名"),
    ]
    let isReadOnly = false

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let name = arguments["persona"] else { return .fail("缺少 persona") }
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

/// 工具之间传中间结果的暂存区。
///
/// research_character 查到的档案要交给 create_character 用，
/// 但两次工具调用之间没有共享内存 —— 这个 actor 就是那个交接台。
actor AgentScratch {
    static let shared = AgentScratch()
    private var storage: [String: Any] = [:]

    func put(key: String, value: Any) { storage[key] = value }
    func get(key: String) -> Any? { storage[key] }
    func clear() { storage.removeAll() }
}
