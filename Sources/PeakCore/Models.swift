import Foundation

/// What a card does, in plain words. Shown on the first tap, before any button can run.
public struct CardDescription: Equatable, Sendable {
    public let inputs: [String]
    public let touches: [String]
    public let outputs: [String]
    public init(inputs: [String], touches: [String], outputs: [String]) {
        self.inputs = inputs; self.touches = touches; self.outputs = outputs
    }
}

public enum CardKind: String, Sendable { case meeting, fix, approval, family }

public enum CardAction: Equatable, Sendable, Hashable {
    case run                 // the card's one explicit action (see CardPolicy for what that is per kind)
    case askClaude           // advice only (GOAT's own ask path); never runs anything
    case copyPrompt          // clipboard only
    case openInGOAT          // activates GOAT
    case openInCommand       // opens Command (pipeline progress lives there)
    case openURL(String)     // Join / Open: opens the URL only
    case copyLink(String)    // clipboard only (family link)

    public var label: String {
        switch self {
        case .run: return "Run"
        case .askClaude: return "Ask Claude"
        case .copyPrompt: return "Copy prompt"
        case .openInGOAT: return "Open in GOAT"
        case .openInCommand: return "Open in Command"
        case .openURL: return "Open"
        case .copyLink: return "Copy family link"
        }
    }
}

public struct PeakCard: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: CardKind
    public let client: String            // never empty (CardBuilder drops anything without a client)
    public let title: String
    public let detail: String
    public let description: CardDescription
    public let viewOnly: Bool            // deletes / sends / invoices / bookings / DB edits: view here, act in GOAT
    public let viewOnlyReason: String?
    public let actions: [CardAction]     // the buttons offered AFTER the description is shown
    public let startsAt: Date?           // meeting countdown
    public let engineID: String?         // approvals: the 12-hex id the engine knows
    public let joinURL: String?          // meeting: Command's ROOM page Run opens (CommandLink; never a join URL)

    public init(id: String, kind: CardKind, client: String, title: String, detail: String, description: CardDescription,
                viewOnly: Bool, viewOnlyReason: String?, actions: [CardAction], startsAt: Date? = nil, engineID: String? = nil, joinURL: String? = nil) {
        self.id = id; self.kind = kind; self.client = client; self.title = title; self.detail = detail
        self.description = description; self.viewOnly = viewOnly; self.viewOnlyReason = viewOnlyReason
        self.actions = actions; self.startsAt = startsAt; self.engineID = engineID; self.joinURL = joinURL
    }
}

/// Raw engine rows (tolerant decoding from the local GOAT engine's JSON; unknown fields ignored).
public struct MeetingRow: Equatable, Sendable {
    public let client: String
    public let scheduledAt: Date
    public let durationMinutes: Int
    public let joinURL: String?
    public let openURL: String
}

public struct FixRow: Equatable, Sendable {
    public let title: String
    public let client: String
    public let state: String
    public let message: String
}

public struct ApprovalRow: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let kindLabel: String
    public let title: String
    public let why: String
    public let client: String
    public let gate: String
    public let touches: [String]
    public let outputs: [String]
    public let actLabel: String
    public let test: Bool
}

/// A finished shift download from GOAT's live doc (`what` is "Shift download · <client> · <opponent> · <date>").
public struct DownloadDone: Equatable, Sendable {
    public let id: String
    public let client: String
    public init(id: String, client: String) { self.id = id; self.client = client }
}

public struct FamilyRow: Equatable, Sendable {
    public let jobID: String
    public let client: String
    public let reason: String
    public let link: String?
    public let meetingDate: String
}

public struct EngineSnapshot: Equatable, Sendable {
    public var meeting: MeetingRow?
    public var meetingError: String?
    public var commandSignIn: CommandSignInNotice? = nil   // Command's dashboard sign-in expired (engine auth: "expired")
    public var fixes: [FixRow] = []
    public var fixesRunning: Int = 0
    public var downloadsRunning: Int = 0
    public var downloadPercents: [Double] = []         // percent (0-100) of each running download that reports one
    public var downloadsDone: [DownloadDone] = []      // shift downloads GOAT reports finished (the Live Activity set: shift downloads only)
    public var approvals: [ApprovalRow] = []
    public var familyEnabled = false
    public var family: [FamilyRow] = []
    public var errors: [String] = []
    // "What's my day" + the 5090 light (DayBrief.swift, GPULight.swift). nil = not in this read (old engine / failed).
    public var today: [SessionRow]? = nil              // next-meeting `today`: this coach's named sessions today
    public var gpuWindow: GPUWindow? = nil             // next-meeting `gpu_window`: times the 5090 must hold around
    public var fixesNeeded: [BriefItem] = []           // /api/live `fixes_needed` (BLOCKED)
    public var liveAt: Date? = nil                     // /api/live doc's own write time
    public var approvalsAt: Date? = nil                // /api/approvals listing time
    public var takenAt: Date? = nil                    // when Peak made this read
    public init() {}
}
