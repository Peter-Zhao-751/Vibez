//
//  ShieldReplicaView.swift
//  Vibez
//
//  DEBUG-only stand-in for the real Screen Time shield, which never fires
//  in the simulator (ManagedSettingsStore shields are device-only). Exists
//  so marketing/App Store screenshots of the shield experience can be
//  captured with simctl like any other screen: a generic blurred feed
//  under the same dark material + agent tint, and the same
//  icon/title/subtitle/Close slot layout VibezShield ships. Colors mirror
//  VibezShield/ShieldCard.swift (separate targets can't share source).
//
//  Launch with:
//    -vibez.debug.shieldReplica YES
//    [-vibez.debug.shieldReplicaAgent cx]            // Codex identity
//    [-vibez.debug.shieldReplicaDark NO]             // light appearance
//    [-vibez.debug.shieldReplicaTitle "..."]
//    [-vibez.debug.shieldReplicaBody "..."]
//

#if DEBUG
import SwiftUI

struct ShieldReplicaView: View {
    private let isCodex: Bool
    private let isDark: Bool
    private let titleText: String
    private let subtitleText: String

    init() {
        let defaults = UserDefaults.standard
        isCodex = defaults.string(forKey: "vibez.debug.shieldReplicaAgent") == "cx"
        isDark = defaults.object(forKey: "vibez.debug.shieldReplicaDark") == nil
            ? true
            : defaults.bool(forKey: "vibez.debug.shieldReplicaDark")
        titleText = defaults.string(forKey: "vibez.debug.shieldReplicaTitle")
            ?? "Needs you — Ship the onboarding revamp"
        subtitleText = defaults.string(forKey: "vibez.debug.shieldReplicaBody")
            ?? "Tests pass. Should I merge to main or stage it behind a flag first?"
    }

    /// Same per-agent accent as ShieldState.accentUIColor.
    private var accent: Color {
        isCodex
            ? Color(red: 0.29, green: 0.48, blue: 1.00)
            : Color(red: 0.851, green: 0.467, blue: 0.341)
    }

    /// Same 25% accent / 75% base mix as ShieldState.backgroundUIColor,
    /// with the same dark/light base values.
    private var wash: Color {
        let mix = 0.25
        let (ar, ag, ab) = isCodex ? (0.29, 0.48, 1.00) : (0.851, 0.467, 0.341)
        let (dr, dg, db) = isDark ? (0.047, 0.051, 0.071) : (0.984, 0.973, 0.957)
        return Color(
            red: dr * (1 - mix) + ar * mix,
            green: dg * (1 - mix) + ag * mix,
            blue: db * (1 - mix) + ab * mix
        )
    }

    /// fg / fgMute equivalents from ShieldState.
    private var fg: Color { isDark ? .white : .black }
    private var fgMute: Color {
        isDark ? .white.opacity(0.65) : .black.opacity(0.55)
    }

    private var icon: UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return nil }
        let name = isCodex ? "shield-codex-v2.png" : "shield-claude-v2.png"
        return UIImage(contentsOfFile: container.appendingPathComponent(name).path)
    }

    var body: some View {
        ZStack {
            FakeFeed()
                .compositingGroup()
                .blur(radius: 34)
                .scaleEffect(1.12)
                .ignoresSafeArea()
            wash.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 150, height: 150)
                        .padding(.bottom, 18)
                }
                Text(titleText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(fg)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 10)
                Text(subtitleText)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(fgMute)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
                Spacer()
                Button {} label: {
                    Text("Close")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(isDark ? .dark : .light)
    }
}

/// Generic social-feed lookalike (deliberately NOT any real app's trade
/// dress) — only ever seen through 26pt of blur, so shapes and color
/// energy are all that matter.
private struct FakeFeed: View {
    private let storyColors: [[Color]] = [
        [.pink, .orange], [.purple, .blue], [.teal, .green],
        [.red, .yellow], [.indigo, .cyan],
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(.gray.opacity(0.35)).frame(width: 34, height: 34)
                RoundedRectangle(cornerRadius: 4).fill(.gray.opacity(0.3))
                    .frame(width: 110, height: 12)
                Spacer()
                Circle().fill(.gray.opacity(0.25)).frame(width: 28, height: 28)
            }
            HStack(spacing: 14) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(LinearGradient(
                            colors: storyColors[i],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 62, height: 62)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Color(red: 0.91, green: 0.66, blue: 0.49),
                             Color(red: 0.85, green: 0.42, blue: 0.55),
                             Color(red: 0.55, green: 0.37, blue: 0.69)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 320)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(.gray.opacity(0.3)).frame(width: 64, height: 16)
                }
                Spacer()
            }
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Color(red: 0.49, green: 0.77, blue: 0.91),
                             Color(red: 0.37, green: 0.55, blue: 0.85),
                             Color(red: 0.23, green: 0.37, blue: 0.66)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 320)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color.white)
    }
}
#endif
