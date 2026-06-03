//
//  ClaudeBodyShape.swift
//  Vibez
//
//  The Claude mascot's body silhouette (body + side wings + four feet),
//  shared by the animated home-screen mascot (Mascots.swift) and the
//  static shield card (ShieldCardRenderer.swift). The eye poses differ
//  between the two and stay in their own files.
//

import SwiftUI

struct ClaudeBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 100
        var p = Path()
        // Body
        p.addRect(CGRect(x: 8 * s, y: 8 * s, width: 84 * s, height: 56 * s))
        // Side wings
        p.addRect(CGRect(x: -4 * s, y: 36 * s, width: 12 * s, height: 15 * s))
        p.addRect(CGRect(x: 92 * s, y: 36 * s, width: 12 * s, height: 15 * s))
        // Four feet
        for x in [18.0, 32.0, 60.0, 74.0] {
            p.addRect(CGRect(x: x * s, y: 64 * s, width: 10 * s, height: 18 * s))
        }
        return p
    }
}
