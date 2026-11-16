import PeakCore
import SwiftUI

/// The live coaching checklist: the read → technique → execution → finishing stages as a compact
/// 2x2 grid, tappable to mark covered. Stages and times only — no client name anywhere — so the
/// grid and the pill line are presenting-safe. A gold outline marks the first uncovered stage
/// (the one the coach is on); a covered stage gets a gold check.
struct ChecklistGrid: View {
    @ObservedObject var model: MeetingChecklistModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("LIVE SESSION").font(.system(size: 10, weight: .heavy)).tracking(1)
                    .foregroundStyle(Color.peakGold)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(model.elapsedText() ?? "--:--")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.white)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ChecklistStage.allCases) { stage in
                    stageTile(stage)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder func stageTile(_ stage: ChecklistStage) -> some View {
        let covered = model.covered.contains(stage)
        let isCurrent = model.parkingLot.first == stage
        let isClosing = model.closing == stage
        Button {
            Haptic.tick()
            model.toggle(stage)
        } label: {
            HStack {
                Text(stage.label).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.white)
                Spacer()
                Text(covered ? "✓" : isCurrent ? "●" : "○")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(covered || isCurrent ? Color.peakGold : Color.white)
                if isClosing {
                    Text("CLOSING").font(.system(size: 9, weight: .heavy)).tracking(1)
                        .foregroundStyle(Color.peakGold)
                }
            }
            .frame(minHeight: 28, alignment: .center)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isCurrent ? Color.peakGold : Color.white.opacity(0.25), lineWidth: isCurrent ? 1.5 : 1))
        .accessibilityLabel(Text("\(stage.label) \(covered ? "covered" : "not covered")\(isClosing ? ", closing on this" : "")"))
    }
}

/// The collapsed pill line during a live meeting: elapsed time plus one mark per stage.
/// Ticks every 30s (the app's coarse-tick rule); the model publishes on the 30s refresh too.
struct ChecklistPillLine: View {
    @ObservedObject var model: MeetingChecklistModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(model.collapsedText() ?? "")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// The ten-minute nudge: the notch has expanded itself with the uncovered stages as a ranked
/// parking lot. Picking one marks it "Closing on this" — the stage stays uncovered until its
/// tile is tapped. Dismissing holds for this meeting. Stage names only, so it is presenting-safe.
struct NudgeSection: View {
    @ObservedObject var model: MeetingChecklistModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("CLOSE ON ONE · \(remainingText()) LEFT")
                        .font(.system(size: 10, weight: .heavy)).tracking(1)
                        .foregroundStyle(Color.peakGold)
                }
                Spacer()
                Button { Haptic.tick(); model.dismissNudge() } label: {
                    Text("Dismiss").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
                        .frame(minHeight: 28, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss the closing nudge for this meeting"))
            }
            ForEach(Array(model.parkingLot.enumerated()), id: \.offset) { idx, stage in
                HStack(spacing: 8) {
                    Text("\(idx + 1)").font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.peakGold)
                    Text(stage.label).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.white)
                    Spacer()
                    if model.closing == stage {
                        Text("Closing on this").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.peakGold)
                    } else {
                        PeakButton(title: "Close on this") {
                            Haptic.tick()
                            model.closeOn(stage)
                        }
                    }
                }
                .frame(minHeight: 28)
            }
            if model.parkingLot.isEmpty {
                Text("All four stages covered — close on the strongest one.")
                    .font(.system(size: 12)).foregroundStyle(Color.white)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.peakGold, lineWidth: 1))
    }

    func remainingText() -> String {
        guard let span = model.liveSpan else { return "--:--" }
        return MeetingClock.remainingText(span: span, now: Date())
    }
}
