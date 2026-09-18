import Foundation

/// 演出指令：模型在回复里内嵌的「舞台指示」。
/// 用户永远看不到指示本身，只看到它造成的结果 —— 一次停顿、一阵脸红、一场雨。
struct PerformanceCue: Codable, Hashable, Sendable {
    enum Channel: String, Codable, Sendable, CaseIterable {
        case avatar    // 表情 / 动作 / 口型
        case stage     // 屏幕演出：雨、樱花、闪光、故障
        case bubble    // 气泡：抖动、打字机、延迟
        case audio     // 环境音 / 音效
        case haptic    // 震动
        case camera    // 镜头推拉摇
        case pacing    // 节拍：拆成多条消息发，模拟真人
    }

    /// 在文本中的字符偏移：让表演卡在句子的正确位置。
    var at: Int
    var channel: Channel
    var name: String
    var intensity: Double
    /// 相对该字符的延迟（秒），制造停顿。
    var delay: Double
    var params: [String: String]

    init(at: Int, channel: Channel, name: String, intensity: Double = 0.6, delay: Double = 0, params: [String: String] = [:]) {
        self.at = at
        self.channel = channel
        self.name = name
        self.intensity = intensity.clamped(0, 1)
        self.delay = delay
        self.params = params
    }
}

/// 演出白名单。模型只能从这张表里选词 —— 「怎么演」由客户端决定，
/// 模型与 UI 之间永远隔着一层导演。
enum CueVocabulary {
    static let avatarActions: Set<String> = [
        "smile", "grin", "pout", "blush", "cry", "sulk", "surprise", "angry",
        "thinking", "lookaway", "nod", "shakehead", "tilt", "stretch", "shiver",
        "leanin", "stepback", "hug", "wave", "sigh", "yawn", "freeze",
    ]

    static let stageEffects: Set<String> = [
        "rain", "snow", "petals", "sparkle", "heartbeat", "glitch", "flash",
        "vignette", "blur", "sepia", "night", "sunset", "fireflies", "crack",
    ]

    static let bubbleEffects: Set<String> = ["shake", "typewriter", "fade", "slidein", "popin", "blur"]

    static let audioEffects: Set<String> = [
        "rain_loop", "cafe_loop", "train_loop", "wind_loop",
        "heartbeat_sfx", "notification_sfx", "chime_sfx",
    ]

    static let haptics: Set<String> = ["light", "medium", "heavy", "success", "warning", "soft", "rigid"]

    static let cameraMoves: Set<String> = ["pushin", "pullout", "shake", "tiltup", "dutch", "settle"]

    static func isAllowed(_ cue: PerformanceCue) -> Bool {
        switch cue.channel {
        case .avatar: return avatarActions.contains(cue.name)
        case .stage: return stageEffects.contains(cue.name)
        case .bubble: return bubbleEffects.contains(cue.name)
        case .audio: return audioEffects.contains(cue.name)
        case .haptic: return haptics.contains(cue.name)
        case .camera: return cameraMoves.contains(cue.name)
        case .pacing: return true
        }
    }

    /// 写进 system prompt 的说明书。
    static var modelBriefing: String {
        let avatar = avatarActions.sorted().joined(separator: " ")
        let stage = stageEffects.sorted().joined(separator: " ")
        let bubble = bubbleEffects.sorted().joined(separator: " ")
        let audio = audioEffects.sorted().joined(separator: " ")
        let haptic = haptics.sorted().joined(separator: " ")
        let camera = cameraMoves.sorted().joined(separator: " ")
        return """
        【演出协议】你可以在台词里插入舞台指示，格式 ⟦c:频道.动词:强度⟧。例如：
        ⟦c:bubble.typewriter⟧⟦c:avatar.blush:0.7⟧今天…那个…⟦c:pacing.split:0.8⟧其实我等你很久了。
        ⟦c:stage.rain:0.5⟧⟦c:audio.rain_loop⟧外面下雨了。⟦c:avatar.lookaway:0.4⟧
        可用频道与动词（只能从这里选，写错会被忽略）：
        avatar: \(avatar)
        stage: \(stage)
        bubble: \(bubble)
        audio: \(audio)
        haptic: \(haptic)
        camera: \(camera)
        pacing: split（把这段话拆成多条消息分次发出，模拟真人打字）
        强度 0.0-1.0 可省略。指示要克制：一条回复 0-3 个，宁缺毋滥。
        这些标记对你而言就是「动作」本身，不要用文字复述它们。
        """
    }
}
