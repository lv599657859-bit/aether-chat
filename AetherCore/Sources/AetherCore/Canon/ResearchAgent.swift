import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 角色研究员。
///
/// 用户的要求：「一键准确完美的复刻游戏里的角色，他们会自己去详细搜索并建立自己的知识库」。
///
/// 这里的取舍是：**自动、但不盲目**。
/// 它会自己去检索、自己整理、自己标注置信度，也会自己承认「这条我拿不准」。
/// 复刻精度越高，它越倾向于对资料里没有的东西保持沉默 —— 而不是编一个听起来很对的答案。
final class ResearchAgent: @unchecked Sendable {
    struct Options: Sendable {
        var workTitle: String
        var characterName: String
        var aliases: [String] = []
        var fidelity: CanonFidelity = .faithful
        /// 用户额外粘贴的资料，优先级最高
        var manualText: String = ""
        /// Fandom 子域，例如 genshin-impact
        var fandomSubdomain: String = ""
        var includeEnglish: Bool = false
        var maxFacts: Int = 60
    }

    private let provider: LLMProvider
    private let embedder: EmbeddingProvider
    private let session: URLSession

    init(provider: LLMProvider = ProviderHub.shared.llm,
         embedder: EmbeddingProvider = ProviderHub.shared.embedder,
         session: URLSession = .shared) {
        self.provider = provider
        self.embedder = embedder
        self.session = session
    }

    /// 主流程。progress 会持续汇报人类可读的进度（这一步**可以**显示给用户看，
    /// 因为它发生在创建流程里，不破坏「她是一个真实的人」这个幻觉）。
    func research(
        _ options: Options,
        progress: @escaping @Sendable (String) -> Void
    ) async -> PersonaDraft {
        var draft = PersonaDraft(core: PersonaCore.blank(name: options.characterName))
        draft.core.origin = .adapted
        draft.core.sourceWork = options.workTitle
        draft.core.fidelity = options.fidelity

        // ── 1. 采集 ────────────────────────────────────────────────
        progress("正在检索《\(options.workTitle)》的资料…")
        var documents: [FetchedDocument] = []

        if !options.manualText.isBlank {
            if let doc = try? await ManualFetcher(title: options.characterName, body: options.manualText)
                .fetch(title: options.characterName) {
                documents.append(doc)
                draft.researchLog.append("手动资料 \(doc.length) 字")
            }
        }

        let fetchers = buildFetchers(options: options)
        for fetcher in fetchers {
            for query in queryPlan(options: options) {
                do {
                    let titles = try await fetcher.search(query, limit: 3)
                    for title in titles.prefix(2) {
                        if documents.contains(where: { $0.source.title == title }) { continue }
                        if let doc = try await fetcher.fetch(title: title) {
                            documents.append(doc)
                            draft.researchLog.append("\(fetcher.displayName)：《\(doc.source.title)》\(doc.length) 字")
                        }
                    }
                } catch {
                    draft.warnings.append("\(fetcher.displayName) 检索失败：\(error.localizedDescription)")
                }
                if documents.count >= 8 { break }
            }
            if documents.count >= 8 { break }
        }

        if documents.isEmpty {
            draft.warnings.append("没有抓到任何公开资料。请改用「手动录入」把设定粘进来 —— 这比编造更可靠。")
            draft.openQuestions.append("这个人是谁？她最想要什么？她怎么说话？")
            return draft
        }

        progress("抓到 \(documents.count) 份资料，正在整理设定…")

        // ── 2. 抽取事实 ────────────────────────────────────────────
        var facts: [CanonFact] = []
        for document in documents {
            let chunks = DocumentChunker.chunks(document.text).prefix(4)
            for chunk in chunks {
                let extracted = await extractFacts(
                    from: chunk,
                    source: document.source,
                    options: options
                )
                facts.append(contentsOf: extracted)
                if facts.count >= options.maxFacts * 2 { break }
            }
            if facts.count >= options.maxFacts * 2 { break }
        }

        progress("整理出 \(facts.count) 条原始设定，正在去重与校验…")

        // 没有模型（或模型没吐出可用 JSON）时的兜底：直接从资料正文里抽。
        // 这样「搜一个角色」在没有 API Key 的机器上也不是一条死路 ——
        // 检索本身本来就不需要密钥，只有整理需要。
        if facts.isEmpty {
            facts = Self.heuristicExtract(from: documents)
            if !facts.isEmpty {
                draft.researchLog.append("模型不可用，改用关键词抽取，得到 \(facts.count) 条")
                draft.warnings.append("这次没有用模型整理资料。设定是关键词抽出来的，准确度有限 —— 想要精确复刻，请在「我的 → 生成引擎」里配一个服务。")
            }
        }

        // ── 3. 去重、合并、定置信度 ────────────────────────────────
        let merged = deduplicate(facts, fidelity: options.fidelity)

        // ── 4. 冲突检测：精确复刻模式下，矛盾条目要标出来让用户决定 ──
        let conflicts = detectConflicts(merged)
        for conflict in conflicts {
            draft.warnings.append("资料冲突：\(conflict)")
        }

        // ── 5. 生成人格 ────────────────────────────────────────────
        progress("正在还原她的说话方式…")
        let profile = await buildProfile(
            merged: merged,
            options: options,
            documents: documents
        )

        var bundle = CanonBundle(
            workTitle: options.workTitle,
            characterName: options.characterName,
            aliases: options.aliases,
            fidelity: options.fidelity,
            facts: Array(merged.prefix(options.maxFacts)),
            relationMap: profile.relationMap,
            glossary: profile.glossary,
            speechCorpus: profile.speechCorpus
        )
        bundle.fingerprint = bundle.facts.map { $0.title + $0.body }.joined().sha256Hex

        draft.bundle = bundle
        draft.core.name = options.characterName
        draft.core.handle = "@" + options.characterName.lowercased()
        draft.core.canonBundleID = bundle.id
        draft.core.seed = profile.seed
        draft.core.soul = profile.soul
        draft.core.speechQuirks = profile.quirks
        draft.core.taboos = profile.taboos
        draft.openQuestions = profile.openQuestions

        progress("复刻完成：\(bundle.facts.count) 条设定，\(bundle.speechCorpus.count) 条台词样本")
        draft.researchLog.append("完成于 \(Date().iso8601)")
        return draft
    }

