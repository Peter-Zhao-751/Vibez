import Foundation

/// Incremental tail of an append-only JSONL log.
/// Handles the three things that actually happen to a live log file:
/// rotation (inode changes), truncation (size < offset), and torn writes
/// (a line only partly on disk when we read).
public final class EventLogReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = Data()

    public init(url: URL) { self.url = url }

    /// Cold start: replay at most `maxBytes` from the end, discarding the
    /// leading partial line, and leave the offset at EOF.
    public func primeFromTail(maxBytes: Int) -> [HUDEvent] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return [] }
        inode = attrs[.systemFileNumber] as? UInt64
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size

        var lines = splitCompleteLines(data, carry: &partial)
        partial = Data()                       // at EOF there is no carry to keep
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // leading partial line
        return lines.compactMap { HUDEventDecoder.decodeLine($0) }
    }

    /// Everything appended since the last call.
    public func readNew() -> [HUDEvent] {
        var events: [HUDEvent] = []

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return [] }
        let currentInode = attrs[.systemFileNumber] as? UInt64

        if let known = inode, let now = currentInode, known != now {
            // Rotated: drain what is left of the OLD file before switching.
            events += drainRotatedTail()
            offset = 0
            partial = Data()
            inode = now
        } else if inode == nil {
            inode = currentInode
        }

        if size < offset {                     // truncated in place
            offset = 0
            partial = Data()
        }

        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else {
            return events
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size

        let lines = splitCompleteLines(data, carry: &partial)
        events += lines.compactMap { HUDEventDecoder.decodeLine($0) }
        return events
    }

    private func drainRotatedTail() -> [HUDEvent] {
        let rotated = HUDPaths.rotatedURL(for: url)
        guard let handle = try? FileHandle(forReadingFrom: rotated) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var carry = partial
        let lines = splitCompleteLines(data, carry: &carry)
        return lines.compactMap { HUDEventDecoder.decodeLine($0) }
    }

    /// Emits only newline-terminated lines; anything after the last newline is
    /// held in `carry` until the writer finishes it.
    private func splitCompleteLines(_ data: Data, carry: inout Data) -> [String] {
        var buffer = carry + data
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer = buffer[buffer.index(after: nl)...]
        }
        carry = Data(buffer)
        return lines
    }
}
