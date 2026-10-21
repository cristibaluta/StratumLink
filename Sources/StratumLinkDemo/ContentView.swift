//
//  ContentView.swift
//  StratumLinkDemo
//

import SwiftUI
import StratumLink

struct ContentView: View {

    @StateObject private var model = DemoModel()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column { machinesBox; statusBox; alertsBox; eventsBox }
                .frame(width: 280)
            column { jogBox; spindleBox; probeBox; atcBox; accessoriesBox }
                .frame(width: 340)
            column { jobBox; terminalBox }
                .frame(minWidth: 380)
        }
        .padding(12)
        .frame(minWidth: 1060, minHeight: 760)
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }
        }
    }

    private var connected: Bool { model.connection.isConnected }

    // MARK: - Machines

    private var machinesBox: some View {
        GroupBox("Machines") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.discovery.machines) { machine in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(machine.name)
                            Text("\(machine.ip):\(machine.port)\(machine.busy ? " · busy" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connected && model.selectedMachine?.id == machine.id {
                            Button("Disconnect") { model.disconnect() }
                        } else {
                            Button("Connect") { model.connect(machine) }
                        }
                    }
                }
                HStack {
                    Button(model.discovery.isScanning ? "Stop scan" : "Scan") {
                        model.discovery.isScanning ? model.discovery.stopScanning() : model.discovery.startScanning()
                    }
                    if let error = model.discovery.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status

    private var statusBox: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 4) {
                row("Connected", connected ? "yes" : "no")
                row("Protocol", model.connection.wireProtocol?.rawValue ?? "—")
                if let status = model.connection.status {
                    row("State", status.state)
                    row("MPos", pos(status.machinePosition))
                    row("WPos", pos(status.workPosition))
                    if let job = status.activeJob {
                        ProgressView(value: job.fraction)
                        row("Job", "line \(job.currentLine) · \(job.percent)% · \(job.elapsedText)")
                    } else if let last = status.lastJob {
                        row("Last job", "stopped at line \(last.currentLine)")
                    }
                }
                if let error = model.connection.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pos(_ p: (x: Double, y: Double, z: Double)) -> String {
        String(format: "%.3f  %.3f  %.3f", p.x, p.y, p.z)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospacedDigit())
        }
        .font(.caption)
    }

    // MARK: - Alerts / events

    private var alertsBox: some View {
        GroupBox("Alerts") {
            VStack(alignment: .leading, spacing: 6) {
                if model.alerts.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(model.alerts) { alert in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(alert.title).bold()
                            Text(alert.message).font(.caption)
                        }
                        Spacer()
                        if alert.offersResume {
                            Button("Resume") { model.session.resumeJob() }
                        }
                        Button("✕") { model.alerts.removeAll { $0.id == alert.id } }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var eventsBox: some View {
        GroupBox("Session events") {
            ScrollView {
                Text(model.eventLog.suffix(30).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
        }
    }

    // MARK: - Jog

    private var jogBox: some View {
        GroupBox("Jog") {
            VStack(spacing: 8) {
                HStack {
                    Picker("Step", selection: $model.jogStep) {
                        ForEach([0.1, 1, 10, 50], id: \.self) { Text("\($0, specifier: "%g")") .tag($0) }
                    }
                    Picker("Feed", selection: $model.jogFeed) {
                        ForEach([200.0, 500, 1000, 3000], id: \.self) { Text("\(Int($0))").tag($0) }
                    }
                }
                HStack(spacing: 16) {
                    VStack {
                        Button("Y+") { model.jog(y: 1) }
                        HStack {
                            Button("X−") { model.jog(x: -1) }
                            Button("X+") { model.jog(x: 1) }
                        }
                        Button("Y−") { model.jog(y: -1) }
                    }
                    VStack {
                        Button("Z+") { model.jog(z: 1) }
                        Button("Z−") { model.jog(z: -1) }
                    }
                }
                HStack {
                    Button("Home") { model.send(MachineSession.homeCommand) }
                    Button("Unlock") { model.send(MachineSession.unlockCommand) }
                    Button("Status ?") { model.connection.requestStatus() }
                }
                HStack {
                    Button("Zero X") { model.send(MachineSession.zeroCommand(x: true)) }
                    Button("Zero Y") { model.send(MachineSession.zeroCommand(y: true)) }
                    Button("Zero Z") { model.send(MachineSession.zeroCommand(z: true)) }
                    Button("Zero XYZ") { model.send(MachineSession.zeroCommand(x: true, y: true, z: true)) }
                }
            }
            .disabled(!connected)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Spindle

    private var spindleBox: some View {
        GroupBox("Spindle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("RPM", text: $model.spindleRPM).frame(width: 80)
                    Button("On") { model.send(CNC.spindleOn.with(rpm: Int(model.spindleRPM) ?? 0)) }
                    Button("Off") { model.send(CNC.spindleOff) }
                    Button("Temp") { model.send(CNC.spindleTemperature) }
                }
                HStack {
                    Text("Feed \(Int(model.feedOverride))%").frame(width: 80, alignment: .leading)
                    Slider(value: $model.feedOverride, in: 10...200, step: 10) { editing in
                        if !editing { model.send(CNC.feedOverride.with(percent: Int(model.feedOverride))) }
                    }
                }
            }
            .disabled(!connected)
        }
    }

    // MARK: - Probe

    private var probeBox: some View {
        GroupBox("Probe") {
            HStack {
                Button("Probe Z") { model.send(CNC.probe.with(z: -10, feed: 50)) }
                Button("Auto Z (probe + zero)") { model.session.autoZeroProbe() }
                Button("Clear leveling") { model.send(CNC.clearBedLeveling) }
            }
            .disabled(!connected)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - ATC

    private var atcBox: some View {
        GroupBox("Tool changer") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Tool", text: $model.toolNumber).frame(width: 50)
                    Button("M6 T") { model.send(CNC.toolChange.with(tool: Int(model.toolNumber) ?? 1)) }
                    Button("Probe (T0)") { model.send(CNC.toolChange.with(tool: 0)) }
                }
                HStack {
                    Button("ATC home") { model.send(CNC.automaticToolChangerHome) }
                    Button("Tighten") { model.send(CNC.tightenSpindleCollet) }
                    Button("Loosen") { model.send(CNC.loosenSpindleCollet) }
                }
                HStack {
                    Button("Calibrate tool") { model.send(CNC.calibrateTool) }
                    Button("Detector on") { model.send(CNC.toolDetectorLaserOn) }
                    Button("off") { model.send(CNC.toolDetectorLaserOff) }
                }
            }
            .disabled(!connected)
        }
    }

    // MARK: - Accessories

    private var accessoriesBox: some View {
        GroupBox("Accessories") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Light on") { model.send(CNC.lightOn) }
                    Button("Light off") { model.send(CNC.lightOff) }
                    Button("Air on") { model.send(CNC.airflowOn) }
                    Button("Air off") { model.send(CNC.airflowOff) }
                }
                HStack {
                    Text("Vacuum")
                    TextField("%", text: $model.vacuumPercent).frame(width: 50)
                    Button("On") { model.send(CNC.internalVacuumOn.with(percent: Int(model.vacuumPercent) ?? 0)) }
                    Button("Off") { model.send(CNC.internalVacuumOff) }
                    Button("Auto") { model.send(CNC.automaticVacuumOn) }
                }
                HStack {
                    Text("Fan")
                    TextField("%", text: $model.fanPercent).frame(width: 50)
                    Button("On") { model.send(CNC.spindleCoolingFanOn.with(percent: Int(model.fanPercent) ?? 0)) }
                    Button("Off") { model.send(CNC.spindleCoolingFanOff) }
                }
                HStack {
                    Button("Beep on") { model.send(CNC.beepOn) }
                    Button("Beep off") { model.send(CNC.beepOff) }
                }
            }
            .disabled(!connected)
        }
    }

    // MARK: - Job

    private var jobBox: some View {
        GroupBox("Job") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("File")
                    TextField("name.nc", text: $model.fileName)
                }
                TextEditor(text: $model.gcode)
                    .font(.body.monospaced())
                    .frame(height: 150)
                    .border(.separator)

                HStack {
                    Text("Origin offset")
                    TextField("X", value: $model.offsetX, format: .number).frame(width: 60)
                    TextField("Y", value: $model.offsetY, format: .number).frame(width: 60)
                }
                Toggle("Auto Z before run", isOn: $model.options.autoZBeforeRun)
                Toggle("Auto level before run", isOn: $model.options.levelBeforeRun)
                if model.options.levelBeforeRun {
                    Stepper("Grid \(model.options.levelGridPoints)×\(model.options.levelGridPoints)",
                            value: $model.options.levelGridPoints, in: 2...10)
                    Stepper("Margin \(Int(model.options.levelMargin)) mm",
                            value: $model.options.levelMargin, in: 0...20)
                }

                HStack {
                    Button("Upload & Run") { model.runJob() }
                        .disabled(!connected || model.uploader.isActive)
                    Button("Pause") { model.session.pauseJob() }
                    Button("Suspend") { model.session.suspendJob() }
                    Button("Resume") { model.session.resumeJob() }
                    Button("Stop") { model.session.stopJob() }
                }
                .disabled(!connected)

                HStack {
                    Text("Resume from line")
                    TextField("1", text: $model.resumeLine).frame(width: 60)
                    Button("Go") { model.session.resumeJob(fromLine: Int(model.resumeLine)) }
                        .disabled(!connected)
                }

                Text("Upload: \(describe(model.uploader.state))").font(.caption)
                Text("Macro runner: \(describe(model.jobRunner.state)) (\(model.jobRunner.linesSent)/\(model.jobRunner.totalLines))")
                    .font(.caption)
                if let path = model.session.lastUploadedRemotePath {
                    Text("Last uploaded: \(path)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func describe(_ state: GCodeUploader.State) -> String {
        switch state {
        case .transferring(let sent, let total): return "transferring \(sent)/\(total) bytes"
        case .completed(let path): return "completed → \(path)"
        case .failed(let message): return "failed: \(message)"
        default: return "\(state)"
        }
    }

    private func describe(_ state: GCodeJobRunner.State) -> String {
        if case .failed(let message) = state { return "failed: \(message)" }
        return "\(state)"
    }

    // MARK: - Terminal

    private var terminalBox: some View {
        GroupBox("Terminal") {
            VStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.connection.rawLog.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(height: 220)
                    .onChange(of: model.connection.rawLog.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
                HStack {
                    TextField("G-code or console command", text: $model.mdiInput)
                        .onSubmit { model.sendMDI() }
                    Button("Send") { model.sendMDI() }
                    Button("Clear") { model.connection.clearLogs() }
                }
                .disabled(!connected)
                HStack {
                    Button("? status") { model.send(MachineSession.statusCommand) }
                    Button("! hold") { model.send(MachineSession.feedHoldCommand) }
                    Button("~ resume") { model.send(MachineSession.resumeCommand) }
                    Button("^X reset") { model.send(MachineSession.softResetCommand) }
                }
                .disabled(!connected)
            }
        }
    }
}
