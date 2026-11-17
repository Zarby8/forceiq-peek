import PeakCore
import SwiftUI

/// Expanded Peek home list, sectioned (Nov 17, 2026): NOW (live state), NEXT SESSION
/// (brief + checklist), AGENTS (the watcher rows), RUNNING (Command's in-flight jobs),
/// TONIGHT (the evening games line), BUSINESS (the past-due money line), WAITING (the
/// card stack). One vertical ScrollView so a stack taller than the leftover sheet stays
/// reachable (trackpad, mouse wheel, visible scrollbar). The section order, the module
/// gates and the empty-section suppression come from HomeSheetPlan (PeakCore,
/// unit-tested); this view only derives the content flags and renders the plan.
/// Header and the switcher footer stay pinned outside the scroll. Peek never changes
/// pipeline / queue / hold state here; it only shows Command's rows.
struct PeekHomeScroll: View {
    @ObservedObject var nextSession: NextSessionModel
    @ObservedObject var running: RunningModel
    @ObservedObject var cards: CardStackViewModel
    @ObservedObject var checklist: MeetingChecklistModel
    @ObservedObject var agents: AgentWatchModel
    @ObservedObject var light: GPULightModel
    let gates: HomeSheetGates

    var brief: SessionBrief? {
        nextSession.session.flatMap { SessionBriefBuilder.build(session: $0, since: nextSession.since) }
    }

    /// The plan's input, derived from the models on every render. Agent-derived items
    /// are ANDed with the agents gate here as well as in the plan: the watcher model
    /// stays empty while the module is off, and the flags say so explicitly.
    var content: HomeSheetContent {
        var c = HomeSheetContent(gates: gates)
        c.hasRecap = gates.agents && agents.recap != nil
        c.hasApproval = gates.agents && agents.firstPending != nil
        c.hasPresence = cards.presenceLine != nil
        c.hasNeedsYou = !cards.needsYou.isEmpty
        c.hasFinish = gates.agents && agents.lastFinish != nil
        c.hasNudge = checklist.nudgeShown && checklist.isLive()
        c.hasChecklist = checklist.isLive()
        c.hasBrief = brief != nil
        c.hasNextPill = nextSession.showsPill
        c.hasAgentSessions = !agents.sessions.isEmpty
        c.hasRunning = running.unavailable || ((running.feed?.known ?? false) && !(running.feed?.rows.isEmpty ?? true))
        c.hasTonight = cards.tonightText != nil
        c.hasMoney = cards.moneyLine != nil
        c.waitingCards = cards.cards.count
        c.waitingExtras = cards.pipelineHidden > 0 || cards.unnamed > 0
        return c
    }

    var body: some View {
        let plan = HomeSheetPlan.sections(content)
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.enumerated()), id: \.element) { idx, section in
                    if idx > 0 { SheetSectionRule() }
                    sectionView(section)
                }
            }
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder func sectionView(_ section: HomeSheetSection) -> some View {
        let label = HomeSheetPlan.showsLabel(section, content) ? section.label : nil
        switch section {
        case .now:
            // Live state only. The while-you-were-away recap waits at the very top while
            // one is current (shown once, then dismissed); a held Claude approval next
            // (it is blocked on the coach and expires); then the standing lines — the
            // GPU/meeting status, the other coach's presence, the needs-you faults in
            // plain words, and the last finish while it is current. All the coach's own
            // infrastructure, never client data; this whole scroll is replaced by the
            // presenting notice while presenting.
            SheetSection(label: label) {
                AgentsRecapCard(model: agents)
                ApprovalCard(model: agents)
                GPULightDot(light: light)
                PresenceLineView(cards: cards)
                NeedsYouSection(cards: cards)
                AgentsFinishLine(model: agents)
            }
        case .nextSession:
            // The ten-minute nudge first when it is due; the live checklist next; then
            // today's brief. The brief names the client and quotes Ghost data, so it
            // only renders on this non-presenting home branch — never while presenting.
            SheetSection(label: label) {
                if checklist.nudgeShown && checklist.isLive() { NudgeSection(model: checklist) }
                if checklist.isLive() { ChecklistGrid(model: checklist) }
                if let brief { SessionBriefCard(brief: brief) }
                if nextSession.showsPill {
                    NextSessionPill(model: nextSession).onTapGesture { Haptic.tick(); nextSession.openCard() }
                }
            }
        case .agents:
            // The watcher rows. The block carries its own heading in the same gold
            // small-caps treatment, so the plan gives it no second label.
            SheetSection(label: label) {
                AgentsSection(model: agents)
            }
        case .running:
            SheetSection(label: label) {
                RunningSection(model: running)
            }
        case .tonight:
            SheetSection(label: label) {
                TonightLineView(cards: cards)
            }
        case .business:
            SheetSection(label: label) {
                MoneyLineView(cards: cards)
            }
        case .waiting:
            SheetSection(label: label) {
                CardList(cards: cards)
            }
        }
    }
}

