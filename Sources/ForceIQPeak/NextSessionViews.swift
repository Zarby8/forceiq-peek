import PeakCore
import SwiftUI

// The next-session pill and its one-glance card (read-only; see PeakCore/NextSession.swift). Pure white text on black at
// full opacity; the gold / green outline and the glow are on the capsule shape only. The countdown is a coarse
// TimelineView(.periodic) (every 30 s, NextSessionStyle.tickSeconds; the CPU guard reads the literal): no animation loop, nothing redraws between ticks.

struct NextSessionPill: View {
    @ObservedObject var model: NextSessionModel
    var compact = false
    var accent: Color { Color(hex: NextSessionStyle.outlineHex(gold: model.gold)) }
    var body: some View {
        if model.showsPill {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(model.pillText(now: ctx.date) ?? "")
                    .font(.system(size: compact ? 11 : 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(hex: NextSessionStyle.textHex)).lineLimit(1)
                    .padding(.horizontal, compact ? 8 : 12)
                    .frame(minHeight: compact ? 18 : PeakMotion.minTapTarget)
                    .background(
                        Capsule().fill(Color.black)
                            .overlay(Capsule().stroke(accent, lineWidth: model.gold ? 2 : 1))
                            .shadow(color: model.gold ? accent : Color.black, radius: model.gold ? 5 : 0)
                    )
                    .contentShape(Capsule())
            }
        }
    }
}

/// Collapsed notch: no room for a name, so a small gold dot (a shape) says a gap is waiting; the name is in the pill.
struct NextSessionDot: View {
    @ObservedObject var model: NextSessionModel
    var body: some View {
        if model.showsPill && model.gold {
            Circle().fill(Color(hex: NextSessionStyle.goldHex)).frame(width: 7, height: 7)
                .shadow(color: Color(hex: NextSessionStyle.goldHex), radius: 3)
        }
    }
}

/// The one-glance card: who, when, what changed since last met, and each gap with Ask TRON / Copy (clipboard only).
struct NextSessionCard: View {
    @ObservedObject var model: NextSessionModel
    var gold: Color { Color(hex: NextSessionStyle.goldHex) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let s = model.session {
                    HStack {
                        Text(s.client).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.white)
                        Text(DateFormatter.localizedString(from: s.scheduledAt, dateStyle: .medium, timeStyle: .short))
                            .font(.system(size: 13)).foregroundStyle(Color.white).lineLimit(1)
                        Spacer()
                        PeakButton(title: "Back", color: .white) { model.closeCard() }
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("\(s.durationMinutes) min \(s.sessionType.isEmpty ? "session" : s.sessionType), \(NextSessionCountdown.text(to: s.scheduledAt, now: ctx.date))")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                    }
                    header("Since last met")
                    if let x = model.since {
                        ForEach(Array(x.lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(2)
                        }
                        if !x.note.isEmpty { Text(x.note).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(2) }
                    } else {
                        Text("Ghost had nothing for this client.").font(.system(size: 12)).foregroundStyle(Color.white)
                    }
                    header("Gaps")
                    if model.warnings.isEmpty {
                        Text("No gaps found.").font(.system(size: 12)).foregroundStyle(Color.white)
                    }
                    ForEach(model.warnings) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(w.state == .present ? "GAP" : "UNKNOWN").font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(w.state == .present ? gold : Color.white)
                                Text(w.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(2)
                            }
                            if !w.note.isEmpty { Text(w.note).font(.system(size: 11)).foregroundStyle(Color.white).lineLimit(3) }
                            HStack(spacing: 8) {
                                ForEach(w.actions, id: \.self) { a in
                                    PeakButton(title: a.label, color: gold) { model.perform(a, on: w) }
                                }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(w.state == .present ? gold : Color.white, lineWidth: 1))
                    }
                    Text("Read-only. Ask TRON and Copy only put text on your clipboard; nothing is sent, booked or invoiced.")
                        .font(.system(size: 11)).foregroundStyle(Color.white)
                    if let r = model.lastAction { Text(r).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(2) }
                }
            }
        }
        .scrollIndicators(.never)
    }
    func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.peakGreen)
    }
}
