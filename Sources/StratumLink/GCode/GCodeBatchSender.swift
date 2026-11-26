//
//  GCodeBatchSender.swift
//  StratumLink
//
//  Sends a small group of lines all at once, then waits until every one of
//  them has been acknowledged before accepting the next group.
//
//  This is for things that must stay together, like a jog:
//
//      G91
//      G1 X0.5 F750
//      G90
//
//  Unlike `GCodeJobRunner` (one line in flight at a time), the whole batch is
//  on the wire together, so the trailing `G90` is already queued on the
//  machine when the move runs, even if the move itself is rejected. Waiting
//  for the acknowledgements before the next batch is the flow control: the
//  machine's input buffer is small and must not be flooded.
//

import Foundation

@MainActor
public final class GCodeBatchSender {

    public enum Outcome: Equatable {
        /// Every line was acknowledged.
        case completed
        /// The machine answered with an error or alarm.
        case failed(String)
        /// Not every acknowledgement arrived in time; the sender freed itself
        /// so a lost reply can't block it for good.
        case timedOut
    }

    public init() {}

    /// True from `send` until the last acknowledgement (or a failure, timeout
    /// or `reset`). While true, `send` refuses a new batch.
    public private(set) var isBusy = false

    /// Called when the batch in flight ends, whatever the reason.
    public var onFinish: ((Outcome) -> Void)?

    /// How long to wait for the acknowledgements before giving up.
    public var timeout: TimeInterval = 2

    private var send: ((String) -> Void)?
    private var remainingAcks = 0
    private var timeoutTask: Task<Void, Never>?

    public func configure(send: @escaping (String) -> Void) {
        self.send = send
    }

    /// Sends all `lines` now. Returns false, sending nothing, while the
    /// previous batch is still waiting for its acknowledgements.
    @discardableResult
    public func send(_ lines: [String]) -> Bool {
        let lines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !isBusy, !lines.isEmpty, let send else {
            return false
        }
        isBusy = true
        remainingAcks = lines.count
        startTimeout()
        lines.forEach(send)
        return true
    }

    /// Forgets the batch in flight without reporting it (connection closed,
    /// soft reset): its replies will never come, or no longer matter.
    public func reset() {
        finish(nil)
    }

    /// Feed every non-status line the machine sends back through here (see
    /// `MachineConnection.onLine`).
    public func handleMachineLine(_ line: String) {
        guard isBusy else {
            return
        }
        let response = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if response.hasPrefix("error") || response.hasPrefix("alarm") {
            finish(.failed(line))
            return
        }
        guard response == "ok" || response.hasPrefix("ok ") else {
            return
        }
        remainingAcks -= 1
        if remainingAcks <= 0 {
            finish(.completed)
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let seconds = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.finish(.timedOut)
        }
    }

    private func finish(_ outcome: Outcome?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard isBusy else {
            return
        }
        isBusy = false
        remainingAcks = 0
        if let outcome {
            onFinish?(outcome)
        }
    }
}
