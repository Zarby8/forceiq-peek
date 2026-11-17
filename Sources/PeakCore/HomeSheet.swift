import Foundation

/// The expanded sheet's section plan (Nov 17, 2026): the home tab is no longer one
/// undifferentiated scroll. Sections render in a fixed urgency order — what needs the
/// coach, then what's next, then what's later, navigation last (the launcher stays a
/// footer outside the scroll, in the app target) — and a section with no content never
/// renders, label included. Pure value logic so the ordering and the suppression rules
/// are unit-tested; the SwiftUI home view derives the content flags from its models
/// and renders exactly this plan.
public enum HomeSheetSection: String, CaseIterable, Sendable {
    case now, nextSession, agents, running, tonight, business, waiting

    /// The on-sheet label, in the sheet's small-caps gold treatment.
    public var label: String {
        switch self {
        case .now: return "NOW"
        case .nextSession: return "NEXT SESSION"
        case .agents: return "AGENTS"
        case .running: return "RUNNING"
        case .tonight: return "TONIGHT"
        case .business: return "BUSINESS"
        case .waiting: return "WAITING"
        }
    }
}

/// The profile gates the sections answer to, resolved by the app from the coach
/// profile (and, for the watcher, the settings switch that can also turn it on —
/// the same resolution AppDelegate uses to start the watcher).
public struct HomeSheetGates: Equatable, Sendable {
    public var meetings: Bool
    public var agents: Bool
    public var spend: Bool
    public init(meetings: Bool, agents: Bool, spend: Bool) {
        self.meetings = meetings; self.agents = agents; self.spend = spend
    }
}

/// What the home sheet currently has to show, as bare presence flags. The view fills
/// these from its models on every render; agent-derived items (recap, the held
/// approval, the finish line) are only ever set when the agents gate is on, because
/// the watcher model stays empty while it is off — the plan still re-checks the gate
/// so the rule holds by construction, not by wiring luck.
public struct HomeSheetContent: Equatable, Sendable {
    public var gates: HomeSheetGates
    // NOW: live state.
    public var hasRecap = false
    public var hasApproval = false
    public var hasPresence = false
    public var hasNeedsYou = false
    public var hasFinish = false
    // NEXT SESSION: the brief, the live checklist, its nudge, the next-session pill.
    public var hasNudge = false
    public var hasChecklist = false
    public var hasBrief = false
    public var hasNextPill = false
    // AGENTS: the watcher session rows.
    public var hasAgentSessions = false
    // RUNNING: Command's in-flight rows (or its didn't-answer line).
    public var hasRunning = false
    // TONIGHT: the evening games line.
    public var hasTonight = false
    // BUSINESS: the past-due money line.
    public var hasMoney = false
    // WAITING: the card stack. The stack always renders at least its status rows
    // (profile notice / sign-in / all-clear), so the section always renders; its
    // label only appears when actual cards or card footers are waiting.
    public var waitingCards = 0
    public var waitingExtras = false

    public init(gates: HomeSheetGates) { self.gates = gates }
}

public enum HomeSheetPlan {
    /// The sections to render, in sheet order. NOW always leads: the GPU/meeting
    /// status line always has a state, so at minimum NOW is that one quiet line —
    /// never an empty labeled box. WAITING always closes the scroll: the card stack
    /// always carries at least its status rows.
    public static func sections(_ c: HomeSheetContent) -> [HomeSheetSection] {
        var out: [HomeSheetSection] = [.now]
        if c.gates.meetings, c.hasNudge || c.hasChecklist || c.hasBrief || c.hasNextPill {
            out.append(.nextSession)
        }
        if c.gates.agents, c.hasAgentSessions {
            out.append(.agents)
        }
        if c.hasRunning {
            out.append(.running)
        }
        if c.gates.meetings, c.hasTonight {
            out.append(.tonight)
        }
        if c.gates.spend, c.hasMoney {
            out.append(.business)
        }
        out.append(.waiting)
        return out
    }

    /// Whether the section wears the wrapper's label. Two blocks label themselves:
    /// the watcher block carries its own CLAUDE heading in the same gold small-caps
    /// treatment, and the waiting stack only earns its label when cards (or their
    /// footers) are actually waiting — over a lone status row it stays unlabeled.
    public static func showsLabel(_ s: HomeSheetSection, _ c: HomeSheetContent) -> Bool {
        switch s {
        case .agents: return false
        case .waiting: return c.waitingCards > 0 || c.waitingExtras
        default: return true
        }
    }
}
