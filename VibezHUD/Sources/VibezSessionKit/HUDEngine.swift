import Foundation

/// Reader + store wired together. The single entry point used by both the app
/// and the probe, so the two can never drift.
public final class HUDEngine {
    private let reader: EventLogReader
    private let store: SessionStore

    public init(logURL: URL = HUDPaths.defaultLogURL,
                config: StoreConfig = StoreConfig(),
                clock: any Clock = SystemClock(),
                liveness: any LivenessProbe = POSIXLivenessProbe()) {
        self.reader = EventLogReader(url: logURL)
        self.store = SessionStore(config: config, clock: clock, liveness: liveness)
    }

    /// Cold start: bounded tail replay, then a snapshot.
    @discardableResult
    public func primeAndDrain(tailBytes: Int = HUDPaths.coldStartTailBytes) -> HUDSnapshot {
        for e in reader.primeFromTail(maxBytes: tailBytes) { store.apply(e) }
        for e in reader.readNew() { store.apply(e) }
        return store.snapshot()
    }

    /// Drain whatever is new and re-snapshot. Safe to call on a timer.
    public func poll() -> HUDSnapshot {
        for e in reader.readNew() { store.apply(e) }
        return store.snapshot()
    }
}
