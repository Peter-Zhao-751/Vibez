// VibezHUD/Tests/VibezSessionKitTests/RemoteSessionSourceTests.swift
import Foundation
import Testing
@testable import VibezSessionKit

private final class FakeFetcher: RemoteEventsFetching, @unchecked Sendable {
    var docs: [RemoteEventDoc] = []
    var registered = 0
    var fetches = 0
    var shouldThrow = false
    func registerIfNeeded() async throws { registered += 1 }
    func fetchRecentEvents() async throws -> [RemoteEventDoc] {
        fetches += 1
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        return docs
    }
}

@Test func pollOnceRegistersThenFetchesAndExposesSessions() async {
    let f = FakeFetcher()
    f.docs = [RemoteEventDoc(session: "r1", agent: "cx", event: "needs-input", shield: "on",
                             title: "Deploy?", body: nil, machine: "mini", createdAtMs: 1_000)]
    let src = RemoteSessionSource(fetcher: f)
    await src.pollOnce()
    #expect(f.registered == 1 && f.fetches == 1)
    let rows = src.currentSessions(now: 2_000)
    #expect(rows.map(\.sid) == ["r1"])
    #expect(rows.first?.machine == "mini")
}

@Test func fetchFailureKeepsThePreviousDocs() async {
    let f = FakeFetcher()
    f.docs = [RemoteEventDoc(session: "r1", agent: "cc", event: "done", shield: nil,
                             title: "T", body: nil, machine: nil, createdAtMs: 1_000)]
    let src = RemoteSessionSource(fetcher: f)
    await src.pollOnce()
    #expect(src.currentSessions(now: 2_000).count == 1)
    f.shouldThrow = true
    await src.pollOnce()
    // Stale-but-present beats empty; the reducer's time rules age it out.
    #expect(src.currentSessions(now: 2_000).count == 1)
}

@Test func registrationFailureStillAllowsFetching() async {
    final class RegFails: RemoteEventsFetching, @unchecked Sendable {
        var fetches = 0
        func registerIfNeeded() async throws { throw URLError(.timedOut) }
        func fetchRecentEvents() async throws -> [RemoteEventDoc] { fetches += 1; return [] }
    }
    let f = RegFails()
    let src = RemoteSessionSource(fetcher: f)
    await src.pollOnce()
    await src.pollOnce()
    #expect(f.fetches == 2)   // fetch proceeds; registration retries silently
}

@Test func makeDefaultHonorsTheKillSwitchAndMissingId() {
    // Pure decision logic, factored so it's testable without env mutation.
    #expect(RemoteSessionSource.shouldEnable(vibezId: "moss-pine-fox-jazz", killSwitch: "1") == false)
    #expect(RemoteSessionSource.shouldEnable(vibezId: nil, killSwitch: nil) == false)
    #expect(RemoteSessionSource.shouldEnable(vibezId: "not a valid id", killSwitch: nil) == false)
    #expect(RemoteSessionSource.shouldEnable(vibezId: "moss-pine-fox-jazz", killSwitch: nil) == true)
}
