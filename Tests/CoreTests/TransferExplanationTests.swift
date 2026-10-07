import Foundation
import Testing
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices

private func item(_ status: TransferStatus, upload: Bool = false, position: UInt32 = 0, token: UInt32? = nil, retries: Int = 0,
                  error: String? = nil) -> Transfer {
    var transfer = Transfer(user: "peer", file: SharedFile(path: "Music\\Album\\01.flac", size: 1000), upload: upload)
    transfer.status = status; transfer.queuePosition = position; transfer.token = token; transfer.retries = retries; transfer.error = error
    return transfer
}

private let online = TransferQueueContext(upload: false, connected: true, suspended: false, slots: 3, inUse: 1)

@Suite struct TransferExplanationTests {
    @Test func pausedDirectionWinsOverEveryWaitingReason() {
        let paused = TransferQueueContext(upload: false, connected: true, suspended: true, slots: 3, inUse: 0)
        #expect(TransferExplanation.reason(for: item(.queued), in: paused) == .directionPaused)
        #expect(TransferExplanation.reason(for: item(.negotiating, position: 4), in: paused) == .directionPaused)
        #expect(TransferExplanation.detail(.directionPaused, upload: false).contains("Resume Downloads"))
        #expect(TransferExplanation.detail(.directionPaused, upload: true).contains("Resume Uploads"))
    }

    @Test func offlineQueuedWorkWaitsForConnection() {
        let offline = TransferQueueContext(upload: false, connected: false, suspended: false, slots: 3, inUse: 0)
        #expect(TransferExplanation.reason(for: item(.queued), in: offline) == .offline)
        #expect(TransferExplanation.label(.offline) == "Waiting to connect")
    }

    @Test func localSlotAndRemoteQueueAreDistinguished() {
        let full = TransferQueueContext(upload: false, connected: true, suspended: false, slots: 2, inUse: 2)
        #expect(TransferExplanation.reason(for: item(.queued), in: full) == .waitingForLocalSlot(inUse: 2, slots: 2))
        #expect(TransferExplanation.reason(for: item(.queued), in: online) == .connecting(user: "peer"))
        #expect(TransferExplanation.reason(for: item(.negotiating, position: 12), in: online) == .remoteQueue(user: "peer", position: 12))
        #expect(TransferExplanation.reason(for: item(.negotiating, position: 12, token: 7), in: online) == .connecting(user: "peer"))
        #expect(TransferExplanation.label(.remoteQueue(user: "peer", position: 12)) == "In their queue · #12")
        #expect(TransferExplanation.detail(.waitingForLocalSlot(inUse: 2, slots: 2), upload: false).contains("download slots"))
        #expect(TransferExplanation.detail(.remoteQueue(user: "peer", position: 12), upload: false).contains("place 12"))
    }

    @Test func retryFeedbackRequiresAConfirmedPendingRetry() {
        #expect(TransferExplanation.reason(for: item(.failed, retries: 1, error: "timeout"), in: online) == .failed("timeout"))
        #expect(TransferExplanation.reason(for: item(.failed, retries: 2, error: "timeout"), in: online) == .failed("timeout"))
        var live = item(.failed, retries: 2, error: "timeout")
        live.runtimeState = TransferRuntimeState(holdsLocalSlot: false, localSlotsInUse: 0, localSlots: 3, connected: true, directionSuspended: false,
                                                 queueWait: nil, peerBlockedUntil: nil,
                                                 pendingRetry: TransferRetrySchedule(identity: UUID(), deadline: Date(timeIntervalSince1970: 9_000)))
        #expect(TransferExplanation.reason(for: live, in: online) == .retrying(attempt: 2, limit: 3))
        #expect(TransferExplanation.allowsManualRetry(item(.failed, retries: 1, error: "size mismatch")))
        #expect(!TransferExplanation.allowsManualRetry(item(.failed, upload: true, error: "x")))
        #expect(!TransferExplanation.allowsManualRetry(item(.completed)))
        #expect(TransferExplanation.reason(for: item(.failed, retries: 3, error: "timeout"), in: online) == .failed("timeout"))
        #expect(TransferExplanation.reason(for: item(.failed, retries: 0, error: "File not shared."), in: online) == .failed("File not shared."))
        #expect(TransferExplanation.reason(for: item(.failed, upload: true, retries: 1, error: "x"), in: online) == .failed("x"))
        let paused = TransferQueueContext(upload: false, connected: true, suspended: true, slots: 3, inUse: 0)
        #expect(TransferExplanation.reason(for: item(.failed, retries: 1, error: "x"), in: paused) == .failed("x"))
        #expect(TransferExplanation.label(.retrying(attempt: 1, limit: 3)) == "Retrying soon · 1 of 3")
    }

