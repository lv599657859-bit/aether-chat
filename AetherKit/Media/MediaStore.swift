import AetherCore
import Foundation
import UIKit

/// 媒体仓库。图片、语音、通话录音都落在 Documents/Media 下。
/// 用文件名引用而不是把二进制塞进 JSON —— 消息记录保持小、可读、可迁移。
actor MediaStore {
    static let shared = MediaStore()

    private let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Aether/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(for fileName: String) -> URL {
        root.appendingPathComponent(fileName)
    }

    func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    func newAudioURL(prefix: String) async throws -> URL {
        let name = "\(prefix)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6)).m4a"
        return url(for: name)
    }

    /// 保存图片数据，返回文件名。
    func saveImageData(_ data: Data, prefix: String = "img") throws -> String {
        let name = "\(prefix)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6)).jpg"
        let target = url(for: name)
        // 统一转成 JPEG 并压一档，聊天图片不需要原图体积
        if let image = UIImage(data: data),
           let compressed = image.jpegData(compressionQuality: 0.82) {
            try compressed.write(to: target, options: .atomic)
        } else {
            try data.write(to: target, options: .atomic)
        }
        return name
    }

    func loadImage(_ fileName: String) -> UIImage? {
        guard let data = try? Data(contentsOf: url(for: fileName)) else { return nil }
        return UIImage(data: data)
    }

    func saveToPhotoLibrary(_ fileName: String) {
        guard let image = loadImage(fileName) else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// 清理没有被任何消息引用的媒体。
    func vacuum(referenced: Set<String>) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: url(for: file))
            removed += 1
        }
        return removed
    }

    func totalBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { partial, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
    }
}
