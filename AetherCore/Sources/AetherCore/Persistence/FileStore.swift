import Foundation

/// 极简本地存储：JSON 落盘 + 原子写。
/// 之所以不上 SQLite/SwiftData：这一步的目标是「今天就能跑起来、数据完全在本地」。
/// 消息量破万后把 messages/ 换成 GRDB 即可，上层接口不用动 —— 见 docs/03。
actor FileStore {
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil) {
        let base = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = e

        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    var rootURL: URL { root }

    private func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    private func ensureParent(_ u: URL) {
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func load<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        let u = url(path)
        guard let data = try? Data(contentsOf: u) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Log.app.error("FileStore decode failed \(path): \(error.localizedDescription)")
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, to path: String) {
        let u = url(path)
        ensureParent(u)
        do {
            let data = try encoder.encode(value)
            try data.write(to: u, options: .atomic)
        } catch {
            Log.app.error("FileStore write failed \(path): \(error.localizedDescription)")
        }
    }

    func delete(_ path: String) {
        try? FileManager.default.removeItem(at: url(path))
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    /// 全库备份打包（用于「把角色带走」/ 迁移设备）。
    func exportArchive(to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: root, to: destination)
    }
}
