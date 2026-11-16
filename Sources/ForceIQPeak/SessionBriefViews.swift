import PeakCore
import SwiftUI

/// The one-thing brief card on the home sheet: today's teaching point, the lines behind it,
/// the game to pull in FLOW, and one plain line on what the feed cannot say. Read-only —
/// nothing here sends, books or changes anything. Never shown while presenting (it names the
/// client and quotes Ghost data); the home sheet only renders it on the non-presenting branch.
struct SessionBriefCard: View {
    let brief: SessionBrief
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY'S ONE THING").font(.system(size: 10, weight: .heavy)).tracking(1)
                .foregroundStyle(Color.peakGold)
            Text(brief.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
                .lineLimit(3)
            ForEach(Array(brief.supportLines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(2)
            }
            Text(brief.filmLine).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                .lineLimit(2)
            Text(brief.caveat).font(.system(size: 11)).foregroundStyle(Color.white).lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.peakGold, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Today's one thing. \(brief.headline) \(brief.filmLine)"))
    }
}
