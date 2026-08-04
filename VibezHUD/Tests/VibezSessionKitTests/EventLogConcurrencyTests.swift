import Testing
import Foundation
@testable import VibezSessionKit

@Test func fiftyConcurrentAppendersLoseNothingAndInterleaveNothing() throws {
    let log = TempLog()
    let writers = 50, perWriter = 20

    // Each writer is a real subshell doing exactly what hud_record() does.
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "appenders", attributes: .concurrent)
    for w in 0..<writers {
        queue.async(group: group) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", """
              for i in $(seq 1 \(perWriter)); do
                printf '%s\\n' '{"v":1,"ts":'"$i"',"sid":"w\(w)","agent":"cc","kind":"tool","proj":"P","cwd":"/tmp/P","title":"t"}' >> '\(log.url.path)'
              done
              """]
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }
    group.wait()

    let text = try String(contentsOf: log.url, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == writers * perWriter, "lost or duplicated lines")

    // Every single line must decode — a torn/interleaved write would not.
    let decoded = lines.compactMap { HUDEventDecoder.decodeLine(String($0)) }
    #expect(decoded.count == lines.count, "an interleaved write corrupted a line")

    // And every writer's full run survived.
    let counts = Dictionary(grouping: decoded, by: \.sid).mapValues(\.count)
    #expect(counts.count == writers)
    #expect(counts.values.allSatisfy { $0 == perWriter })
}
