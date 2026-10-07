import Foundation
import TransferEngine

/// Why a transfer is where it is, in words a person can act on rather than protocol states.
public enum TransferReason: Equatable, Sendable {
    case transferring
    case connecting(user: String)
    /// Pause Downloads or Pause Uploads is on for this direction.
    case directionPaused
    /// This transfer was paused on its own.
    case paused
    case offline
    /// Waiting for one of this Mac's own slots.
    case waitingForLocalSlot(inUse: Int, slots: Int)
    /// The other person has queued the request. Position 0 means no place has been reported yet.
    case remoteQueue(user: String, position: UInt32)
    /// The request was sent and the other person hasn't answered yet.
    case waitingForPeer(user: String)
    /// The other person's client answered an upload offer with "Queued". Arpeggio offers it again after a pause.
    case peerDeferred(user: String, until: Date?)
    /// Queued with a free slot. It starts on the next scheduling pass.
    case waitingToStart(user: String)
    /// A failed download with a live automatic retry registered by the scheduler.
    case retrying(attempt: Int, limit: Int)
    case failed(String)
    /// Transfers wait until Arpeggio can save transfer records safely.
    case storageRecovery
    /// Finishing the current write before it stops.
    case stopping
    case completed
    /// Finished, but the downloaded file is no longer where Arpeggio put it.
    case fileMissing
    case cancelled

    public var isProblem: Bool {
        switch self {
        case .failed, .fileMissing, .storageRecovery: true
        default: false
        }
    }
}

/// Direction-wide state the explanation depends on.
public struct TransferQueueContext: Sendable, Equatable {
    public var upload: Bool
    public var connected: Bool
    public var suspended: Bool
    public var slots: Int
    /// Slots in use the way the scheduler counts them.
    public var inUse: Int

    public init(upload: Bool, connected: Bool, suspended: Bool, slots: Int, inUse: Int) {
        self.upload = upload; self.connected = connected; self.suspended = suspended; self.slots = max(1, slots); self.inUse = max(0, inUse)
    }

    /// Uses the scheduler's own published counts when rows carry them. Otherwise counts as the scheduler does:
    /// negotiating or transferring rows hold a slot, except downloads waiting in the other person's queue, and
    /// previews never count.
    public static func make(_ transfers: [Transfer], upload: Bool, connected: Bool, suspended: Bool, slots: Int) -> Self {
        let rows = transfers.filter { $0.upload == upload && !$0.isPreview }
        if let state = rows.lazy.compactMap(\.runtimeState).first {
            return Self(upload: upload, connected: connected, suspended: suspended, slots: state.localSlots, inUse: state.localSlotsInUse)
        }
        return Self(upload: upload, connected: connected, suspended: suspended, slots: slots, inUse: rows.filter(holdsSlot).count)
    }

    static func holdsSlot(_ transfer: Transfer) -> Bool {
        switch transfer.status {
        case .transferring: true
        case .negotiating: !looksRemotelyQueued(transfer)
        default: false
        }
    }

    /// Without published scheduler state, a tokenless download request with a reported place in line is taken to be
    /// waiting in the other person's queue.
    static func looksRemotelyQueued(_ transfer: Transfer) -> Bool {
        !transfer.upload && transfer.status == .negotiating && transfer.token == nil && transfer.queuePosition > 0
    }
}

public enum TransferExplanation {
    /// Matches the transfer engine: a failed download is retried automatically up to three times.
    public static let automaticRetryLimit = 3

    /// Published scheduler state comes first. Retries are promised only when the scheduler reports a live one,
    /// never from the row's retry counter.
    public static func reason(for transfer: Transfer, in context: TransferQueueContext, fileMissing: Bool = false) -> TransferReason {
        switch transfer.status {
        case .completed: return fileMissing ? .fileMissing : .completed
        case .cancelled: return .cancelled
        case .paused: return .paused
        case .transferring: return .transferring
        case .failed:
            if !transfer.upload, transfer.runtimeState?.pendingRetry != nil {
                return .retrying(attempt: max(1, transfer.retries), limit: automaticRetryLimit)
            }
            return .failed(transfer.error ?? "The transfer stopped.")
        case .queued, .negotiating:
            if let state = transfer.runtimeState {
                switch state.queueWait {
                case .offline?: return .offline
                case .directionPaused?: return .directionPaused
                case .localSlots?: return .waitingForLocalSlot(inUse: state.localSlotsInUse, slots: state.localSlots)
                case .remoteQueue?: return .remoteQueue(user: transfer.user, position: transfer.queuePosition)
                case .peerBackoff?: return .peerDeferred(user: transfer.user, until: state.peerBlockedUntil)
                case .accountingRecovery?: return .storageRecovery
                case .stopping?: return .stopping
                case nil:
                    // Published state with no wait is authoritative: an old queue position is not a remote queue.
                    if transfer.status == .negotiating { return transfer.upload ? .waitingForPeer(user: transfer.user) : .connecting(user: transfer.user) }
                    return transfer.upload ? .waitingToStart(user: transfer.user) : .connecting(user: transfer.user)
                }
            }
            if context.suspended { return .directionPaused }
            if !context.connected { return .offline }
            if transfer.status == .negotiating {
                if TransferQueueContext.looksRemotelyQueued(transfer) { return .remoteQueue(user: transfer.user, position: transfer.queuePosition) }
                return transfer.upload ? .waitingForPeer(user: transfer.user) : .connecting(user: transfer.user)
            }
            if context.inUse >= context.slots { return .waitingForLocalSlot(inUse: context.inUse, slots: context.slots) }
            return transfer.upload ? .waitingToStart(user: transfer.user) : .connecting(user: transfer.user)
        }
    }

