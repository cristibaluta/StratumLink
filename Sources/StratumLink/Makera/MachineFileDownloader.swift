//
//  MachineFileDownloader.swift
//  StratumLink
//

import Foundation
import Combine
import CryptoKit

/// Downloads a file from the machine's SD card, e.g. to open a program that's
/// already on the machine.
///
/// The framed transfer protocol, as implemented by Carvera_Controller
/// (`XMODEM.py` → `recv`, `Controller.py` → `downloadCommand`):
///
/// 1. Host → `FILE_START` (0xB0) carrying `download <path>\n`, with spaces in
///    the path as `\u{1}` and `? & ! ~` as `\u{2}…\u{5}`.
/// 2. Machine → `FILE_MD5` (0xB1): the file's MD5 as 32 hex characters.
/// 3. Host → `FILE_VIEW` (0xB2), empty.
/// 4. Machine → `FILE_VIEW`: the number of packets, 4 bytes big-endian.
/// 5. Host → `FILE_DATA` (0xB3) with a 4-byte big-endian packet number,
///    starting at 1 — a request for that packet. Machine → `FILE_DATA`:
///    the packet number (4 bytes) followed by the data. Repeat, asking for
///    the next number after each packet received.
/// 6. After the last packet the host sends `FILE_END` (0xB4), empty.
///
/// `FILE_CAN` (0xB5) from the machine means it cancelled; the host sends
/// `FILE_RETRY` (0xB6) / re-asks when nothing arrives.
@MainActor
public final class MachineFileDownloader: ObservableObject {

    public enum State: Equatable {
        case idle
        case downloading(path: String, bytesReceived: Int)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    /// 0...1 while downloading, from the packets received so far. Stays 0
    /// until the machine has said how many packets there are.
    @Published public private(set) var progress: Double = 0

    public var isActive: Bool {
        if case .downloading = state { return true }
        return false
    }

    private enum Phase { case waitMD5, waitView, readData }

    private var wireProtocol: (() -> MakeraWireProtocol?)?
    private var isMock: (() -> Bool)?
    private var sendFrame: ((UInt8, Data) -> Void)?
    private var setBusy: ((Bool) -> Void)?
    private var log: ((String) -> Void)?

    private var path = ""
    private var phase = Phase.waitMD5
    private var totalPackets = 0
    private var nextPacket = 1
    private var received = Data()
    private var advertisedMD5: String?
    private var lastRequest: (ptype: UInt8, payload: Data) = (MakeraFraming.ptypeFileMD5, Data())
    private var retries = 0
    private var completion: ((Result<Data, Error>) -> Void)?
    private var watchdogID = UUID()
    /// Silence before re-sending the last request, and how many times.
    private let stallInterval: TimeInterval = 3
    private let maxRetries = 5

    public init() {}

    func configure(wireProtocol: @escaping () -> MakeraWireProtocol?,
                   isMock: @escaping () -> Bool,
                   sendFrame: @escaping (UInt8, Data) -> Void,
                   setBusy: @escaping (Bool) -> Void,
                   log: @escaping (String) -> Void) {
        self.wireProtocol = wireProtocol
        self.isMock = isMock
        self.sendFrame = sendFrame
        self.setBusy = setBusy
        self.log = log
    }

    // MARK: Request

    /// Downloads `path` (e.g. `/sd/gcodes/part.nc`). No-op while another
    /// download is active.
    public func download(path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard !isActive else { return }

        if isMock?() == true {
            state = .downloading(path: path, bytesReceived: 0)
            progress = 0
            let id = UUID(); watchdogID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.watchdogID == id else { return }
                self.state = .idle
                completion(.success(Data(Self.mockProgram(named: (path as NSString).lastPathComponent).utf8)))
            }
            return
        }
        guard wireProtocol?() == .makera else {
            state = .failed("Downloading files needs the Makera (framed) protocol.")
            return
        }

        self.path = path
        progress = 0
        phase = .waitMD5
        totalPackets = 0
        nextPacket = 1
        received = Data()
        advertisedMD5 = nil
        retries = 0
        self.completion = completion
        state = .downloading(path: path, bytesReceived: 0)
        setBusy?(true)

        lastRequest = (MakeraFraming.ptypeFileMD5, Data())
        let command = "download \(MakeraFraming.escapeConsolePath(path))\n"
        log?("[download] > \(command.trimmingCharacters(in: .whitespacesAndNewlines))")
        sendFrame?(MakeraFraming.ptypeFileStart, Data(command.utf8))
        armWatchdog()
    }

