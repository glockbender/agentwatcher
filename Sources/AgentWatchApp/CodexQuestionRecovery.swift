import AgentWatchCore
import AgentWatchLookup
import Foundation

/// Reads backwards after a restart: the newest question or reply for a saved ID decides it.
/// Only unresolved IDs survive between batches. Older conversation content is never retained.
struct CodexQuestionRecovery {
    let open: Set<String>
    let offset: UInt64

    static func read(at url: URL, through end: UInt64, questions: Set<String>) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let blockSize = SessionDescriptionResolver.transcriptTailByteCount
        let maximum = TranscriptReader.maximumIncrementByteCount

        func bytes(before cursor: UInt64, limit: Int) throws -> (start: UInt64, data: Data) {
            let count = Int(min(cursor, UInt64(limit)))
            let start = cursor - UInt64(count)
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw CocoaError(.fileReadCorruptFile) }
            return (start, data)
        }

        // Leave a trailing fragment for the first live poll, even when the file grows during recovery.
        var offset = end
        while offset > 0 {
            let block = try bytes(before: offset, limit: blockSize)
            if let newline = block.data.lastIndex(of: 0x0A) {
                offset = block.start + UInt64(newline + 1)
                break
            }
            offset = block.start
        }

        var cursor = offset
        var limit = blockSize
        var unresolved = questions
        var open: Set<String> = []
        while cursor > 0, !unresolved.isEmpty {
            let block = try bytes(before: cursor, limit: limit)
            let begin: Int
            if block.start == 0, block.data.count <= maximum {
                begin = 0
            } else if let newline = block.data.dropLast().firstIndex(of: 0x0A) {
                begin = newline + 1
            } else {
                // Grow only for a single long record. If it exceeds the live reader's limit,
                // it might contain a reply; an older opening cannot confirm the remaining IDs.
                guard limit < maximum + 1 else { break }
                limit = min(limit * 2, maximum + 1)
                continue
            }
            let increment = try TranscriptReader.read(
                increment: Data(block.data[begin...]), source: .codex, observedAt: .distantPast)
            for fact in increment.facts.reversed() {
                switch fact {
                case let .codexQuestionAsked(id, _):
                    if unresolved.remove(id) != nil { open.insert(id) }
                case let .codexQuestionAnswered(id, _):
                    unresolved.remove(id)
                case .turnInterrupted:
                    unresolved.removeAll()
                default: break
                }
            }
            cursor = block.start + UInt64(begin)
            limit = blockSize
        }
        return Self(open: open, offset: offset)
    }
}
