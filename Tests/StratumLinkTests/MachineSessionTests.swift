import Foundation
import Testing
@testable import StratumLink

struct MachineSessionTests {

    @Test func alertRulesRecognizeAlarmsErrorsAndToolChanges() throws {
        #expect(MachineAlertRules.alert(forLine: "ok") == nil)
        #expect(MachineAlertRules.alert(forLine: "ALARM: Hard limit")?.message == "Hard limit")
        #expect(MachineAlertRules.alert(forLine: "error: bad")?.kind == .error)
        let tool = try #require(MachineAlertRules.alert(forLine: "Please change tool T3"))
        #expect(tool.kind == .toolChange)
        #expect(tool.title == "Tool change needed (T3)")
    }

    @Test func originCommandsSetG54ToTheOffset() {
        let lines = MachineSession.jobOriginCommands(for: SIMD2<Float>(10, 20))
        #expect(lines.count == 3)
        #expect(lines.last?.contains("X10") == true)
        #expect(lines.last?.contains("Y20") == true)
    }

    @Test @MainActor func realtimeStringsAreNotQueuedLines() {
        let session = MachineSession()
        for command in ["?", "!", "~", "^X"] { #expect(session.isRealtimeCommand(command)) }
        #expect(!session.isRealtimeCommand("G1 X1"))
    }

    @Test @MainActor func disconnectEmitsEventAndReportsLastUploadPath() async throws {
        let session = MachineSession(lastUploadedRemotePath: "/sd/gcodes/a.nc")
        #expect(session.lastUploadedRemotePath == "/sd/gcodes/a.nc")
        var paths: [String?] = []
        session.onLastUploadedRemotePathChange = { paths.append($0) }
        var disconnected = false
        session.onEvent = { if case .disconnected = $0 { disconnected = true } }
        session.connection.connect(to: .mock)
        session.uploader.onCompleted?("/sd/gcodes/b.nc")
        session.stopJob()
        session.connection.disconnect()
        try await Task.sleep(for: .milliseconds(50))
        #expect(paths == ["/sd/gcodes/b.nc"])
        #expect(disconnected)
    }
}
