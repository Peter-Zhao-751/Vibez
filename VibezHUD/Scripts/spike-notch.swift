// VibezHUD/Scripts/spike-notch.swift
// Run: swift VibezHUD/Scripts/spike-notch.swift
// Exits by itself with status 0 (PASS) or 1 (FAIL).
import AppKit
import CoreGraphics

func say(_ s: String) { print(s); fflush(stdout) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first else { fatalError("no screen") }
let f = screen.frame
let inset = screen.safeAreaInsets.top
let auxL = screen.auxiliaryTopLeftArea?.width ?? 0
let auxR = screen.auxiliaryTopRightArea?.width ?? 0
let notchW = (inset > 0 && auxL > 0 && auxR > 0) ? f.width - auxL - auxR : 180
let notchH = inset > 0 ? inset : 24

say("screen=\(f)")
say("safeTop=\(inset) auxL=\(auxL) auxR=\(auxR)")
say("notch=\(notchW)x\(notchH)")

// The level under test. If this fails, walk the ladder in Step 2.
let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

// Deliberately WIDER than the notch, so it must clear the menu bar on both sides.
let w: CGFloat = notchW + 260, h: CGFloat = notchH + 40
let rect = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)

let panel = NSPanel(contentRect: rect,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = level
panel.isOpaque = false
panel.hasShadow = false
panel.backgroundColor = .clear
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
v.wantsLayer = true
v.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.85).cgColor
v.layer?.cornerRadius = 18
v.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
panel.contentView = v
panel.orderFrontRegardless()

// Let WindowServer place the window before interrogating it.
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    let mine = panel.windowNumber
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []

    guard let myIdx = list.firstIndex(where: {
        ($0[kCGWindowNumber as String] as? Int) == mine
    }) else {
        say("FAIL: our window is not in the on-screen list at all")
        exit(1)
    }
    let myLayer = list[myIdx][kCGWindowLayer as String] as? Int ?? -999
    say("panel: layer=\(myLayer) frontIndex=\(myIdx) windowNumber=\(mine)")

    // Menu-bar furniture: anything owned by Window Server or Control Center
    // that sits flush against the top of the screen.
    var barLayer = Int.min, barIdx = Int.max, barOwners = Set<String>()
    for (i, wi) in list.enumerated() {
        let owner = wi[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "Window Server" || owner == "Control Center" else { continue }
        let b = wi[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard (b["Y"] as? Double ?? -1) == 0 else { continue }
        barLayer = max(barLayer, wi[kCGWindowLayer as String] as? Int ?? Int.min)
        barIdx = min(barIdx, i)
        barOwners.insert(owner)
    }
    guard barLayer != Int.min else {
        say("FAIL: found no menu-bar windows to compare against")
        exit(1)
    }
    say("menubar: maxLayer=\(barLayer) frontIndex=\(barIdx) owners=\(barOwners.sorted())")

    // Front-to-back ordering: a LOWER index is closer to the viewer.
    let above = myLayer > barLayer && myIdx < barIdx
    say(above
        ? "PASS: panel layer \(myLayer) sits above menu bar layer \(barLayer)"
        : "FAIL: panel layer \(myLayer) does NOT clear menu bar layer \(barLayer)")
    exit(above ? 0 : 1)
}

app.run()
