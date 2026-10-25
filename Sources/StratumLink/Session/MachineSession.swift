//
//  MachineSession.swift
//  StratumLink
//

import Foundation
import Combine
import simd

/// Per-job settings for `MachineSession.uploadJob`. Captured when the upload
/// starts — not read when it finishes — so changing a setting while the file
/// is still transferring can't change the job that was just sent.
public struct MachineRunOptions: Equatable {

    /// XY position (mm) the job's G54 work origin is set to right before
    /// `play`. The offset is used as-is, i.e. it's taken to be the machine XY
    /// position of the work origin. If the canvas origin turns out to sit
    /// elsewhere in machine coordinates, this is the place to add that base
    /// position (and any axis sign flip).
    public var originOffset: SIMD2<Float>

    /// Probe a `G32` grid over the program's cutting area after the origin is
    /// set and before `play`.
    public var levelBeforeRun: Bool
    /// Probe points per axis (`G32` I and J).
    public var levelGridPoints: Int
    /// Extra area probed around the program's cutting bounds, in mm.
    public var levelMargin: Double

    /// Probe Z and zero the work Z coordinate at the trigger point before `play`.
    public var autoZBeforeRun: Bool

    public init(originOffset: SIMD2<Float> = .zero,
                levelBeforeRun: Bool = false,
                levelGridPoints: Int = 5,
                levelMargin: Double = 3,
                autoZBeforeRun: Bool = false) {
        self.originOffset = originOffset
        self.levelBeforeRun = levelBeforeRun
        self.levelGridPoints = levelGridPoints
        self.levelMargin = levelMargin
        self.autoZBeforeRun = autoZBeforeRun
    }
}

/// What a `MachineSession` tells its host. The host decides how to present it.
public enum MachineSessionEvent {
    /// Something the person needs to know about (alarm, tool change, …).
    case alert(MachineAlert)
    /// These alert kinds are obsolete: the cause went away by itself.
    case alertsResolved(Set<MachineAlert.Kind>)
    /// The connection to the machine was established.
    case connected
    /// The connection was closed (pending work was already cancelled).
    case disconnected
    /// A soft-reset is about to be sent. Hosts should stop anything of their
    /// own that moves the machine (e.g. a held jog).
    case motionAborting
}

/// Orchestrates everything between "I have a G-code program" and "the machine
/// is running it": upload → set origin → optional Z probe / `G32` leveling →
/// wait for idle → `play`, plus pause / suspend / resume-from-line / stop, and
/// detection of state transitions worth telling the person about.
///
/// It owns the `MachineConnection`, the `GCodeJobRunner` (line-by-line macros)
/// and the `GCodeUploader` (whole programs). It has no UI and no persistence:
/// settings come in through `MachineRunOptions`, and everything the host
/// should react to goes out through `onEvent`.
@MainActor
public final class MachineSession {

    public let connection: MachineConnection
    public let jobRunner: GCodeJobRunner
    public let uploader: GCodeUploader
    /// Firmware version and SD-card file list.
    public let info = MachineInfo()

    /// Receives alerts, connection changes, etc. See `MachineSessionEvent`.
    public var onEvent: ((MachineSessionEvent) -> Void)?

    /// SD-card path of the most recently completed upload.
    /// `resumeJob(fromLine:)` needs this: `goto <line>` repositions the file
    /// the firmware already has loaded, but doesn't itself say which file, so
    /// a resume-from-line only makes sense while this still points at what's
    /// on the SD card. Best-effort "last thing we sent it" — there's no way
    /// to ask the firmware what it currently has loaded.
    ///
    /// Persisting it is up to the host (`onLastUploadedRemotePathChange` +
    /// the initializer), so "Resume from Line" survives an app restart while
    /// a job sits suspended on the machine.
    public private(set) var lastUploadedRemotePath: String? {
        didSet { onLastUploadedRemotePathChange?(lastUploadedRemotePath) }
    }
    public var onLastUploadedRemotePathChange: ((String?) -> Void)?

    // MARK: Console / realtime commands