    func connectionClosed() {
        guard isActive else { return }
        fail("Connection closed during download.")
    }

    // MARK: Incoming

    func handleFrame(_ ptype: UInt8, _ payload: Data) {
        guard isActive else { return }

        if ptype == MakeraFraming.ptypeFileCancel {
            fail("The machine cancelled the transfer.")
            return
        }

        switch (phase, ptype) {
        case (.waitMD5, MakeraFraming.ptypeFileMD5):
            advertisedMD5 = String(data: payload, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            phase = .waitView
            request(MakeraFraming.ptypeFileView, Data())

        case (.waitView, MakeraFraming.ptypeFileView):
            guard payload.count >= 4 else { return }
            totalPackets = Self.bigEndianInt(payload.prefix(4))
            log?("[download] \(totalPackets) packet(s)")
            if totalPackets == 0 {
                request(MakeraFraming.ptypeFileEnd, Data())
                finish()
                return
            }
            phase = .readData
            nextPacket = 1
            request(MakeraFraming.ptypeFileData, Self.packetNumber(1))

        case (.readData, MakeraFraming.ptypeFileData):
            guard payload.count >= 4 else { return }
            let seq = Self.bigEndianInt(payload.prefix(4))
            guard seq == nextPacket else { return } // duplicate / out of order
            received.append(payload.dropFirst(4))
            state = .downloading(path: path, bytesReceived: received.count)
            progress = totalPackets > 0 ? Double(seq) / Double(totalPackets) : 0
            if seq >= totalPackets {
                sendFrame?(MakeraFraming.ptypeFileEnd, Data())
                finish()
            } else {
                nextPacket += 1
                request(MakeraFraming.ptypeFileData, Self.packetNumber(nextPacket))
            }

        default:
            break // not what this phase is waiting for; the watchdog re-asks
        }
    }

    /// Machine text replies. Used only to surface failures ("file not found").
    func handleMachineLine(_ line: String) {
        for part in line.split(whereSeparator: \.isNewline) {
            let lower = part.lowercased()
            guard isActive else { return }
            if lower.contains("no such file") || lower.contains("not found") || lower.contains("could not open")
                || (lower.contains("download") && (lower.contains("fail") || lower.contains("error"))) {
                fail(String(part))
            }
        }
    }

    // MARK: Completion

    private func finish() {
        let data = received
        if data.prefix(2) == Data([0, 0]) {
            fail("This file is stored compressed (QuickLZ) on the machine, which isn't supported yet.")
            return
        }
        if let md5 = advertisedMD5, md5.count == 32, md5.allSatisfy(\.isHexDigit) {
            let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == md5 else {
                fail("Downloaded file is corrupt (MD5 mismatch).")
                return
            }
        }
        let done = completion
        reset()
        done?(.success(data))
    }

    private func fail(_ message: String) {
        let done = completion
        if isActive, phase != .waitMD5 || !received.isEmpty {
            sendFrame?(MakeraFraming.ptypeFileCancel, Data())
        }
        reset()
        state = .failed(message)
        done?(.failure(NSError(domain: "StratumLink.Download", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: message])))
    }

    private func reset() {
        watchdogID = UUID()
        received = Data()
        completion = nil
        state = .idle
        setBusy?(false)
    }

    // MARK: Requests & retries

    private func request(_ ptype: UInt8, _ payload: Data) {
        lastRequest = (ptype, payload)
        retries = 0
        sendFrame?(ptype, payload)
        armWatchdog()
    }

    /// If the machine goes quiet, ask again; give up after a few tries.
    private func armWatchdog() {
        let id = UUID()
        watchdogID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + stallInterval) { [weak self] in
            guard let self, self.watchdogID == id, self.isActive else { return }
            self.retries += 1
            if self.retries > self.maxRetries {
                self.fail("Timed out waiting for the machine.")
                return
            }
            self.log?("[download] no answer, asking again (\(self.retries)/\(self.maxRetries))")
            self.sendFrame?(self.lastRequest.ptype, self.lastRequest.payload)
            self.armWatchdog()
        }
    }

    // MARK: Helpers

    private static func bigEndianInt(_ bytes: Data) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func packetNumber(_ n: Int) -> Data {
        let v = UInt32(n)
        return Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func mockProgram(named name: String) -> String {
        """
        ; \(name) (simulated download)
        G21 G90
        G0 X0 Y0
        G1 X40 Y0 F600
        G1 X40 Y25
        G1 X0 Y25
        G1 X0 Y0
        M5
        """
    }
}