    // MARK: - 检索计划

    private func buildFetchers(options: Options) -> [CanonSourceFetcher] {
        var list: [CanonSourceFetcher] = []
        if !options.fandomSubdomain.isBlank {
            list.append(MediaWikiFetcher.fandom(subdomain: options.fandomSubdomain))
        }
        list.append(MediaWikiFetcher.moegirl())
        list.append(MediaWikiFetcher.wikipedia(language: "zh"))
        if options.includeEnglish {
            list.append(MediaWikiFetcher.wikipedia(language: "en"))
        }
        return list
    }

    /// 查询计划：先精确后宽泛，避免一上来就抓到一堆无关页面。
    private func queryPlan(options: Options) -> [String] {
        var queries = ["\(options.characterName)"]
        queries.append("\(options.workTitle) \(options.characterName)")
        for alias in options.aliases.prefix(2) {
            queries.append("\(options.workTitle) \(alias)")
        }
        return queries
    }

    // MARK: - 事实抽取

    private func extractFacts(
        from chunk: String,
        source: CanonSource,
        options: Options
    ) async -> [CanonFact] {
        let prompt = """
        下面是关于《\(options.workTitle)》中角色「\(options.characterName)」的公开资料片段。

        请抽取其中**明确写出来**的设定事实。分类只能用这些英文词：
        identity, appearance, personality, speech, ability, relation, timeline, world, taboo, quote

        铁律：
        1. 只抽资料里写了的。没写的一律不要补。宁可少，不能编。
        2. 如果资料里的表述本身模糊（"据说""可能""推测"），confidence 给 0.4 以下。
        3. quote 类只抽**原文台词**，不要改写。
        4. 每条 body 一句话，不超过 60 字，用中文。
        5. 最多 12 条。

        资料片段：
        \(chunk)

        只输出 JSON 数组，不要解释：
        [{"category":"identity","title":"简短标题","body":"一句话","confidence":0.9,"quote":false}]
        """

        var output = ""
        do {
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .system, content: "你是一个严格的资料整理员。只输出 JSON，不确定就不写。"),
                    LLMMessage(role: .user, content: prompt),
                ],
                temperature: 0.1,
                maxTokens: 1200
            )
            for try await delta in provider.stream(request) { output += delta }
        } catch {
            Log.canon.error("extractFacts failed: \(error.localizedDescription)")
            return []
        }

        return Self.decodeFacts(output, source: source)
    }

    private static func decodeFacts(_ raw: String, source: CanonSource) -> [CanonFact] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return array.compactMap { dict in
            guard let title = dict["title"] as? String, let body = dict["body"] as? String,
                  !title.isBlank, !body.isBlank else { return nil }
            let category = CanonFact.Category(rawValue: dict["category"] as? String ?? "identity") ?? .identity
            let isQuote = dict["quote"] as? Bool ?? false
            let confidence = (dict["confidence"] as? Double ?? 0.6).clamped(0, 1)
            return CanonFact(
                category: isQuote ? .quote : category,
                title: title.trimmed,
                body: body.trimmed,
                confidence: confidence,
                sources: [source],
                isHard: false
            )
        }
    }

    // MARK: - 无模型时的兜底抽取

    /// 关键词抽取。
    ///
    /// 不是「假装在工作」—— 维基正文的结构其实相当可利用：
    ///   首段通常是身份概述；含「身高/生日/发色/声优」的行是硬设定；
    ///   「」里是台词样本；章节标题是专有名词。
    /// 抽出来的东西不如模型整理的干净，但比什么都没有强得多。
    static func heuristicExtract(from documents: [FetchedDocument]) -> [CanonFact] {
        var facts: [CanonFact] = []

        let markers: [(String, CanonFact.Category)] = [
            ("身高", .appearance), ("体重", .appearance), ("生日", .appearance),
            ("血型", .appearance), ("发色", .appearance), ("瞳色", .appearance),
            ("年龄", .appearance), ("三围", .appearance), ("服装", .appearance),
            ("声优", .speech), ("配音", .speech), ("语气", .speech), ("口癖", .speech),
            ("性格", .personality), ("喜欢", .personality), ("讨厌", .personality),
            ("能力", .ability), ("武器", .ability), ("技能", .ability),
            ("所属", .world), ("阵营", .world), ("组织", .world),
            ("关系", .relation), ("亲属", .relation), ("同伴", .relation),
        ]

        for document in documents {
            let source = document.source
            let lines = document.text
                .components(separatedBy: "\n")
                .map { $0.trimmed }
                .filter { !$0.isEmpty }

            // 1. 开头几行 = 身份概述
            let head = lines.prefix(6).joined(separator: " ")
            if head.count > 30 {
                facts.append(CanonFact(
                    category: .identity,
                    title: "身份概述",
                    body: String(head.prefix(180)),
                    confidence: 0.6,
                    sources: [source]
                ))
            }

            // 2. 含标记词的行 = 硬设定
            for line in lines where line.count >= 8 && line.count <= 140 {
                for (marker, category) in markers where line.contains(marker) {
                    facts.append(CanonFact(
                        category: category,
                        title: marker,
                        body: line,
                        confidence: 0.55,
                        sources: [source]
                    ))
                    break
                }
            }

            // 3. 引号里的短句 = 台词样本
            for quote in Self.extractQuotes(document.text).prefix(10) {
                facts.append(CanonFact(
                    category: .quote, title: "台词", body: quote,
                    confidence: 0.45, sources: [source]
                ))
            }
        }

        // 去重
        var seen = Set<String>()
        return facts.filter { fact in
            let key = fact.category.rawValue + "|" + String(fact.body.prefix(30))
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func extractQuotes(_ text: String) -> [String] {
        var result: [String] = []
        let pairs: [(Character, Character)] = [("「", "」"), ("“", "”")]
        for (open, close) in pairs {
            var current = ""
            var capturing = false
            for character in text {
                if character == open { capturing = true; current = ""; continue }
                if character == close {
                    capturing = false
                    let line = current.trimmed
                    if line.count >= 6 && line.count <= 60 { result.append(line) }
                    continue
                }
                if capturing { current.append(character) }
            }
        }
        return result
    }

    // MARK: - 去重 / 冲突 / 铁律

    private func deduplicate(_ facts: [CanonFact], fidelity: CanonFidelity) -> [CanonFact] {
        var buckets: [String: CanonFact] = [:]
        for fact in facts {
            let key = fact.body
                .replacingOccurrences(of: "[，。、；：！？\\s]", with: "", options: .regularExpression)
                .prefix(24)
                .description
            if var existing = buckets[key] {
                // 多个来源印证 -> 置信度上升
                for source in fact.sources where !existing.sources.contains(where: { $0.url == source.url }) {
                    existing.sources.append(source)
                }
                existing.confidence = min(1.0, existing.confidence + 0.15)
                buckets[key] = existing
            } else {
                buckets[key] = fact
            }
        }

        var merged = Array(buckets.values)

        // 精确复刻 / 忠于原作模式：核心分类的高置信条目升级为「铁律」
        if fidelity == .strict || fidelity == .faithful {
            let coreCategories: Set<CanonFact.Category> = [.identity, .appearance, .personality, .speech, .taboo]
            for i in merged.indices where coreCategories.contains(merged[i].category) {
                merged[i].isHard = merged[i].confidence >= 0.75
            }
        }

        return merged.sorted { lhs, rhs in
            if lhs.isHard != rhs.isHard { return lhs.isHard }
            return lhs.confidence > rhs.confidence
        }
    }

    private func detectConflicts(_ facts: [CanonFact]) -> [String] {
        var conflicts: [String] = []
        let appearance = facts.filter { $0.category == .appearance }
        // 同一分类下出现互斥关键词（例如身高/年龄/发色）时提示
        let dimensions = ["身高", "年龄", "发色", "瞳色", "生日"]
        for dimension in dimensions {
            let hits = facts.filter { $0.body.contains(dimension) }
            if hits.count >= 2 {
                let values = Set(hits.map { $0.body })
                if values.count >= 2 {
                    conflicts.append("\(dimension)在资料中有 \(values.count) 种说法，请在审核时确认")
                }
            }
        }
        _ = appearance
        return conflicts
    }

    // MARK: - 人格还原

    private struct Profile: Sendable {
        var seed: PersonaSeed
        var soul: String
        var quirks: [String]
        var taboos: [String]
        var speechCorpus: [String]
        var glossary: [String: String]
        var relationMap: [String: [String]]
        var openQuestions: [String]
    }

    private func buildProfile(
        merged: [CanonFact],
        options: Options,
        documents: [FetchedDocument]
    ) async -> Profile {
        let factDigest = merged.prefix(50)
            .map { "[\($0.category.rawValue)] \($0.title)：\($0.body)" }
            .joined(separator: "\n")

        // 台词样本直接来自资料里的 quote 类
        var corpus = merged.filter { $0.category == .quote }.map { $0.body }

        let prompt = """
        你在为《\(options.workTitle)》的角色「\(options.characterName)」建立人格档案，
        目的是让一个对话引擎能**准确地演她**。

        已知设定：
        \(factDigest)

        请输出 JSON（不要有别的内容）：
        {
          "oneLine": "一句话说清她是谁（30 字内）",
          "background": "她的来历（80 字内）",
          "coreDesire": "她最想要什么（30 字内）",
          "wound": "她最怕什么 / 伤在哪（30 字内）",
          "speechStyle": "她怎么说话 —— 包括句长、用词、称呼对方的习惯（80 字内）",
          "relationshipStance": "她初次见到陌生人时的态度（40 字内）",
          "interests": ["她会主动聊起的话题", "最多 6 个"],
          "taboos": ["她绝不会做的事 / 绝不会说的话", "最多 5 个"],
          "quirks": ["口癖或说话习惯，例如总是在句尾加某个字", "最多 5 个"],
          "soul": "第二人称的人格正文，150-250 字。要写得像在描述一个真人而不是一份简历。包含：她怎么看待世界、她掩饰什么、她在什么情况下会露出破绽。",
          "glossary": {"专有名词":"解释", "最多 10 条"},
          "relationMap": {"某人": ["和她的关系"], "最多 8 条"},
          "openQuestions": ["资料里没写清楚、需要用户补充的点", "最多 5 条"]
        }

        纪律：设定里没有的，不要编。拿不准的写进 openQuestions。
        """

        var output = ""
        do {
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .system, content: "你是一个角色档案编写者。只输出 JSON。不确定就留到 openQuestions。"),
                    LLMMessage(role: .user, content: prompt),
                ],
                temperature: 0.5,
                maxTokens: 2000
            )
            for try await delta in provider.stream(request) { output += delta }
        } catch {
            Log.canon.error("buildProfile failed: \(error.localizedDescription)")
        }

        var profile = Self.decodeProfile(output, fallbackName: options.characterName)
        if corpus.isEmpty {
            // 从对话样本里补：抓含引号的短句
            corpus = documents
                .flatMap { $0.text.components(separatedBy: "\n") }
                .filter { $0.contains("「") || $0.contains("“") || $0.contains("\"") }
                .map { $0.trimmed }
                .filter { $0.count > 6 && $0.count < 80 }
                .prefix(12)
                .map { $0 }
        }
        profile.speechCorpus = Array(corpus.prefix(24))
        return profile
    }

    private static func decodeProfile(_ raw: String, fallbackName: String) -> Profile {
        var profile = Profile(
            seed: .empty, soul: "", quirks: [], taboos: [],
            speechCorpus: [], glossary: [:], relationMap: [:], openQuestions: []
        )
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            profile.soul = "你是 \(fallbackName)。资料不足，等你补充设定。"
            return profile
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return profile
        }

        func str(_ key: String) -> String { (dict[key] as? String)?.trimmed ?? "" }
        func list(_ key: String) -> [String] {
            (dict[key] as? [String])?.map { $0.trimmed }.filter { !$0.isEmpty } ?? []
        }

        profile.seed = PersonaSeed(
            oneLine: str("oneLine"),
            background: str("background"),
            coreDesire: str("coreDesire"),
            wound: str("wound"),
            speechStyle: str("speechStyle"),
            relationshipStance: str("relationshipStance"),
            interests: list("interests"),
            taboos: list("taboos")
        )
        profile.soul = str("soul")
        profile.quirks = list("quirks")
        profile.taboos = list("taboos")
        profile.glossary = (dict["glossary"] as? [String: String]) ?? [:]
        profile.relationMap = (dict["relationMap"] as? [String: [String]]) ?? [:]
        profile.openQuestions = list("openQuestions")
        return profile
    }
}