    /// Grbl/Smoothieware-style homing command. Confirmed against
    /// Carvera_Controller/carveracontroller/Controller.py -> home().
    nonisolated public static let homeCommand = "$H"
    /// Grbl/Smoothieware-style alarm-clear/unlock command.
    nonisolated public static let unlockCommand = "$X"
    /// Realtime status query byte.
    nonisolated public static let statusCommand = "?"
    /// Realtime feed-hold and cycle-resume bytes.
    nonisolated public static let feedHoldCommand = "!"
    nonisolated public static let resumeCommand = "~"
    /// Console (line) command that resumes a job paused by `suspend` — not
    /// to be confused with `resumeCommand`, the realtime `~` that resumes a
    /// feed-hold.
    nonisolated public static let consoleResumeCommand = "resume"
    /// Console (line) command that suspends a job at the next safe point.
    nonisolated public static let consoleSuspendCommand = "suspend"
    /// Printable stand-in for Ctrl-X (0x18). Sends the soft-reset byte.
    nonisolated public static let softResetCommand = "^X"

    // MARK: Private state

    private var cancellables = Set<AnyCancellable>()

    /// The status state before the current one, without its `:sub-state`
    /// ("Hold:0" → "Hold"). Empty while disconnected, so the first report
    /// after connecting isn't mistaken for a transition.
    private var lastBaseState = ""

    /// The most recent alarm/error text, to say *what* went wrong when the
    /// status change is what announces it.
    private var lastFault: (text: String, date: Date)?

    /// When the session itself last sent `suspend`, so the resulting Pause
    /// state isn't reported as "paused by the machine".
    private var suspendRequestedAt: Date?

    private var lastPostedAt: [MachineAlert.Kind: Date] = [:]

    /// `G32`'s H: the height the probe lifts to between points.
    private let levelProbeHeight = 2.0

    /// Options of the upload in flight (or the last one). Internal so tests
    /// can drive `uploader.onCompleted` directly.
    var pendingOptions = MachineRunOptions()

    /// The cutting area of the program being sent. `nil` when leveling is off.
    private var pendingLevelingArea: GCodeBounds?

    /// Identifies the current run so a cancelled run's waiter can't start a
    /// replacement job that happens to have the same file name.
    private var pendingPlayID = UUID()
    /// SD path of a job whose `play` is being held back until the pre-run
    /// leveling finishes. Non-nil means "a run is being prepared"; clearing
    /// it (Stop does) cancels the `play`.
    private var pendingPlayPath: String? {
        didSet { pendingPlayID = UUID() }
    }

    // MARK: Init

