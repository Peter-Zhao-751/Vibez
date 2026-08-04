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
        // Advance by what we actually consumed, not by the size we sampled
        // before reading — the writer may have appended in between, and those
        // bytes ARE in `data`. Using `size` would re-emit them next poll.
        offset = start + UInt64(data.count)

        var lines = splitCompleteLines(data, carry: &partial)
        if start > 0 {
            if lines.isEmpty {
                // The window held no newline at all, so every byte we have —
                // including what landed in `partial` — begins mid-line and
                // cannot be trusted. Only reachable if maxBytes < one line.
                partial = Data()
            } else {
                lines.removeFirst()            // the leading partial line
            }
        }
        // NOTE: do NOT clear `partial` here. If the writer was mid-write when
        // we primed, the final line has no newline yet and its head is sitting
        // in `partial`. Dropping it loses that event permanently: the writer
        // later appends only the remainder, which cannot decode on its own.
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
        offset += UInt64(data.count)           // consumed bytes, not sampled size

        let lines = splitCompleteLines(data, carry: &partial)
        events += lines.compactMap { HUDEventDecoder.decodeLine($0) }
        return events
    }

    /// Drain what is left of the pre-rotation file, picking up from where we
    /// stopped reading it.
    ///
    /// Accepted limitation: only ONE backup generation exists, so if the log
    /// rotated twice between two polls, `.1` is no longer the file we were
    /// reading and its unread tail is gone. At a 2 MB rotation threshold and a
    /// ~200 ms poll that needs 4 MB of hook output in 200 ms, which does not
    /// happen. The size guard below keeps that case harmless rather than
    /// letting it emit garbage.
    private func drainRotatedTail() -> [HUDEvent] {
        let rotated = HUDPaths.rotatedURL(for: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: rotated.path),
              let rotatedSize = attrs[.size] as? UInt64,
              rotatedSize > offset,
              let handle = try? FileHandle(forReadingFrom: rotated) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        // A throwaway carry ON PURPOSE. If the rotated file ends mid-line, that
        // line's remainder was written into the OLD inode (the writer's fd
        // survives the rename) — a file we never read again. Carrying those
        // bytes into the new file would prepend garbage to its first line.
        // Discarding is correct; the caller clears `partial` for the same reason.
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
