import SwiftUI

/// Two Liquid Glass ears flanking the notch. Each hides entirely at zero, so a
/// quiet machine shows a bare notch.
struct CollapsedEars: View {
    let needsYou: Int
    let working: Int
    let notchWidth: CGFloat
    var namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            ear(visible: needsYou > 0, id: "ear-left") {
                Circle().fill(HUDTheme.needsYou).frame(width: 7, height: 7)
                    .modifier(PulseModifier())
                Text("\(needsYou)").font(.system(size: 10, weight: .bold))
            }
            Spacer().frame(width: notchWidth + 8)
            ear(visible: working > 0, id: "ear-right") {
                Equalizer().frame(width: 10, height: 10)
                Text("\(working)").font(.system(size: 10, weight: .bold)).opacity(0.5)
            }
        }
        .foregroundStyle(.white)
    }

    private func ear<C: View>(visible: Bool, id: String, @ViewBuilder content: () -> C) -> some View {
        // MEASURED: `.opacity(0)` applied AFTER `.glassEffect` is ignored — glass
        // content is composited by the render server, so an outer opacity never
        // reaches it, and a zero-count ear stayed fully drawn. (`glassEffectID` is
        // innocent; removing it alone changed nothing.) So the ear is genuinely not
        // built when empty, and a `.hidden()` twin holds the slot open — that width
        // is what keeps the surviving ear clear of the notch.
        let slot = HStack(spacing: 5) { content() }
            .padding(.horizontal, 8)
            .frame(height: 18)

        return ZStack {
            slot.hidden()
            if visible {
                slot
                    .glassEffect(.regular, in: .rect(cornerRadius: HUDTheme.earCornerRadius))
                    .glassEffectID(id, in: namespace)
                    .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(HUDTheme.expand, value: visible)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.45 : 1)
            .scaleEffect(on ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct Equalizer: View {
    @State private var phase = false
    private let heights: [CGFloat] = [4, 10, 7]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(HUDTheme.working)
                    .frame(width: 2, height: heights[i])
                    .scaleEffect(y: phase ? 1 : 0.4, anchor: .bottom)
                    .animation(.easeInOut(duration: 0.52)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
