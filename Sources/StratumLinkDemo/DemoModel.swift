//
//  DemoModel.swift
//  StratumLinkDemo
//

import SwiftUI
import Combine
import StratumLink

/// Thin SwiftUI wrapper around `MachineSession`: republishes the library's
/// observable parts (connection, uploader, job runner, discovery) so one view
/// can observe everything, and keeps the demo-only UI state.
@MainActor
final class DemoModel: ObservableObject {

    let session = MachineSession()
    let discovery = MachineDiscovery()

    var connection: MachineConnection { session.connection }
    var uploader: GCodeUploader { session.uploader }
    var jobRunner: GCodeJobRunner { session.jobRunner }

    @Published var selectedMachine: MakeraMachine?
    @Published var alerts: [MachineAlert] = []
    @Published var eventLog: [String] = []

    // Inputs
    @Published var mdiInput = ""
    @Published var jogStep = 1.0
    @Published var jogFeed = 1000.0
    @Published var spindleRPM = "12000"
    @Published var feedOverride = 100.0
    @Published var toolNumber = "1"
    @Published var vacuumPercent = "100"
    @Published var fanPercent = "100"
    @Published var gcode = """
    G21 G90
    G0 X0 Y0
    G1 X10 Y0 F600
    G1 X10 Y10
    G1 X0 Y10
    G1 X0 Y0
    M5
    """
    @Published var fileName = "demo.nc"
    @Published var options = MachineRunOptions()
    @Published var offsetX = 0.0
    @Published var offsetY = 0.0
    @Published var resumeLine = "1"

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward nested objects' changes so the whole window refreshes.
        Publishers.MergeMany(
            session.connection.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.uploader.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.jobRunner.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.info.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            discovery.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)

        session.onEvent = { [weak self] event in
            self?.handle(event)
        }
        session.onLastUploadedRemotePathChange = { [weak self] path in
            self?.log("last uploaded path → \(path ?? "nil")")
        }
        discovery.startScanning()
    }

    private func handle(_ event: MachineSessionEvent) {
        switch event {
        case .alert(let alert):
            alerts.append(alert)
            log("alert [\(alert.kind)] \(alert.title): \(alert.message)")
        case .alertsResolved(let kinds):
            alerts.removeAll { kinds.contains($0.kind) }
            log("alerts resolved: \(kinds)")
        case .connected:
            log("connected")
        case .disconnected:
            log("disconnected")
        case .motionAborting:
            log("motion aborting (soft reset)")
        }
    }

    private func log(_ message: String) {
        eventLog.append(message)
        if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
    }

    // MARK: Connection

    func connect(_ machine: MakeraMachine) {
        selectedMachine = machine
        connection.connect(to: machine)
    }

    func disconnect() {
        connection.disconnect()
    }

    // MARK: Sending

    func send(_ command: CNCCommand) {
        session.sendCommand(command)
    }

    func send(_ raw: String) {
        session.sendRawCommand(raw)
    }

    func sendMDI() {
        send(mdiInput)
        mdiInput = ""
    }

    func jog(x: Double = 0, y: Double = 0, z: Double = 0) {
        var words = ""
        if x != 0 { words += " X\(x * jogStep)" }
        if y != 0 { words += " Y\(y * jogStep)" }
        if z != 0 { words += " Z\(z * jogStep)" }
        session.startJob(lines: [
            CNC.relativeMode.command,
            "G1\(words) F\(Int(jogFeed))",
            CNC.absoluteMode.command
        ])
    }

    func runJob() {
        var runOptions = options
        runOptions.originOffset = SIMD2<Float>(Float(offsetX), Float(offsetY))
        session.uploadJob(fileName: fileName, contents: gcode, options: runOptions)
    }
}
