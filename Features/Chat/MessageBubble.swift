import SwiftUI

/// 一条消息。
///
/// 演出指令在这里落地成视觉：抖动、打字机、渐入、弹入。
/// 注意这些效果**只影响这一条**，不会污染整个界面 —— 演出要有边界感。
struct MessageBubble: View {
    let message: Message
    let persona: Persona?
    let participants: [Persona]
    let isGroup: Bool
    let onReact: (String) -> Void
    let onRetry: () -> Void

    @State private var shakeOffset: CGFloat = 0
    @State private var appeared = false
    @State private var revealedText: String = ""

    private var isMine: Bool { message.isFromUser }

    private var author: Persona? {
        guard let id = message.authorID else { return nil }
        return participants.first { $0.id == id }
    }

    private var bubbleEffects: Set<String> {
        Set(message.cues.filter { $0.channel == .bubble }.map { $0.name })
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 44) }

            if !isMine, isGroup {
                AvatarDot(persona: author ?? persona ?? Persona(core: .blank(name: "?")), size: 30)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine, isGroup, let author {
                    Text(author.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                content
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .clipShape(BubbleShape(isMine: isMine))
                    .offset(x: shakeOffset)
                    .scaleEffect(appeared || bubbleEffects.contains("popin") ? 1 : 0.86)
                    .opacity(appeared ? 1 : 0)
                    .contextMenu { contextMenu }

                if !message.reactions.isEmpty {
                    reactionsRow
                }
            }

            if !isMine { Spacer(minLength: 44) }
        }
        .onAppear {
            applyEffects()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { appeared = true }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .image, .dailyShare:
            imageContent
        case .voiceNote:
            VoiceNoteBubble(attachment: message.attachments.first, isMine: isMine)
        case .sticker:
            Text(message.text).font(.system(size: 46))
        case .callLog:
            callLogContent
        case .systemEvent:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        default:
            textContent
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bubbleEffects.contains("typewriter") ? revealedText : message.text)
                .font(.system(size: 16))
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !message.attachments.isEmpty, message.attachments.first?.kind == .image {
                imageContent
            }
        }
    }

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment = message.attachments.first,
               let image = AttachmentImage.load(attachment.fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contextMenu {
                        Button {
                            Task { await MediaStore.shared.saveToPhotoLibrary(attachment.fileName) }
                        } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 180, height: 220)
                    .overlay { ProgressView() }
            }
            if let caption = message.attachments.first?.caption, !caption.isEmpty {
                Text(caption).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var callLogContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.arrow.up.right")
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(message.text).font(.system(size: 13, weight: .medium))
                if let transcript = message.attachments.first?.transcript, !transcript.isEmpty {
                    Text("通话记录已保存").font(.system(size: 10)).opacity(0.7)
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private var bubbleBackground: some View {
        Group {
            if isMine {
                Color(hex: "#6C5CE7")
            } else if message.kind == .sticker || message.kind == .systemEvent {
                Color.clear
            } else {
                Color(uiColor: .secondarySystemBackground)
            }
        }
    }

    private var reactionsRow: some View {
        HStack(spacing: 3) {
            ForEach(message.reactions.keys.sorted(), id: \.self) { emoji in
                Text(emoji)
                    .font(.system(size: 12))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button { onReact("❤️") } label: { Label("喜欢", systemImage: "heart") }
        Button { onReact("😄") } label: { Label("笑", systemImage: "face.smiling") }
        Button { onReact("…") } label: { Label("无语", systemImage: "ellipsis") }
        if !isMine {
            Button { onRetry() } label: { Label("让她再说一次", systemImage: "arrow.clockwise") }
        }
        if case .image = message.kind, let name = message.attachments.first?.fileName {
            Button {
                Task { await MediaStore.shared.saveToPhotoLibrary(name) }
            } label: { Label("保存图片", systemImage: "square.and.arrow.down") }
        }
    }

    // MARK: - 演出

    private func applyEffects() {
        if bubbleEffects.contains("shake") {
            withAnimation(.easeInOut(duration: 0.06).repeatCount(8, autoreverses: true)) {
                shakeOffset = 7
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shakeOffset = 0 }
        }
        if bubbleEffects.contains("typewriter") {
            revealedText = ""
            let full = message.text
            Task {
                for character in full {
                    revealedText.append(character)
                    try? await Task.sleep(nanoseconds: 28_000_000)
                }
            }
        } else {
            revealedText = message.text
        }
    }
}

/// 气泡尾巴。自己发的在右，对方在左。
struct BubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 17
        var path = Path()
        let corners: UIRectCorner = isMine
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        path = Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
        return path
    }
}

/// 正在输入中的气泡。用省略号节奏而不是转圈 —— 转圈是机器，省略号是人。
struct StreamingBubble: View {
    let author: Persona?
    let phrase: String?
    let text: String?
    let isGroup: Bool

    @State private var dotPhase = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isGroup, let author {
                AvatarDot(persona: author, size: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                if isGroup, let author {
                    Text(author.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let text, !text.isEmpty {
                        Text(text).font(.system(size: 16))
                    } else {
                        Text(phrase ?? "正在输入")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            ForEach(0..<3) { index in
                                Circle()
                                    .fill(Color.secondary.opacity(dotPhase == index ? 0.85 : 0.3))
                                    .frame(width: 4, height: 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(BubbleShape(isMine: false))
            }
            Spacer(minLength: 44)
        }
        .onAppear {
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    withAnimation(.easeInOut(duration: 0.2)) { dotPhase = (dotPhase + 1) % 3 }
                }
            }
        }
    }
}

/// 图片按需加载 + 缓存。聊天里滚动的图片不能每次都读盘解码。
enum AttachmentImage {
    private static var cache = NSCache<NSString, UIImage>()

    static func load(_ fileName: String) -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) { return cached }
        guard let image = MediaStoreSync.load(fileName) else { return nil }
        cache.setObject(image, forKey: fileName as NSString)
        return image
    }
}

/// 同步读一张本地小图。容量可控，且只在小尺寸展示时使用。
enum MediaStoreSync {
    static func load(_ fileName: String) -> UIImage? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Aether/Media").appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
