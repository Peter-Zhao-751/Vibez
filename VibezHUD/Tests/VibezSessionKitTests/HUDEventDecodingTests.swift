import Testing
@testable import VibezSessionKit

private let good = #"{"v":1,"ts":1754345678901,"sid":"abc","agent":"cc","kind":"needs-input","proj":"Vibez","cwd":"/tmp/Vibez","title":"Notch app","body":"awaiting approval","tool":"Bash"}"#

@Test func decodesAWellFormedLine() throws {
    let e = try #require(HUDEventDecoder.decodeLine(good))
    #expect(e.ts == 1_754_345_678_901)
    #expect(e.sid == "abc")
    #expect(e.agent == .claude)
    #expect(e.kind == .needsInput)
    #expect(e.proj == "Vibez")
    #expect(e.tool == "Bash")
}

@Test func skipsMalformedAndUnusableLines() {
    #expect(HUDEventDecoder.decodeLine("") == nil)
    #expect(HUDEventDecoder.decodeLine("   ") == nil)
    #expect(HUDEventDecoder.decodeLine("{not json") == nil)
    #expect(HUDEventDecoder.decodeLine(#"{"v":1}"#) == nil)                    // missing required
    #expect(HUDEventDecoder.decodeLine(good.replacingOccurrences(of: #""v":1"#, with: #""v":99"#)) == nil)  // unknown schema
    #expect(HUDEventDecoder.decodeLine(good.replacingOccurrences(of: "needs-input", with: "teleport")) == nil) // unknown kind
}

@Test func unknownAgentFallsBackToClaude() throws {
    // Matches the iOS convention: unrecognised agent tags render as Claude.
    let line = good.replacingOccurrences(of: #""agent":"cc""#, with: #""agent":"zz""#)
    let e = try #require(HUDEventDecoder.decodeLine(line))
    #expect(e.agent == .claude)
}

@Test func survivesHostileContent() throws {
    let emoji = good.replacingOccurrences(of: "Notch app", with: "🚀 ünïcode ✳ 中文")
    #expect(try #require(HUDEventDecoder.decodeLine(emoji)).title == "🚀 ünïcode ✳ 中文")

    let huge = good.replacingOccurrences(of: "awaiting approval", with: String(repeating: "x", count: 10_000))
    #expect(HUDEventDecoder.decodeLine(huge)?.body?.count == 10_000)
}
