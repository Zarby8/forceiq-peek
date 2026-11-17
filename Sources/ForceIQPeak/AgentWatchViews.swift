import PeakCore
import SwiftUI

/// The Claude watcher's faces (spec §5): a dot + count on the collapsed pill, one CLAUDE section
/// on the home sheet, and the approval card — the one interactive surface, pinned above the
/// section when a held request is waiting. Brand rules hold: white text on black, gold/green
/// accents, red is a shape only, nothing dimmed.

func agentDotColor(_ hex: UInt32?) -> Color {
    switch hex {
    case Brand.goldHex: return .peakGold
    case Brand.greenHex: return .peakGreen
    case Brand.redHex: return .peakRed
    default: return .white
    }
}

/// Collapsed pill: one dot (gold pulsing = working, green = waiting, white = done, red = failed)
/// plus the live session count. Nothing else — no names, no text.
struct AgentsPillBadge: View {
    let summary: AgentPillSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            if let hex = summary.dotHex {
                Circle().fill(agentDotColor(hex)).frame(width: 8, height: 8)
                    .phaseAnimator([0.35, 1.0]) { v, p in
                        v.opacity(summary.pulses && !reduceMotion ? p : 1)
                    } animation: { _ in .easeInOut(duration: 0.8) }
            }
            Text("\(summary.count)")
                .font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.white).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
    }
}

/// The home sheet's CLAUDE section: one row per live session (state dot, project folder, tmux
/// label, state + elapsed). A row with a jump target (a tmux pane, or the Claude app for a
/// desktop session) takes a tap and jumps there; a flagged stuck session wears a gold STUCK tag.
struct AgentsSection: View {
    @ObservedObject var model: AgentWatchModel
    var body: some View {
        if !model.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("CLAUDE").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Color.peakGold)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.sessions.prefix(5)) { s in row(s, now: ctx.date) }
                        if model.sessions.count > 5 {
                            Text("+\(model.sessions.count - 5) more")
                                .font(.system(size: 12)).foregroundStyle(Color.white)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder func row(_ s: AgentSession, now: Date) -> some View {
        if SessionJumper.canJump(s) {
            Button { SessionJumper.jump(s) } label: { rowContent(s, now: now) }
                .buttonStyle(.plain)
        } else {
            rowContent(s, now: now)
        }
    }
    func rowContent(_ s: AgentSession, now: Date) -> some View {
        HStack(spacing: 8) {
            Circle().fill(agentDotColor(s.state.dotHex ?? Brand.whiteHex)).frame(width: 8, height: 8)
            Text(s.folder).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.white).lineLimit(1)
            if let t = s.tmuxLabel {
                Text(t).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1)
            }
            if s.isFlaggedStuck {
                Text("STUCK").font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(Color.peakGold).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(s.displayLine(now: now)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.white).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.folder), \(s.displayLine(now: now))\(s.isFlaggedStuck ? ", stuck" : "")")
    }
}

/// The approval card (spec §3.1/§5): a held PermissionRequest or AskUserQuestion, answered here
/// or sent back to the terminal. Shows only the §7 derived summary — it never sees a raw payload.
struct ApprovalCard: View {
    @ObservedObject var model: AgentWatchModel
    var body: some View {
        if let a = model.firstPending {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("CLAUDE IS ASKING").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Color.peakGold)
                    Spacer()
                    if model.queuedCount > 0 {
                        Text("+\(model.queuedCount) asking").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                    }
                }
                Text(sessionLine(a)).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.white).lineLimit(1)
                if a.kind == .permission {
                    Text(a.toolName ?? "Permission").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.white).lineLimit(1)
                    if let s = a.summary {
                        Text(s).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(2)
                    }
                } else if let q = a.question {
                    Text(q).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white).lineLimit(3)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    RunningProgressLine(fraction: a.budgetFraction(now: ctx.date), color: .peakGold)
                }
                if a.kind == .permission {
                    HStack(spacing: 8) {
                        PeakButton(title: "Allow", color: .peakGreen, filled: true) { model.decide(a, .allow) }
                        PeakButton(title: "Deny", color: .peakGold) { model.decide(a, .deny) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(a.options, id: \.self) { option in
                            PeakButton(title: option, color: .peakGold) { model.decide(a, .answer(option)) }
                        }
                        PeakButton(title: "Answer in terminal", color: .white) { model.decide(a, .terminal) }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.peakGold, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Claude is asking. \(a.requestLine)")
        }
    }
    func sessionLine(_ a: AgentApproval) -> String {
        a.tmuxLabel.map { "\(a.folder) · \($0)" } ?? a.folder
    }
}

/// The collapsed pill's watcher line (watcher-plus): a flagged stuck session's folder + working
/// age, or the fresh finish inside its fade window. One short line; the shell shows it only while
/// not presenting (it names a project folder, and presenting shows no names).
struct AgentPillLineView: View {
    let line: AgentPillLine
    var body: some View {
        Text(line.text)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.accessibilityLabel)
    }
}

/// The sheet's last-finish line: the most recent completed turn (folder · done · duration · time),
/// kept until a newer finish supersedes it — even after the session itself has faded or ended.
struct AgentsFinishLine: View {
    @ObservedObject var model: AgentWatchModel
    var body: some View {
        if let f = model.lastFinish {
            HStack(spacing: 8) {
                Circle().fill(Color.white).frame(width: 8, height: 8)
                Text(f.sheetLine).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1)
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last finished: \(f.line)")
        }
    }
}

/// The while-you-were-away recap card: what finished, failed, or lapsed unanswered while the mark
/// slept. The model assembles it on wake; it waits at the top of the home sheet for the first
/// expansion, shows once, and is dismissed here.
struct AgentsRecapCard: View {
    @ObservedObject var model: AgentWatchModel
    var body: some View {
        if let r = model.recap {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("WHILE YOU WERE AWAY").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Color.peakGold)
                    Spacer()
                    PeakButton(title: "Dismiss", color: .white) { model.dismissRecap() }
                }
                ForEach(r.lines) { line in
                    Text(line.text).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.peakGold, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("While you were away: \(r.lines.map(\.text).joined(separator: "; "))")
        }
    }
}
