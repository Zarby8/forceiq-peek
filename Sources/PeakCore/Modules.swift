import Foundation

/// Peek modules. PR 1 ships meetings, approvals (GOAT fixes + approvals), family (behind GOAT_FAMILY_DELIVERY_ALERTS)
/// and the app switcher. The rest are declared so they slot in later; each is on/off per coach profile.
public enum PeakModuleID: String, Sendable, CaseIterable {
    case meetings, approvals, switcher, family
    case drops, threePO = "3po", voice, machineGlance = "machine_glance", spend
    public static let shipped: [PeakModuleID] = [.meetings, .approvals, .family, .switcher, .threePO, .spend, .drops]
}

public protocol PeakModule: Sendable {
    var id: PeakModuleID { get }
    func isEnabled(_ p: CoachProfile) -> Bool
    /// Cards from the local engine snapshot (every card names its client).
    func cards(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput
    /// Deep links this module owns (forceiq-peak://…).
    func handles(_ a: PeakURLAction) -> Bool
}

public struct ModuleOutput: Equatable, Sendable {
    public var cards: [PeakCard] = []
    public var unnamed = 0
    public var pipelineHidden = 0
    public init(cards: [PeakCard] = [], unnamed: Int = 0, pipelineHidden: Int = 0) {
        self.cards = cards; self.unnamed = unnamed; self.pipelineHidden = pipelineHidden
    }
}

extension PeakModule {
    public func isEnabled(_ p: CoachProfile) -> Bool { p.isEnabled(id) }
    public func handles(_ a: PeakURLAction) -> Bool { false }
}

public struct MeetingsModule: PeakModule {
    public let id = PeakModuleID.meetings
    public init() {}
    public func cards(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput {
        guard let m = s.meeting else { return ModuleOutput() }
        return ModuleOutput(cards: CardBuilder.meetingCards(m))
    }
}

public struct ApprovalsModule: PeakModule {
    public let id = PeakModuleID.approvals
    public init() {}
    public func cards(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput { CardBuilder.fixAndApprovalCards(s) }
}

public struct FamilyModule: PeakModule {
    public let id = PeakModuleID.family
    public init() {}
    public func cards(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput { CardBuilder.familyCards(s) }
}

public struct SwitcherModule: PeakModule {
    public let id = PeakModuleID.switcher
    public init() {}
    public func cards(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput { ModuleOutput() }   // a row, not cards
    public func handles(_ a: PeakURLAction) -> Bool { if case .switchApp = a { return true }; return false }
}

/// 3PO chat: no cards on the home list; it owns the forceiq-peak://3po deep link (model pick).
public struct ThreePOModule: PeakModule {
    public let id = PeakModuleID.threePO
    public init() {}
    public func cards(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput { ModuleOutput() }
    public func handles(_ a: PeakURLAction) -> Bool { if case .threePOModel = a { return true }; return false }
}

public enum ModuleRegistry {
    public static let all: [any PeakModule] = [MeetingsModule(), ApprovalsModule(), FamilyModule(), SwitcherModule(), ThreePOModule()]

    /// Enabled modules' cards, then the coach filter: a card whose client isn't on this coach's roster is never shown
    /// (it's counted as "more in GOAT" so nothing vanishes silently).
    public static func build(_ s: EngineSnapshot, _ p: CoachProfile) -> ModuleOutput {
        var out = ModuleOutput()
        for m in all where m.isEnabled(p) {
            let o = m.cards(s, p)
            for c in o.cards {
                if p.isMyClient(c.client) { out.cards.append(c) } else { out.unnamed += 1 }
            }
            out.unnamed += o.unnamed; out.pipelineHidden += o.pipelineHidden
        }
        return out
    }

    public static func owner(of a: PeakURLAction, _ p: CoachProfile) -> PeakModuleID? {
        all.first { $0.handles(a) }.map(\.id)
    }

    /// A deep link a module owns runs only when that module is enabled for this coach.
    public static func allows(_ a: PeakURLAction, _ p: CoachProfile) -> Bool {
        guard let id = owner(of: a, p) else { return true }
        return p.isEnabled(id)
    }
}
