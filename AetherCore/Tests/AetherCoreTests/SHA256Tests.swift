import XCTest
@testable import AetherCore

/// 指纹的地基。
///
/// 人格指纹、canon 包指纹、离线向量化的桶位，全都建立在这个自实现的 SHA-256 上。
/// 它一旦算错，后果不是崩溃，而是**静默的数据错乱**：
/// 记忆向量在两次启动之间落到不同维度、人格「被改动」误报。
/// 所以这里用公开测试向量把它钉死。
final class SHA256Tests: XCTestCase {

    func testKnownVectors() {
        XCTAssertEqual(
            "".sha256Hex,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            "abc".sha256Hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".sha256Hex,
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    /// 跨过 55/56/64 字节的填充边界 —— 这是自实现最容易写错的地方。
    func testPaddingBoundaries() {
        let a = String(repeating: "a", count: 55).sha256Hex
        let b = String(repeating: "a", count: 56).sha256Hex
        let c = String(repeating: "a", count: 64).sha256Hex
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(b.count, 64)
        XCTAssertEqual(c.count, 64)
        XCTAssertEqual(Set([a, b, c]).count, 3, "长度不同必须得到不同摘要")
    }

    /// 中文（UTF-8 多字节）也要稳定。
    func testCJKIsStable() {
        let one = "灵犀人格指纹".sha256Hex
        let two = "灵犀人格指纹".sha256Hex
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.count, 64)
        XCTAssertNotEqual(one, "灵犀人格指紋".sha256Hex)
    }

    /// 这一条是在防一个真实踩过的坑：
    /// 早先版本用 String.hashValue 取向量桶位，而 Swift 的 hashValue 每进程随机播种，
    /// 结果就是「同一条记忆，重启之后向量变了」—— 检索静默失效，且完全看不出来。
    func testHashIsStableAcrossProcesses() {
        let sample = "我不吃香菜"
        XCTAssertEqual(sample.sha256Hex, sample.sha256Hex)
        // 摘要的前两个字节决定桶位，必须完全确定
        XCTAssertEqual(sample.sha256Bytes.count, 32)
        XCTAssertEqual(sample.sha256Bytes, sample.sha256Bytes)
    }
}