/// Stage 6 presence: "{coach} is meeting with {client}" while the other coach's session is live.
/// Home-scroll only, so never while presenting (it names a client).
struct PresenceLineView: View {
    @ObservedObject var cards: CardStackViewModel
    var body: some View {
        if let line = cards.presenceLine {
            Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Stage 5 "needs you": stack faults in plain words, once (latched in the view model — a persistent
/// fault never re-nags). Silent when all is fine. Lives inside the NOW section (the section
/// label covers it — no second heading here). Home-scroll only, so never while presenting.
struct NeedsYouSection: View {
    @ObservedObject var cards: CardStackViewModel
    var body: some View {
        if !cards.needsYou.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cards.needsYou, id: \.id) { f in
                    Text(f.line).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Stage 5 money line: the past-due rollup, invisible until at least one invoice is past due.
struct MoneyLineView: View {
    @ObservedObject var cards: CardStackViewModel
    var body: some View {
        if let line = cards.moneyLine {
            Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.peakGold).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Running": the upscales and meeting packs Command is working on right now, as Command reports them. Read-only rows, gold and green
/// on black with pure white text. Hidden while presenting (the whole home view is replaced by the presenting notice then).
/// The RUNNING label comes from the section wrapper; this block is just the rows.
struct RunningSection: View {
    @ObservedObject var model: RunningModel
    var body: some View {
        if let f = model.feed, f.known, !f.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(f.rows) { RunningRowView(row: $0) }
            }
        } else if model.unavailable {
            Text("Running status unavailable: Command didn't answer.").font(.system(size: 12)).foregroundStyle(Color.white)
        }
    }
}

struct RunningRowView: View {
    let row: RunningRow
    var accent: Color { row.needsLook ? .peakGold : .peakGreen }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(RunningText.title(row)).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.white).lineLimit(1)
                Spacer(minLength: 8)
                if let p = row.percent {
                    Text(RunningText.percent(p)).font(.system(size: 12, weight: .heavy).monospacedDigit()).foregroundStyle(Color.white)
                }
            }
            if !RunningText.status(row).isEmpty {
                Text(RunningText.status(row)).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1)
            }
            if let p = row.percent { RunningProgressLine(fraction: p / 100, color: accent) }
            if let foot = RunningText.footnote(row) {
                Text(foot).font(.system(size: 11)).foregroundStyle(Color.white).lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(RunningText.title(row)). \(RunningText.status(row)). \(row.percent.map(RunningText.percent) ?? "")"))
    }
}

/// A thin outlined track with a fill: a shape, so no gray anywhere.
struct RunningProgressLine: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().stroke(color, lineWidth: 1)
                Capsule().fill(color).frame(width: max(4, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// One labeled zone of the sectioned home sheet: the label in the sheet's small-caps
/// gold treatment (the one-thing brief's), then the zone's rows. A nil label renders
/// the rows bare — the watcher block labels itself, and the waiting stack only earns
/// its label when cards are actually waiting (HomeSheetPlan.showsLabel decides).
struct SheetSection<Content: View>: View {
    let label: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label).font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Color.peakGold)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The thin separator between two sections: a full-strength gold hairline — the brand
/// rule allows no dimmed or grey strokes anywhere on the sheet.
struct SheetSectionRule: View {
    var body: some View {
        Rectangle().fill(Color.peakGold).frame(height: 1)
    }
}

/// Tonight's games, evenings only: the same line the collapsed pill carries once the
/// day's sessions are over (CardStackViewModel.tonightText already carries the gating).
struct TonightLineView: View {
    @ObservedObject var cards: CardStackViewModel
    var body: some View {
        if let t = cards.tonightText {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
