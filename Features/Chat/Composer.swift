import AetherCore
import SwiftUI
import PhotosUI

/// 输入区。打字、按住说话、发图、打电话 —— 四个入口，一个都不藏在二级菜单里。
struct Composer: View {
    let onSend: (String, [Attachment]) -> Void
    let onSendImage: (UIImage) -> Void
    let onStartCall: () -> Void
    let isGroup: Bool
    /// 有角色在念语音时，驱动口型
    var onSpeakingChanged: ((Bool) -> Void)?

    @State private var text = ""
    @State private var recorder = VoiceNoteRecorder()
    @State private var photoItem: PhotosPickerItem?
    @State private var isRecording = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            if recorder.isRecording { recordingBar } else { normalBar }
        }
        .background(.bar)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    onSendImage(image)
                }
                photoItem = nil
            }
        }
    }

    private var normalBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 6) {
                TextField("说点什么…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Button(action: startRecording) {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                        .padding(.bottom, 9)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )

            if text.trimmed.isEmpty {
                Button(action: onStartCall) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: "#6C5CE7")))
                }
            } else {
                Button {
                    let payload = text
                    text = ""
                    onSend(payload, [])
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: "#6C5CE7")))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: text.trimmed.isEmpty)
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button {
                recorder.cancel()
                isRecording = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 2) {
                ForEach(Array(recorder.levels.suffix(34).enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color(hex: "#6C5CE7").opacity(0.35 + Double(level) * 0.65))
                        .frame(width: 3, height: max(4, CGFloat(level) * 30))
                }
            }
            .frame(height: 32)
            .animation(.linear(duration: 0.08), value: recorder.levels.count)

            Text(timeString(recorder.elapsed))
                .font(.system(size: 13, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                if let attachment = recorder.stop() {
                    onSend("", [attachment])
                }
                isRecording = false
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(hex: "#6C5CE7")))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func startRecording() {
        focused = false
        isRecording = true
        Task { await recorder.start(transcriber: SystemTranscriber()) }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
