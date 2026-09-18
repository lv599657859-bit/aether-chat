import XCTest
@testable import AetherCore

/// 演出系统的守门测试。
/// 这些用例挂了，就意味着用户会在屏幕上看到 ⟦c: 这种鬼东西 —— 沉浸感当场死亡。
final class CueParserTests: XCTestCase {

    func testPlainTextPassesThrough() {
        var parser = CueStreamParser()
        let out = parser.feed("今天天气不错")
        XCTAssertEqual(out.display, "今天天气不错")
        XCTAssertTrue(out.cues.isEmpty)
    }

    func testExtractsCueAndKeepsOffset() {
        var parser = CueStreamParser()
        let out = parser.feed("你好⟦c:avatar.blush:0.8⟧啊")
        XCTAssertEqual(out.display, "你好啊")
        XCTAssertEqual(out.cues.count, 1)
        XCTAssertEqual(out.cues.first?.channel, .avatar)
        XCTAssertEqual(out.cues.first?.name, "blush")
        XCTAssertEqual(out.cues.first?.intensity ?? 0, 0.8, accuracy: 0.001)
        // 偏移落在「你好」之后 —— 表演卡在正确的位置
        XCTAssertEqual(out.cues.first?.at, 2)
    }

    /// 最要命的一种情况：标记被网络分片切断。
    func testMarkerSplitAcrossChunksNeverLeaks() {
        var parser = CueStreamParser()
        var visible = ""
        for chunk in ["今天", "⟦c:ava", "tar.smi", "le:0.5⟧", "很开心"] {
            visible += parser.feed(chunk).display
        }
        visible += parser.finish().display
        XCTAssertEqual(visible, "今天很开心")
        XCTAssertFalse(visible.contains("⟦"))
    }

    func testUnclosedMarkerIsFlushedNotSwallowed() {
        var parser = CueStreamParser()
        _ = parser.feed("结尾坏掉了⟦c:avatar.smile")
        let tail = parser.finish()
        // 宁可多显示一点，也绝不吞掉用户该看到的内容
        XCTAssertTrue(tail.display.contains("⟦"))
    }

    func testUnknownCueIsDropped() {
        var parser = CueStreamParser()
        let out = parser.feed("⟦c:avatar.moonwalk:1.0⟧走一个")
        XCTAssertEqual(out.display, "走一个")
        XCTAssertTrue(out.cues.isEmpty, "白名单外的东西必须被丢掉")
    }

    func testEmotionLine() {
        var parser = CueStreamParser()
        let out = parser.feed("⟦e:v=0.7,a=0.8,d=0.4,label=羞恼/心跳⟧嗯")
        XCTAssertEqual(out.display, "嗯")
        XCTAssertEqual(out.emotion?.valence ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(out.emotion?.labels.first, "羞恼")
    }

    func testMonologueIsHidden() {
        var parser = CueStreamParser()
        let out = parser.feed("没事⟦m:其实我有事⟧")
        XCTAssertEqual(out.display, "没事")
        XCTAssertEqual(out.monologue, "其实我有事")
    }

    func testPacingCue() {
        var parser = CueStreamParser()
        let out = parser.feed("第一句⟦c:pacing.split:0.9⟧第二句")
        XCTAssertEqual(out.display, "第一句第二句")
        XCTAssertEqual(out.cues.first?.channel, .pacing)
        XCTAssertGreaterThan(out.cues.first?.delay ?? 0, 0)
    }

    func testVocabularyRejectsOffListAction() {
        let cue = PerformanceCue(at: 0, channel: .avatar, name: "backflip")
        XCTAssertFalse(CueVocabulary.isAllowed(cue))
        let good = PerformanceCue(at: 0, channel: .avatar, name: "smile")
        XCTAssertTrue(CueVocabulary.isAllowed(good))
    }
}
