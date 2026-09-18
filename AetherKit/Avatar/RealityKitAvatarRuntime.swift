import SwiftUI
import RealityKit

/// 3D 形象运行时（USDZ / 由 VRM 转出的 USDZ）。
///
/// 素材约定：
///   Documents/AvatarModels/<name>.usdz     用户导入的模型
///   或 Bundle 内的同名资源
///
/// 面部驱动采用「具名部件」约定 —— 这是美术侧最通用的做法，
/// 也避免了把实现绑死在某个 VRM 加载库上：
///   Expr_Happy / Expr_Sad / Expr_Angry / Expr_Surprised / Expr_Blush   表情网格
///   Mouth_A / Mouth_I / Mouth_U / Mouth_E / Mouth_O                     口型网格
///   Head 或 J_Bip_C_Head                                                头部节点（视线跟随）
/// 有则用，没有就只做整体姿态，不会崩。
@MainActor
final class RealityKitAvatarRuntime: AvatarRuntime {
    let kind: AvatarKind = .threeD
    private(set) var isReady = false
    private(set) var loadError: String?

    private var root: Entity?
    private var head: Entity?
    private var expressions: [String: Entity] = [:]
    private var mouthShapes: [String: Entity] = [:]
    private var anchor: AnchorEntity?
    private var target: EmotionState = .neutral
    private var current: EmotionState = .neutral
    private var spin: Float = 0
    private var speaking = false
    private var mouth: Double = 0
    private var assetName: String?

    /// 视图层持有，用来把模型挂进场景。
    weak var host: AvatarSceneHost?

    func load(assetName: String?, palette: [String]) async {
        guard let assetName, !assetName.isBlank else {
            loadError = "未指定 3D 模型"
            isReady = false
            return
        }
        self.assetName = assetName
        guard let url = Self.locate(assetName) else {
            loadError = "找不到 \(assetName).usdz"
            isReady = false
            return
        }
        do {
            let entity = try await Entity.load(contentsOf: url)
            prepare(entity)
        } catch {
            loadError = error.localizedDescription
            isReady = false
            Log.stage.error("3D load failed: \(error.localizedDescription)")
        }
    }

    private static func locate(_ name: String) -> URL? {
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: "usdz") { return bundleURL }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidate = documents
            .appendingPathComponent("AvatarModels", isDirectory: true)
            .appendingPathComponent("\(name).usdz")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func prepare(_ entity: Entity) {
        // 归一化尺寸：不同来源的模型单位差别巨大，统一到约 1.4 米高
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = max(0.01, bounds.extents.y)
        let scale = 1.4 / height
        entity.scale = SIMD3<Float>(repeating: scale)
        entity.position = SIMD3<Float>(0, -0.7, -2.2)

        head = entity.findEntity(named: "Head") ?? entity.findEntity(named: "J_Bip_C_Head")

        for child in entity.childrenRecursive where child.name.hasPrefix("Expr_") {
            expressions[String(child.name.dropFirst(5)).lowercased()] = child
            child.isEnabled = false
        }
        for child in entity.childrenRecursive where child.name.hasPrefix("Mouth_") {
            mouthShapes[String(child.name.dropFirst(6)).lowercased()] = child
            child.isEnabled = false
        }

        root = entity
        isReady = true
        loadError = nil
        host?.mount(entity)
        Log.stage.info("3D avatar ready: \(self.assetName ?? "?") expr=\(self.expressions.count) mouth=\(self.mouthShapes.count)")
    }

    func apply(emotion: EmotionState, intensity: Double) {
        target = emotion
        current = current.blended(with: emotion, t: 0.12)
        updateExpression()
    }

    func play(action: String, intensity: Double) {
        if let emo = AvatarActionSemantics.emotion(for: action) {
            target = emo
            current = current.blended(with: emo, t: 0.5)
            updateExpression()
        }
        // 有同名动画就播，没有就用姿态代偿
        if let root, let animation = root.availableAnimations.first(where: { $0.name == action }) {
            root.playAnimation(animation.repeat(count: 1))
        } else {
            let offset = AvatarActionSemantics.poseOffset(for: action)
            root?.position.y += Float(offset.height) * 0.004
        }
    }

    func setSpeaking(_ speaking: Bool, mouthOpen: Double) {
        self.speaking = speaking
        self.mouth = mouthOpen
        updateMouth()
    }

    private func updateExpression() {
        guard !expressions.isEmpty else { return }
        let wanted: String
        if current.valence > 0.5 && current.arousal > 0.5 { wanted = "happy" }
        else if current.valence > 0.4 { wanted = "smile" }
        else if current.valence < -0.5 && current.arousal > 0.5 { wanted = "angry" }
        else if current.valence < -0.4 { wanted = "sad" }
        else if current.arousal > 0.75 { wanted = "surprised" }
        else { wanted = "neutral" }

        for (key, entity) in expressions {
            entity.isEnabled = (key == wanted) || (wanted == "happy" && key == "blush" && current.arousal > 0.7)
        }
    }

    private func updateMouth() {
        guard !mouthShapes.isEmpty else { return }
        guard speaking else {
            mouthShapes.values.forEach { $0.isEnabled = false }
            return
        }
        let key: String
        switch mouth {
        case ..<0.2: key = "a"
        case ..<0.45: key = "i"
        case ..<0.7: key = "u"
        default: key = "o"
        }
        for (name, entity) in mouthShapes { entity.isEnabled = (name == key) }
    }

    func advance(by seconds: Double) {
        spin += Float(seconds) * 0.12
        root?.orientation = simd_quatf(angle: spin, axis: SIMD3<Float>(0, 1, 0))
        // 视线跟随：轻微左右摆头，让人显得在看你
        if let head {
            let sway = sin(Double(spin) * 0.7) * 0.05 * (0.5 + current.arousal)
            head.orientation = simd_quatf(angle: Float(sway), axis: SIMD3<Float>(0, 1, 0))
        }
    }

    func makeView() -> AnyView {
        AnyView(RealityAvatarView(runtime: self))
    }

    var status: (ready: Bool, error: String?, expressions: Int) {
        (isReady, loadError, expressions.count)
    }
}

extension Entity {
    var childrenRecursive: [Entity] {
        children + children.flatMap { $0.childrenRecursive }
    }
}

/// 承载 ARView 场景的宿主。视图创建时注册，运行时通过它挂载模型。
@MainActor
protocol AvatarSceneHost: AnyObject {
    func mount(_ entity: Entity)
}

struct RealityAvatarView: View {
    let runtime: RealityKitAvatarRuntime

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            RealitySceneContainer(runtime: runtime)
                .onChange(of: timeline.date) { _, _ in
                    runtime.advance(by: 1.0 / 30.0)
                }
        }
    }
}

struct RealitySceneContainer: UIViewRepresentable {
    let runtime: RealityKitAvatarRuntime

    func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor.clear)
        view.cameraMode = .nonAR
        view.renderOptions.insert(.disableMotionBlur)
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        view.scene.addAnchor(anchor)
        context.coordinator.anchor = anchor
        context.coordinator.view = view
        runtime.host = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, AvatarSceneHost {
        let runtime: RealityKitAvatarRuntime
        var anchor: AnchorEntity?
        weak var view: ARView?

        init(runtime: RealityKitAvatarRuntime) {
            self.runtime = runtime
        }

        func mount(_ entity: Entity) {
            anchor?.addChild(entity)
            // nonAR 模式下 ARView.cameraTransform 是只读的，改用模型自身的位置取景
        }
    }
}
