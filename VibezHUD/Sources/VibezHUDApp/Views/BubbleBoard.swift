import SwiftUI
import VibezSessionKit

struct BubbleBoard: View {
    let snapshot: HUDSnapshot
    let onTap: (Session) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            column("NEEDS YOU", HUDTheme.needsYou, snapshot.needsYou)
            column("DONE", HUDTheme.done, snapshot.done)
            column("WORKING", HUDTheme.working, snapshot.working)
        }
        .padding(.top, 34)          // clears the notch
        .padding([.horizontal, .bottom], 14)
    }

    private func column(_ title: String, _ dot: Color, _ sessions: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(title).font(.system(size: 8.5, weight: .bold)).kerning(0.9)
                Spacer(minLength: 4)
                Text("\(sessions.count)").font(.system(size: 8.5, weight: .bold)).opacity(0.55)
            }
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 4)
            .padding(.bottom, 9)

            // Each column scrolls on its own, so a hundred sessions look the
            // same as twelve — the bubble never grows to accommodate them.
            ScrollView(.vertical) {
                VStack(spacing: 7) {
                    ForEach(sessions) { SessionTile(session: $0, onTap: onTap) }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.03),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
