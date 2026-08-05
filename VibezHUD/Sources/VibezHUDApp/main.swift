// Placeholder entry point.
//
// VibezHUDApp is an executable target, so it needs a linkable `main` the moment
// it has any source files. Tasks 15-16 add pure, AppKit-free logic (NotchGeometry,
// HoverPolicy) here well before there's an app shell to run — Task 17 replaces this
// file with the real AppKit entry point (NSApplication + NotchWindowController).
// Until then this only exists so `swift build`/`swift test` link cleanly for the
// whole package from a stone-cold `.build` directory, not just incrementally.
print("VibezHUDApp: no UI yet — the app shell lands in Task 17.")
