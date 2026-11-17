import Foundation

// Click a desktop session row → jump INTO the Claude thread (watcher-plus follow-up), and show the
// thread's own title on the row.
//
// The Claude desktop app handles claude://code/continue?session=<id>, where <id> is "last" or its
// own sessionId matching ^local_[A-Za-z0-9-]{1,64}$. Peek's hooks report the CLI session id (a UUID),
// not the desktop id; the bridge is the app's on-disk session records:
//   ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json
// each carrying {"sessionId": "local_…", "cliSessionId": "<the UUID the hooks report>",
// "title": "<the chat's name in the desktop app>", …}. The title is user-facing metadata the app
// itself displays — Peek reads it from the record matched by cliSessionId, never from transcripts
// or prompts.
// This type is the pure part: parse a record, validate the id shape, build the URL. The app side
// (SessionJumper) does the directory scan at display/click time.

public enum ClaudeSessionLink {
    /// One parsed session record: the desktop id, the CLI id Peek's hooks report, and the chat's
    /// title in the desktop app (nil when the record has no usable title).
    public struct Record: Equatable, Sendable {
        public let sessionId: String
        public let cliSessionId: String
        public let title: String?
        public init(sessionId: String, cliSessionId: String, title: String?) {
            self.sessionId = sessionId; self.cliSessionId = cliSessionId; self.title = title
        }
    }

    /// A desktop sessionId is `local_` + 1…64 of [A-Za-z0-9-]. ("last" is the handler's other accepted
    /// value; Peek never builds it — a row jump names its own session.)
    public static func isValidSessionID(_ s: String) -> Bool {
        guard s.hasPrefix("local_") else { return false }
        let rest = s.dropFirst("local_".count)
        guard !rest.isEmpty, rest.count <= 64 else { return false }
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// One session record's JSON → its Record. nil for malformed JSON, a record that isn't an
    /// object, missing/empty ids, or a sessionId the handler would reject. A missing, non-string
    /// or blank title is NOT a failure: the record still maps the ids, with title nil.
    public static func parseRecord(_ data: Data) -> Record? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sid = o["sessionId"] as? String, isValidSessionID(sid),
              let cli = o["cliSessionId"] as? String, !cli.isEmpty else { return nil }
        let raw = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Record(sessionId: sid, cliSessionId: cli, title: (raw?.isEmpty ?? true) ? nil : raw)
    }

    /// The continue URL for a validated desktop sessionId; nil for anything the handler would reject.
    public static func continueURL(sessionId: String) -> String? {
        guard isValidSessionID(sessionId) else { return nil }
        return "claude://code/continue?session=\(sessionId)"
    }
}