    public init(lastUploadedRemotePath: String? = nil) {
        self.connection = MachineConnection()
        self.jobRunner = GCodeJobRunner()
        self.uploader = GCodeUploader()
        self.lastUploadedRemotePath = lastUploadedRemotePath

        jobRunner.configure { [weak self] line in
            self?.sendRawCommand(line)
        }
        uploader.configure(
            sendLine: { [weak self] line in
                self?.sendRawCommand(line)
            },
            sendRawBytes: { [weak self] bytes, completion in
                self?.connection.sendRawBytes(bytes, completion: completion)
            },
            sendFrame: { [weak self] ptype, payload, completion in
                self?.connection.sendFileFrame(ptype: ptype, payload: payload, completion: completion)
            },
            wireProtocol: { [weak self] in
                self?.connection.wireProtocol
            }
        )
        // `upload` only writes the file — Smoothieware's own `play <path>`
        // console command is what actually starts the job running from it.
        uploader.onCompleted = { [weak self] remotePath in
            guard let self else { return }
            self.lastUploadedRemotePath = remotePath
            self.startRun(remotePath: remotePath)
        }
        info.configure { [weak self] command in
            self?.sendRawCommand(command)
        }
        jobRunner.onFinish = { [weak self] in
            self?.levelingFinished()
        }
        jobRunner.onFailure = { [weak self] in
            self?.pendingPlayPath = nil
        }
        connection.onLine = { [weak self] line in
            self?.jobRunner.handleMachineLine(line)
            self?.uploader.handleMachineLine(line)
            self?.info.handleMachineLine(line)
            self?.raiseAlert(forLine: line)
        }
        connection.$status
            .map { $0?.state.split(separator: ":").first.map { String($0) } ?? "" }
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in self?.machineStateChanged(to: state) }
            }
            .store(in: &cancellables)
        // Ask for version + files once the wire protocol is known — sending
        // earlier would use the wrong framing.
        connection.$wireProtocol
            .compactMap { $0 }
            .sink { [weak self] _ in
                guard let self, !self.jobRunner.isActive, !self.uploader.isActive else { return }
                self.info.refresh()
            }
            .store(in: &cancellables)
        connection.$isConnected
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] connected in
                self?.connectionChanged(connected)
            }
            .store(in: &cancellables)
    }

    // MARK: - Sending

    public func sendCommand(_ command: CNCCommand) {
        sendRawCommand(command.command)
    }

    /// Whether `command` is one of the realtime control strings ("?", "!",
    /// "~", "^X") that never travel as a queued line.
    public func isRealtimeCommand(_ command: String) -> Bool {
        realtimeCommand(for: command.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// Sends a line to the machine. "?", "!", "~" and "^X" are realtime
    /// control bytes, not queued lines — they're routed through the
    /// protocol-aware realtime path so they work under both the plain-text
    /// and framed wire protocols. No-op while disconnected.
    public func sendRawCommand(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, connection.isConnected else { return }

        if let realtime = realtimeCommand(for: command) {
            if realtime == .softReset {
                softReset()
            } else {
                connection.sendRealtime(realtime)
            }
            return
        }
        connection.send(command)
    }

    private func realtimeCommand(for command: String) -> MachineRealtimeCommand? {
        switch command {
        case Self.statusCommand: return .statusQuery
        case Self.feedHoldCommand: return .feedHold
        case Self.resumeCommand: return .cycleResume
        case Self.softResetCommand: return .softReset
        default: return nil
        }
    }

    /// Builds a "set current axis position as zero" command. G10 L20 P0 sets
    /// the active work coordinate system offset so the machine's *current*
    /// physical position reads as 0 on the given axes (G92 would only be a
    /// temporary offset, not equivalent).
    nonisolated public static func zeroCommand(x: Bool = false, y: Bool = false, z: Bool = false) -> String {
        var command = "G10L20P0"
        if x { command += "X0" }
        if y { command += "Y0" }
        if z { command += "Z0" }
        return command
    }

    /// The lines that put the job where the canvas shows it: millimeters,
    /// G54 selected, and G54's XY origin set to `offset` with `G10 L2 P1`.
    /// Z is deliberately left out so it keeps whatever the Z probe / Auto Z
    /// step established.
    nonisolated public static func jobOriginCommands(for offset: SIMD2<Float>) -> [String] {
        [
            CNC.millimeterMode.command,
            CNC.workspaceG54.command,
            CNC.setWorkspaceCoordinates
                .with(workspace: 1, x: Double(offset.x), y: Double(offset.y))
                .command
        ]
    }

    // MARK: - Job execution

    /// Uploads `contents` to the machine's SD card as `fileName`, then runs
    /// it (origin → optional Z probe / leveling → `play`). No-op while
    /// disconnected or while an upload is already in flight.
    public func uploadJob(fileName: String, contents: String, options: MachineRunOptions = MachineRunOptions()) {
        guard connection.isConnected, !uploader.isActive, pendingPlayPath == nil else { return }

        var area: GCodeBounds?
        if options.levelBeforeRun {
            // Refuse rather than silently run unleveled: the option is an
            // explicit "don't cut without a height map".
            guard let bounds = GCodeBounds.cutting(in: contents) else {
                connection.appendLog("Auto level is on, but the program has no XY cutting moves to measure. Nothing was sent.")
                return
            }
            area = bounds
        }

        pendingOptions = options
        pendingLevelingArea = area
        uploader.upload(fileName: fileName, contents: Data(contents.utf8))
    }

    /// Cancels an in-flight upload only. `stopJob()` is the general "stop".
    public func cancelUpload() {
        uploader.cancel()
    }

    /// Starts streaming `lines` one at a time. Right for MDI-style manual
    /// sends and small macros; use `uploadJob` for a whole program.
    public func startJob(lines: [String]) {
        guard connection.isConnected else { return }
        jobRunner.start(lines: lines)
    }

    /// Runs once the file is on the SD card. With neither pre-run step on,
    /// it's: set the origin, then `play`. With Auto Z and/or Auto Level on,
    /// the origin lines plus whichever probe steps are enabled go through
    /// `jobRunner` instead, because each has to be acknowledged before the
    /// next, and `play` follows in `levelingFinished` once the machine
    /// reports Idle again.
    private func startRun(remotePath: String) {
        let options = pendingOptions
        let area = pendingLevelingArea
        guard options.autoZBeforeRun || area != nil else {
            applyJobOrigin()
            sendRawCommand("play \(remotePath)")
            return
        }

        // Starting the job anyway would mean cutting unprobed/unleveled, so
        // an already-running macro cancels the run rather than skipping the
        // step silently.
        guard !jobRunner.isActive else {
            connection.appendLog("Auto Z/Level: another command sequence is running, so the job was uploaded but not started.")
            return
        }

        let offset = options.originOffset
        var lines = Self.jobOriginCommands(for: offset)
        var logMessages: [String] = ["Setting G54 work origin to X\(offset.x) Y\(offset.y) (job offset)."]

        if options.autoZBeforeRun {
            lines += [CNC.probe.with(z: -10, feed: 50).command, Self.zeroCommand(z: true)]
            logMessages.append("Auto Z before run: probing and zeroing work Z.")
        }

        if let area {
            let margin = options.levelMargin
            let points = Double(options.levelGridPoints)
            let probe = CNC.probeGrid.with(
                r: 1,
                x: area.minX - margin, y: area.minY - margin,
                a: area.width + 2 * margin, b: area.height + 2 * margin,
                i: points, j: points,
                h: levelProbeHeight
            ).command
            // M370 first so a probe that fails halfway can't leave the
            // previous job's grid active.
            lines += [CNC.clearBedLeveling.command, probe]
            logMessages.append("Auto level before run: \(probe)")
        }

        pendingPlayPath = remotePath
        logMessages.forEach { connection.appendLog($0) }
        jobRunner.start(lines: lines)
    }

    /// The pre-run lines have all been acknowledged. Also fires for any other
    /// `jobRunner` macro finishing, hence the `pendingPlayPath` check.
    private func levelingFinished() {
        guard let path = pendingPlayPath else { return }
        let runID = pendingPlayID
        Task { await self.playWhenIdle(path, runID: runID) }
    }

    /// Starts `play` only once the machine itself reports Idle, not merely
    /// once `G32` was acknowledged. Bails out on Alarm, Stop, disconnect, or
    /// after ten minutes.
    private func playWhenIdle(_ path: String, runID: UUID) async {
        guard pendingPlayID == runID else { return }
        let deadline = Date().addingTimeInterval(600)

        // Let a status report that predates the last line clear out.
        connection.requestStatus()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        while pendingPlayID == runID && pendingPlayPath == path {
            let state = connection.status?.state ?? ""

            if !connection.isConnected || state.hasPrefix("Alarm") || Date() > deadline {
                connection.appendLog("Auto level did not finish cleanly (\(state.isEmpty ? "no status" : state)); the job was not started.")
                pendingPlayPath = nil
                return
            }
            if state.hasPrefix("Idle") { break }

            connection.requestStatus()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Stop (or a newer run) cleared/replaced it while waiting.
        guard pendingPlayID == runID, pendingPlayPath == path else { return }
        pendingPlayPath = nil
        sendRawCommand("play \(path)")
    }

    /// Sends the origin lines for the offset captured by `uploadJob`. These
    /// are non-motion, order-preserving lines, so they don't need the
    /// `jobRunner` ack sequencing — the machine handles them in the order
    /// they arrive, before `play`.
    private func applyJobOrigin() {
        let offset = pendingOptions.originOffset
        connection.appendLog("Setting G54 work origin to X\(offset.x) Y\(offset.y) (job offset).")
        for line in Self.jobOriginCommands(for: offset) {
            sendRawCommand(line)
        }
    }

    // MARK: - Pause / suspend / resume / stop
    //
    // These work on whatever the *machine* is doing, whether that's a
    // program running from the SD card after `GCodeUploader` finished, or a
    // burst streamed by `GCodeJobRunner` — the realtime bytes act on the
    // machine, not on either queue.

    /// Feed-hold: decelerates to a stop, keeping the job resumable.
    public func pauseJob() {
        guard connection.isConnected else { return }

        // Stop the streamed queue regardless of machine state.
        jobRunner.pause()

        // A feed-hold only means something while there's motion to hold.
        guard connection.status?.isRunning == true else { return }
        connection.sendRealtime(.feedHold)
        connection.requestStatus()
    }

    /// Suspends the running job so it can be picked up later, unlike
    /// `pauseJob()`'s feed-hold, which is a momentary stop. `suspend` lets
    /// the planner drain, saves the position and stops the spindle — so the
    /// machine is safe to leave, and to jog around while it waits. Continue
    /// with `resumeJob()`, also after the app was closed and reopened: the
    /// suspended state lives on the machine.
    ///
    /// Only offered for a job playing from the SD card and currently moving.
    public func suspendJob() {
        guard connection.isConnected,
              let status = connection.status,
              status.isRunning,
              status.activeJob != nil else { return }

        suspendRequestedAt = Date()
        sendRawCommand(Self.consoleSuspendCommand)
        connection.requestStatus()
    }

    /// Resumes whichever kind of pause the machine is in, from wherever it
    /// actually paused.
    public func resumeJob() {
        resumeJob(fromLine: nil)
    }

    /// Resumes a held job the same way `resumeJob()` does, but first
    /// repositions the SD-card file's read pointer with the console
    /// `goto <line>` command. Passing `nil` is exactly `resumeJob()`.
    ///
    /// Only meaningful for a job that came from `uploader`, so `line` is
    /// silently ignored unless `lastUploadedRemotePath` is set.
    ///
    /// Not confirmed against real hardware — if `goto` turns out to need the
    /// path repeated, this is the one place to fix it.
    public func resumeJob(fromLine line: Int?) {
        guard connection.isConnected else { return }

        if let line, lastUploadedRemotePath != nil {
            sendRawCommand("goto \(line)")
        }

        // Resume the machine first so it's already moving again by the
        // time the runner queues its next line.
        if let status = connection.status {
            if status.isSuspended {
                sendRawCommand(Self.consoleResumeCommand)
                connection.requestStatus()
            } else if status.isFeedHeld {
                connection.sendRealtime(.cycleResume)
                connection.requestStatus()
            }
        }
        jobRunner.resume()
    }

    /// Stops the job outright.
    /// - Mid-upload: cancels the transfer. Nothing is running on the machine
    ///   yet, so there's nothing to reset.
    /// - Otherwise: a soft-reset, if the machine (or the streamed queue)
    ///   actually has something in progress. Not resumable.
    public func stopJob() {
        pendingPlayPath = nil   // cancels a `play` still waiting on leveling
        if uploader.isActive {
            cancelUpload()
            jobRunner.stop()
            return
        }

        guard connection.isConnected else {
            jobRunner.stop()
            return
        }

        // Read before `softReset()` clears the runner.
        let somethingToAbort = jobRunner.isActive || connection.status?.isBusy == true
        guard somethingToAbort else { return }
        softReset()
    }

    /// Ctrl-X. Halts motion immediately and discards the machine's planned
    /// moves, so unlike `pauseJob()` there is no resuming. The firmware
    /// usually comes back in ALARM and needs an Unlock (`$X`) — deliberately
    /// left as a manual step.
    private func softReset() {
        pendingPlayPath = nil
        // Order matters: empty the queue first so an "ok" that's still on
        // its way can't trigger another line after the reset.
        jobRunner.stop()
        onEvent?(.motionAborting)

        guard connection.sendRealtime(.softReset) else { return }
        connection.appendLog("Soft reset sent. If the machine reports ALARM, use Unlock to clear it.")
        connection.requestStatus()
    }

    /// Probes down at the current XY, then zeroes the work Z coordinate at
    /// the trigger point. The two lines are sequenced through `jobRunner`
    /// (which only advances on the previous line's "ok"), so the zero lands
    /// *after* the tool stopped at the trigger point. Assumes the probe's
    /// "ok" is withheld until the probe cycle finishes — documented
    /// grbl/Smoothieware behavior, not confirmed for Carvera's firmware.
    ///
    /// Zeroes with a flat `Z0`, so it's correct for probing onto the
    /// stock/table surface, wrong for a probe plate of known thickness.
    public func autoZeroProbe() {
        guard connection.isConnected, !jobRunner.isActive else { return }
        jobRunner.start(lines: [
            CNC.probe.with(z: -10, feed: 50).command,
            Self.zeroCommand(z: true)
        ])
    }

    // MARK: - Alerts

    private func post(_ alert: MachineAlert) {
        lastPostedAt[alert.kind] = Date()
        onEvent?(.alert(alert))
    }

    private func wasPosted(_ kind: MachineAlert.Kind, within seconds: TimeInterval) -> Bool {
        guard let date = lastPostedAt[kind] else { return false }
        return Date().timeIntervalSince(date) < seconds
    }

    /// Alarm, error and tool-change lines from the machine.
    private func raiseAlert(forLine line: String) {
        guard let alert = MachineAlertRules.alert(forLine: line) else { return }
        if alert.kind == .alarm || alert.kind == .error {
            lastFault = (alert.message, Date())
        }
        post(alert)
    }

    /// The status report is the second source of truth: it catches a stop
    /// the machine didn't explain in text, and tells us when the cause has
    /// gone away (someone resumed or unlocked at the machine itself).
    private func machineStateChanged(to state: String) {
        let previous = lastBaseState
        lastBaseState = state

        // First report after connecting, and a job is sitting suspended on
        // the machine: the "continue later" moment. Say where it stopped.
        if previous.isEmpty, state == "Pause" {
            var message = "A job is suspended on the machine."
            if let job = connection.status?.activeJob {
                message = "A job is suspended on the machine at line \(job.currentLine) (\(job.percent)%, \(job.elapsedText) elapsed)."
            }
            post(MachineAlert(
                kind: .suspendedJob,
                title: "Suspended job",
                message: message + " If it stopped for a tool change, do that first, then resume."
            ))
            return
        }

        guard !state.isEmpty, !previous.isEmpty, state != previous else { return }

        // The job ended (or the machine faulted) before a requested suspend
        // took effect: a later pause is then not ours.
        if state == "Idle" || state == "Alarm" { suspendRequestedAt = nil }

        switch state {
        case "Alarm":
            // The explaining line normally arrives first and has already
            // raised its own alert.
            if !wasPosted(.alarm, within: 10) {
                var detail = "The machine stopped with an alarm. Check the terminal, then Unlock to clear it."
                if let fault = lastFault, Date().timeIntervalSince(fault.date) < 15 {
                    detail = fault.text
                }
                post(MachineAlert(kind: .alarm, title: "Machine alarm", message: detail))
            }
        case "Pause":
            if let requested = suspendRequestedAt, Date().timeIntervalSince(requested) < 60 {
                // Our own `suspend` took effect — the person knows.
                suspendRequestedAt = nil
            } else if !wasPosted(.toolChange, within: 60) {
                // Otherwise the machine paused itself — usually to wait for
                // a tool change. Skipped when a specific tool-change prompt
                // already said so.
                post(MachineAlert(
                    kind: .paused,
                    title: "Job paused by the machine",
                    message: "It may be waiting for a tool change. Check the machine, then resume."
                ))
            }
        default:
            break
        }

        if previous == "Pause" { onEvent?(.alertsResolved([.toolChange, .paused, .suspendedJob])) }
        if previous == "Alarm" { onEvent?(.alertsResolved([.alarm])) }
    }

    private func connectionChanged(_ connected: Bool) {
        if connected {
            onEvent?(.connected)
            return
        }
        pendingPlayPath = nil
        pendingLevelingArea = nil
        info.reset()
        jobRunner.stop()
        uploader.connectionClosed()
        onEvent?(.disconnected)
        // `lastError` is only set by failures, not by an ordinary disconnect.
        if connection.lastError != nil, ["Run", "Hold", "Pause"].contains(lastBaseState) {
            post(MachineAlert(
                kind: .connectionLost,
                title: "Lost connection to the machine",
                message: "A job that was already started from the SD card should keep running on the machine. Reconnect to monitor it."
            ))
        }
        lastBaseState = ""
    }
}