    @Test func missingFinishedFileIsAProblemNotACompletion() {
        #expect(TransferExplanation.reason(for: item(.completed), in: online, fileMissing: true) == .fileMissing)
        #expect(TransferExplanation.reason(for: item(.completed), in: online) == .completed)
        #expect(TransferReason.fileMissing.isProblem)
        #expect(TransferExplanation.label(.fileMissing) == "File missing")
    }

    @Test func contextCountsOnlyTransfersHoldingALocalSlot() {
        let transfers = [item(.transferring), item(.negotiating, token: 3), item(.negotiating, position: 2), item(.queued),
                         item(.transferring, upload: true)]
        let context = TransferQueueContext.make(transfers, upload: false, connected: true, suspended: false, slots: 3)
        #expect(context.inUse == 2)
        #expect(TransferQueueContext.make(transfers, upload: true, connected: true, suspended: false, slots: 3).inUse == 1)
    }

    @Test func bannerExplainsPauseOfflineAndQueues() {
        let transfers = [item(.queued), item(.queued), item(.negotiating, position: 5), item(.paused), item(.completed)]
        let paused = TransferQueueContext.make(transfers, upload: false, connected: true, suspended: true, slots: 1)
        #expect(TransferQueueBanner.make(transfers, context: paused) == .paused(waiting: 3))
        let offline = TransferQueueContext.make(transfers, upload: false, connected: false, suspended: false, slots: 1)
        #expect(TransferQueueBanner.make(transfers, context: offline) == .offline(waiting: 3))
        let busy = TransferQueueContext(upload: false, connected: true, suspended: false, slots: 1, inUse: 1)
        #expect(TransferQueueBanner.make(transfers, context: busy) == .queued(remote: 1, local: 2))
        let idle = TransferQueueContext(upload: false, connected: true, suspended: false, slots: 3, inUse: 0)
        #expect(TransferQueueBanner.make([item(.completed), item(.paused)], context: idle) == nil)
        let suspendedEmpty = TransferQueueContext(upload: true, connected: true, suspended: true, slots: 3, inUse: 0)
        #expect(TransferQueueBanner.make([], context: suspendedEmpty) == .paused(waiting: 0))
    }

    @Test func everyReasonHasALabelAndAnActionableDetail() {
        let reasons: [TransferReason] = [.transferring, .connecting(user: "p"), .directionPaused, .paused, .offline,
                                         .waitingForLocalSlot(inUse: 1, slots: 1), .remoteQueue(user: "p", position: 1),
                                         .waitingForPeer(user: "p"), .retrying(attempt: 1, limit: 3), .failed("boom"),
                                         .completed, .fileMissing, .cancelled, .peerDeferred(user: "p", until: nil),
                                         .peerDeferred(user: "p", until: Date(timeIntervalSince1970: 0)), .waitingToStart(user: "p"),
                                         .storageRecovery, .stopping, .remoteQueue(user: "p", position: 0)]
        for reason in reasons {
            #expect(!TransferExplanation.label(reason).isEmpty)
            #expect(!TransferExplanation.detail(reason, upload: false).isEmpty)
            #expect(!TransferExplanation.label(reason).contains("\u{2014}"))
            #expect(!TransferExplanation.detail(reason, upload: true).contains("\u{2014}"))
        }
    }
}
