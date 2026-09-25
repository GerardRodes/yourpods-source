import XCTest
import SwiftData
@testable import YourPods

/// Regression tests for PlayerManager.markQueuedEpisodeAsPlayed(_:) → durable completion outbox.
///
/// Root cause guarded: `markQueuedEpisodeAsPlayed` delegates to
/// `PodcastManager.markEpisodeAsPlayed(podcastUrl:episodeGuid:)`, which (since B4)
/// enqueues a `PendingCompletion` in the durable outbox when a sync client is present.
/// This file locks down that delegation so a future refactor cannot silently break it.
@MainActor
final class MarkQueuedEpisodeAsPlayedTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQueueItem(
        guid: String,
        podcastUrl: String = "https://example.com/feed.xml"
    ) -> QueueItem {
        QueueItem(
            id: guid,
            title: "Episode \(guid)",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(guid).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - B5 Regression: mark-played propagates to the durable outbox

    /// GIVEN a PlayerManager wired to a PodcastManager that has a sync client,
    /// WHEN markQueuedEpisodeAsPlayed is called for a queued episode,
    /// THEN the episode guid appears in pendingCompletionGuids() — proving the durable
    /// outbox path fired and will survive App Check 403 / network failure.
    func test_markQueuedEpisodeAsPlayed_enqueuesCompletionInOutbox() {
        // GIVEN
        let podcastManager = PodcastManager(modelContext: context)
        // Set a sync client so the `syncClient != nil` gate in markEpisodeAsPlayed opens.
        let stubClient = MarkQueuedEpisodeStubSyncClient()
        podcastManager.setSyncClient(stubClient, deviceId: "test-device-b5")

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        let guid = "ep-b5-regression"
        let item = makeQueueItem(guid: guid)
        audioManager.appendToQueue([item])

        XCTAssertFalse(podcastManager.pendingCompletionGuids().contains(guid),
                       "Precondition: guid must NOT be in outbox before marking played")

        // WHEN
        playerManager.markQueuedEpisodeAsPlayed(item)

        // THEN
        let guids = podcastManager.pendingCompletionGuids()
        XCTAssertTrue(guids.contains(guid),
                      "markQueuedEpisodeAsPlayed must enqueue a durable completion for the episode guid")
    }

    /// GIVEN a PlayerManager with NO sync client (Vault mode),
    /// WHEN markQueuedEpisodeAsPlayed is called,
    /// THEN the episode guid does NOT appear in pendingCompletionGuids() — no outbox entry for Vault.
    func test_markQueuedEpisodeAsPlayed_vaultMode_doesNotEnqueueCompletion() {
        // GIVEN: no sync client set
        let podcastManager = PodcastManager(modelContext: context)
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager

        let guid = "ep-vault-no-outbox"
        let item = makeQueueItem(guid: guid)
        audioManager.appendToQueue([item])

        // WHEN
        playerManager.markQueuedEpisodeAsPlayed(item)

        // THEN: outbox must be empty — Vault users have no Pro server to push to
        let guids = podcastManager.pendingCompletionGuids()
        XCTAssertFalse(guids.contains(guid),
                       "Vault mode must not enqueue a completion (no Pro server)")
    }

    /// GIVEN a PlayerManager with nil podcastManager,
    /// WHEN markQueuedEpisodeAsPlayed is called,
    /// THEN it is a safe no-op (no crash).
    func test_markQueuedEpisodeAsPlayed_nilPodcastManager_isNoOp() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        // podcastManager left nil

        let item = makeQueueItem(guid: "ep-nil-manager")
        audioManager.appendToQueue([item])

        // Must not crash
        playerManager.markQueuedEpisodeAsPlayed(item)
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "Item must be removed from queue even when podcastManager is nil")
    }

    /// Scenario: user marks the PLAYING episode as played with a next episode queued.
    /// The advance path must still enqueue a durable completion (via
    /// handleEpisodeCompleted → syncCompletedEpisodeToProServer), even though
    /// markEpisodeAsPlayed is no longer called on this branch.
    func test_markCurrentEpisodeAsPlayed_withQueue_enqueuesCompletionViaPipeline() async {
        // GIVEN: Pro-style sync clients on BOTH managers (the pipeline's outbox
        // enqueue is gated on PlayerManager.syncClient, the enqueue itself goes
        // through PodcastManager.enqueueCompletion)
        let podcastManager = PodcastManager(modelContext: context)
        let stubClient = MarkQueuedEpisodeStubSyncClient()
        podcastManager.setSyncClient(stubClient, deviceId: "test-device-advance")

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
        playerManager.setSyncClient(stubClient, deviceId: "test-device-advance")

        let playing = makeQueueItem(guid: "ep-advance-playing")
        let next = makeQueueItem(guid: "ep-advance-next")
        audioManager.currentItem = playing
        audioManager.appendToQueue([next])
        audioManager.isPlaying = true

        // WHEN
        playerManager.markCurrentEpisodeAsPlayed()

        // THEN: queue advanced AND the played episode's completion is durably enqueued
        let advanced = await pollUntil { audioManager.currentItem?.id == "ep-advance-next" }
        XCTAssertTrue(advanced, "Precondition: the advance must occur")
        XCTAssertTrue(podcastManager.pendingCompletionGuids().contains("ep-advance-playing"),
                      "Advance path must enqueue a durable completion for the played episode")
        XCTAssertFalse(podcastManager.pendingCompletionGuids().contains("ep-advance-next"),
                       "The NEXT episode must not be marked completed")
    }
}

// MARK: - Stub sync client (minimal conformance — all defaults used where possible)

private actor MarkQueuedEpisodeStubSyncClient: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: [], droppedItems: [])
    }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

/// Poll until `condition` is true or `timeout` elapses, yielding to the main actor
/// between checks. No real-time sleeps — the advance Task runs on the main actor,
/// and playEpisode sets currentItem in its synchronous prefix, so a few yields
/// are enough on the happy path.
@MainActor
fileprivate func pollUntil(
    timeout: TimeInterval = 2.0,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        await Task.yield()
    }
    return condition()
}
