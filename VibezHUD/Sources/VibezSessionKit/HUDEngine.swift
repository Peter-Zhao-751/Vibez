import Foundation

/// Reader + store wired together. The single entry point used by both the app
/// and the probe, so the two can never drift.
public final class HUDEngine {
    private let reader: EventLogReader
    private let store: SessionStore
    private let clock: any Clock
    private let remote: RemoteSessionSource?
    private let config: StoreConfig

    public init(logURL: URL = HUDPaths.defaultLogURL,
                config: StoreConfig = StoreConfig(),
                clock: any Clock = SystemClock(),
                liveness: any LivenessProbe = POSIXLivenessProbe(),
                remote: RemoteSessionSource? = nil) {
        self.reader = EventLogReader(url: logURL)
        self.store = SessionStore(config: config, clock: clock, liveness: liveness)
        self.clock = clock
        self.remote = remote
        self.config = config
    }

    /// Begin the remote polling loop (no-op when the feature is off).
    public func startRemote() { remote?.start() }

    /// Cold start: bounded tail replay, then a snapshot.
    @discardableResult
    public func primeAndDrain(tailBytes: Int = HUDPaths.coldStartTailBytes) -> HUDSnapshot {
        for e in reader.primeFromTail(maxBytes: tailBytes) { store.apply(e) }
        for e in reader.readNew() { store.apply(e) }
        return snapshotWithRemote()
    }

    /// Drain whatever is new and re-snapshot. Safe to call on a timer.
    public func poll() -> HUDSnapshot {
        for e in reader.readNew() { store.apply(e) }
        return snapshotWithRemote()
    }

    /// Probe seam: merge CANNED remote docs (fixture-injected) instead of
    /// live-polled ones — the probe never touches the network.
    public func snapshotMerging(remoteDocs: [RemoteEventDoc], now: Int64) -> HUDSnapshot {
        store.snapshot(remote: RemoteReducer.sessions(docs: remoteDocs, now: now, config: config))
    }

    private func snapshotWithRemote() -> HUDSnapshot {
        store.snapshot(remote: remote?.currentSessions(now: clock.nowMs) ?? [])
    }
}