    /// Resume and Retry are offered for the downloads the engine can restart.
    public static func allowsManualRetry(_ transfer: Transfer) -> Bool {
        !transfer.upload && [.paused, .failed, .cancelled].contains(transfer.status)
    }

    /// Short text for the progress column.
    public static func label(_ reason: TransferReason) -> String {
        switch reason {
        case .transferring: "Transferring"
        case .connecting: "Connecting"
        case .directionPaused: "Paused for all"
        case .paused: "Paused"
        case .offline: "Waiting to connect"
        case .waitingForLocalSlot: "Waiting for a free slot"
        case .remoteQueue(_, let position): position > 0 ? "In their queue · #\(position)" : "In their queue"
        case .waitingForPeer: "Waiting for reply"
        case .peerDeferred: "Asked to wait"
        case .waitingToStart: "Waiting to start"
        case .retrying(let attempt, let limit): "Retrying soon · \(attempt) of \(limit)"
        case .failed: "Failed"
        case .storageRecovery: "Waiting for storage"
        case .stopping: "Stopping"
        case .completed: "Completed"
        case .fileMissing: "File missing"
        case .cancelled: "Cancelled"
        }
    }

    /// One sentence for help tags and VoiceOver, saying what happens next.
    public static func detail(_ reason: TransferReason, upload: Bool) -> String {
        let direction = upload ? "Uploads" : "Downloads"
        switch reason {
        case .transferring: return upload ? "Sending now." : "Receiving now."
        case .connecting(let user): return "Asking \(user) to start the transfer."
        case .directionPaused: return "\(direction) are paused. Resume \(direction) to continue; partial data is kept."
        case .paused: return "Paused. Choose Resume to continue from the partial data."
        case .offline: return "Arpeggio is offline. This starts again when you reconnect."
        case .waitingForLocalSlot(let inUse, let slots):
            return "All \(slots) of your \(upload ? "upload" : "download") slots are busy (\(inUse) in use). It starts when one frees up."
        case .remoteQueue(let user, let position):
            return position > 0
                ? "\(user) has queued your request at place \(position). Their client starts it when one of their slots frees up."
                : "\(user) has queued your request. Their client starts it when one of their slots frees up."
        case .waitingForPeer(let user): return upload ? "Waiting for \(user) to accept the upload." : "Waiting for \(user) to answer."
        case .peerDeferred(let user, let until):
            let when = until.map { " again at \($0.formatted(date: .omitted, time: .standard))" } ?? " again shortly"
            return "\(user)’s client asked Arpeggio to wait. Arpeggio offers the upload\(when)."
        case .waitingToStart(let user):
            return upload ? "Waiting to send to \(user). It starts when an upload slot is free and \(user)’s client is ready."
                          : "It starts as soon as a download slot is free."
        case .retrying(let attempt, let limit): return "Failed. Arpeggio retries automatically (attempt \(attempt) of \(limit))."
        case .failed(let message): return message
        case .storageRecovery: return "Transfers wait until Arpeggio can save transfer records safely. Partial data is kept."
        case .stopping: return "Finishing the current write before it stops. Partial data is kept."
        case .completed: return upload ? "Sent." : "Downloaded."
        case .fileMissing: return "The downloaded file is no longer at its saved location. It may have been moved or deleted outside Arpeggio."
        case .cancelled: return "Cancelled. Files already on disk are kept."
        }
    }
}

/// What the banner above a transfer list should say, if anything.
public enum TransferQueueBanner: Equatable, Sendable {
    /// The whole direction is paused; `waiting` transfers will continue on Resume.
    case paused(waiting: Int)
    /// Offline with unfinished transfers.
    case offline(waiting: Int)
    /// Nothing is wrong, but some transfers wait: on other people (their queue, or a deferred upload) or for a local slot.
    case queued(remote: Int, local: Int)

    public static func make(_ transfers: [Transfer], context: TransferQueueContext) -> Self? {
        // Individually paused transfers stay paused through Resume and reconnection, so they are not "waiting".
        var waiting = 0, remote = 0, local = 0
        for transfer in transfers where transfer.upload == context.upload && !transfer.isPreview {
            guard transfer.status == .queued || transfer.status == .negotiating else { continue }
            waiting += 1
            if let state = transfer.runtimeState {
                switch state.queueWait {
                case .remoteQueue?, .peerBackoff?: remote += 1
                case .localSlots?: local += 1
                default: break
                }
            } else if transfer.status == .negotiating {
                if TransferQueueContext.looksRemotelyQueued(transfer) { remote += 1 }
            } else if context.inUse >= context.slots {
                local += 1
            }
        }
        if context.suspended { return .paused(waiting: waiting) }
        guard waiting > 0 else { return nil }
        if !context.connected { return .offline(waiting: waiting) }
        return remote + local > 0 ? .queued(remote: remote, local: local) : nil
    }
}
