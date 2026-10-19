import Foundation

/// What Peek may and may not do. Peek never sends, deletes, edits a DB, invoices or books. Approvals that would are
/// view-only here and open in GOAT. Pipeline progress (upscale, Dagu, publish) is never shown, only "Open in Command".
public enum CardPolicy {
    /// GOAT approval gates (engine/approvals.py GATE_RANK / STRONG) that Peek never acts on.
    public static let viewOnlyGates: Set<String> = ["send", "delete", "invoice/booking", "db", "deploy", "switch", "computer"]
    /// Words that make any item view-only even when its gate looks routine (belt and braces).
    static let viewOnlyWords = try! NSRegularExpression(
        pattern: #"(?i)\b(delet\w*|remov\w*|trash\w*|send\w*|sent|email\w*|text(ing)?|imessage|message\w*|invoic\w*|bill\w*|payment\w*|refund\w*|book(ing|ings|ed)?|reschedul\w*|cancel\w*|db|database|sql|migrat\w*|deploy\w*)\b"#)
    /// Progress Peek never shows (Command owns it).
    static let pipelineWords = try! NSRegularExpression(pattern: #"(?i)\b(upscal\w*|dagu|publish\w*|realesrgan|gpu_and_deliver)\b"#)

    static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func viewOnlyReason(gate: String, text: String) -> String? {
        if viewOnlyGates.contains(gate.lowercased()) {
            return "This approval would \(gateWords(gate)). Peek only shows it; decide it in GOAT."
        }
        if matches(viewOnlyWords, text) {
            return "This approval involves a send, delete, invoice, booking or database change. Peek only shows it; decide it in GOAT."
        }
        return nil
    }

    public static func isPipelineProgress(_ text: String) -> Bool { matches(pipelineWords, text) }

    static func gateWords(_ gate: String) -> String {
        switch gate.lowercased() {
        case "send": return "send a message"
        case "delete": return "delete something"
        case "invoice/booking": return "touch an invoice or a booking"
        case "db": return "edit a database"
        case "deploy": return "deploy"
        default: return "act outside this Mac's routine steps"
        }
    }

    /// Actions a view-only card may still offer: none of them runs anything.
    public static let viewOnlySafeActions: Set<CardAction> = [.openInGOAT, .copyPrompt, .openInCommand]

    public static func isAllowed(_ action: CardAction, on card: PeakCard) -> Bool {
        guard card.actions.contains(action) else { return false }
        if card.viewOnly { return viewOnlySafeActions.contains(action) }
        return true
    }
}

/// Engine rows → cards (used by the modules). Every card names its client; rows without one are counted, never shown.
public enum CardBuilder {
    static func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func meetingCards(_ m: MeetingRow) -> [PeakCard] {
        guard !clean(m.client).isEmpty else { return [] }
        let room = CommandLink.safe(m.openURL)
        let acts: [CardAction] = [.run, .askClaude, .copyPrompt]
        let when = DateFormatter.localizedString(from: m.scheduledAt, dateStyle: .medium, timeStyle: .short)
        return [PeakCard(
            id: "meeting:\(m.client):\(Int(m.scheduledAt.timeIntervalSince1970))", kind: .meeting, client: clean(m.client),
            title: "Next Command meeting", detail: "\(m.durationMinutes) min",
            description: CardDescription(
                inputs: ["Client: \(clean(m.client))", "Meeting: \(m.durationMinutes) min Command session", "Time: \(when)"],
                touches: [room == CommandLink.schedule ? "Run opens Command's schedule (this booking has no session room yet)."
                          : "Run opens the room page in Command. It does not join or record; you tap Join and Record in Command."],
                outputs: ["Command, on the room page. Nothing is sent, booked, joined or changed."]),
            viewOnly: false, viewOnlyReason: nil, actions: acts, startsAt: m.scheduledAt, joinURL: room)]
    }

    public static func fixAndApprovalCards(_ s: EngineSnapshot) -> ModuleOutput {
        var out = ModuleOutput()
        for f in s.fixes {
            if CardPolicy.isPipelineProgress("\(f.title) \(f.message)") { out.pipelineHidden += 1; continue }
            let client = clean(f.client)
            if client.isEmpty { out.unnamed += 1; continue }
            out.cards.append(PeakCard(
                id: "fix:\(client):\(f.title)", kind: .fix, client: client, title: f.title,
                detail: f.state == "running" ? "Fixing now" : f.state.capitalized,
                description: CardDescription(
                    inputs: ["GOAT live status for \(client) (read-only)"],
                    touches: ["Nothing. GOAT is already running this fix; Peek only shows it."],
                    outputs: ["Copy prompt puts a plain summary on your clipboard. Open in GOAT shows the full card."]),
                viewOnly: true, viewOnlyReason: "GOAT is running this fix. Peek only shows it.",
                actions: [.openInGOAT, .copyPrompt]))
        }
        for a in s.approvals where !a.test {
            let text = "\(a.kindLabel) \(a.title) \(a.why) \(a.actLabel) \(a.touches.joined(separator: " "))"
            if CardPolicy.isPipelineProgress(text) { out.pipelineHidden += 1; continue }
            let client = clean(a.client)
            if client.isEmpty { out.unnamed += 1; continue }
            let reason = CardPolicy.viewOnlyReason(gate: a.gate, text: text)
            let acts: [CardAction] = reason == nil ? [.run, .askClaude, .copyPrompt, .openInGOAT] : [.openInGOAT, .copyPrompt]
            out.cards.append(PeakCard(
                id: "approval:\(a.id)", kind: .approval, client: client, title: a.title, detail: a.kindLabel,
                description: CardDescription(
                    inputs: ["GOAT approval \(a.id) for \(client): \(a.why.isEmpty ? a.title : a.why)"],
                    touches: a.touches.isEmpty ? ["GOAT's own approve path on this Mac (\(a.actLabel.isEmpty ? a.kind : a.actLabel))"] : a.touches,
                    outputs: (a.outputs.isEmpty ? ["What GOAT reports back"] : a.outputs)
                        + [reason == nil ? "Run asks GOAT to approve it; anything that needs a confirm stops and opens GOAT." : "View-only here."]),
                viewOnly: reason != nil, viewOnlyReason: reason, actions: acts, engineID: a.id))
        }
        return out
    }

    public static func familyCards(_ s: EngineSnapshot) -> ModuleOutput {
        var out = ModuleOutput()
        guard s.familyEnabled else { return out }
        for f in s.family {
            let client = clean(f.client)
            if client.isEmpty { out.unnamed += 1; continue }
            var acts: [CardAction] = [.copyPrompt, .openInGOAT]
            if let l = f.link, l.lowercased().hasPrefix("https://") { acts.insert(.copyLink(l), at: 0) }
            out.cards.append(PeakCard(
                id: "family:\(f.jobID)", kind: .family, client: client, title: "Family can't open the meeting yet",
                detail: f.meetingDate,
                description: CardDescription(
                    inputs: ["Command family-delivery alert for \(client) (read-only)"],
                    touches: ["Your clipboard only. Nothing is sent to the family."],
                    outputs: [f.reason]),
                viewOnly: false, viewOnlyReason: nil, actions: acts))
        }
        return out
    }
}
