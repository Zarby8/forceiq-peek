import PeakCore
import SwiftUI

/// Expanded Peek home list: next-session pill, RUNNING cards, and the waiting cards. One vertical ScrollView so a stack
/// taller than the leftover sheet stays reachable (trackpad, mouse wheel, visible scrollbar). Header, GPU light and
/// switcher stay pinned. Peek never changes pipeline / RIFE / queue / 5090-hold state here; it only shows Command's rows.
struct PeekHomeScroll: View {
    @ObservedObject var nextSession: NextSessionModel
    @ObservedObject var running: RunningModel
    @ObservedObject var cards: CardStackViewModel
    @ObservedObject var checklist: MeetingChecklistModel
    @ObservedObject var agents: AgentWatchModel
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                // Ten-minute nudge first when it is due; the live checklist next; then today's brief.
                // The brief names the client and quotes Ghost data, so it only renders on the
                // non-presenting home branch — never while presenting.
                // The while-you-were-away recap at the very top when one is waiting (shown once,
                // then dismissed), then a held Claude approval (it is blocked on the coach and
                // expires), then the CLAUDE watcher section and its last-finish line. All the
                // coach's own infrastructure, never client data; this whole scroll is replaced by
                // the presenting notice while presenting.
                AgentsRecapCard(model: agents)
                ApprovalCard(model: agents)
                AgentsSection(model: agents)
                AgentsFinishLine(model: agents)
                if checklist.nudgeShown && checklist.isLive() { NudgeSection(model: checklist) }
                if checklist.isLive() { ChecklistGrid(model: checklist) }
                if let brief = nextSession.session.flatMap({ SessionBriefBuilder.build(session: $0, since: nextSession.since) }) {
                    SessionBriefCard(brief: brief)
                }
                if nextSession.showsPill {
                    NextSessionPill(model: nextSession).onTapGesture { Haptic.tick(); nextSession.openCard() }
                }
                RunningSection(model: running)
                CardList(cards: cards)
            }
        }
        .scrollIndicators(.visible)
    }
}

/// "Running": the upscales and meeting packs Command is working on right now, as Command reports them. Read-only rows, gold and green
/// on black with pure white text. Hidden while presenting (the whole home view is replaced by the presenting notice then).
struct RunningSection: View {
    @ObservedObject var model: RunningModel
    var body: some View {
        if let f = model.feed, f.known, !f.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUNNING").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Color.white)
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
