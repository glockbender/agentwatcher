import Foundation

/// The name a Codex thread goes by, read out of the index Codex keeps beside its transcripts.
///
/// Codex puts a thread's name nowhere near its transcript: it keeps one line per thread in
/// `session_index.jsonl`, keyed by the raw session identifier. The app never holds a raw
/// identifier — the hook process redacts it and the app redacts it again — so it does here
/// exactly what `TranscriptLocator` does with file names: puts every candidate through the
/// same one-way function and looks for its own label. A hash cannot be undone, but it can be
/// recomputed.
public enum CodexThreadIndex {
    /// - Parameter index: the whole file. Unlike a transcript this is one short record per
    ///   thread — 139 lines and 21 KB on the machine this was written on, parsed and hashed
    ///   in well under a millisecond — so there is nothing here worth reading in parts.
    public static func threadName(forSessionLabel label: String, inIndex index: Data) -> String? {
        // Read to the end rather than stopping at the first match: a thread is written again
        // when it is renamed, and the name it started with stays in the file above the real
        // one. The last line is the current answer.
        var name: String?
        for line in index.split(separator: UInt8(ascii: "\n")) {
            guard
                // A line that is not an object is not a failure: the format is undocumented,
                // and the last line of a file being appended to can be half written.
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let identifier = object["id"] as? String,
                HookCaptureRedactor.label(forRawIdentifier: identifier) == label
            else {
                continue
            }
            name = object["thread_name"] as? String ?? name
        }
        return name
    }
}
