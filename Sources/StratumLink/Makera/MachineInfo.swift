//
//  MachineInfo.swift
//  StratumLink
//

import Foundation
import Combine

/// One entry of an SD-card directory listing (`ls -e -s <path>`).
public struct MachineFileEntry: Identifiable, Equatable, Hashable {
    public var id: String { path }
    public let name: String
    /// Full SD path, e.g. `/sd/gcodes/part.nc`.
    public let path: String
    public let isDirectory: Bool
    /// Bytes; 0 for directories.
    public let size: Int
    /// `nil` when the machine didn't report a (valid) timestamp.
    public let modified: Date?

    public init(name: String, path: String, isDirectory: Bool, size: Int, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    /// Parses one line of `ls -e -s` output: `name size yyyyMMddHHmmss`.
    /// Names may contain spaces, so the line is read from the right. Directory
    /// names carry a trailing `/`. Returns `nil` for anything that isn't an
    /// entry ("ok", status reports, version lines, noise).
    public static func parse(line: String, directory: String) -> MachineFileEntry? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "ok", !text.hasPrefix("<"), !text.hasPrefix("version") else { return nil }

        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var modified: Date?
        if tokens.count >= 3, tokens[tokens.count - 1].count == 14,
           tokens[tokens.count - 1].allSatisfy(\.isNumber) {
            modified = timestampFormatter.date(from: tokens.removeLast())
        }
        guard tokens.count >= 2, let size = Int(tokens[tokens.count - 1]) else { return nil }
        tokens.removeLast()

        var name = tokens.joined(separator: " ")
        let isDirectory = name.hasSuffix("/")
        if isDirectory { name.removeLast() }
        guard !name.isEmpty else { return nil }

        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return MachineFileEntry(name: name, path: base + name, isDirectory: isDirectory,
                                size: isDirectory ? 0 : size, modified: modified)
    }
}

/// What the machine can tell us about itself: firmware version and the files
/// on its SD card. Fed by `MachineSession`, which forwards every non-status
/// line the machine sends, and sends the queries through the same path as
/// any other console command.
///
/// MakeraStudio's console trail on connect:
/// ```
/// download /sd/config.txt        (file transfer — not handled here)
/// version = 1.1.2.0.1.13         (reply to `version`)
/// ls -e -s /sd/gcodes            (directory listing)
/// ```
@MainActor
public final class MachineInfo: ObservableObject {

    public static let defaultDirectory = "/sd/gcodes"

    @Published public private(set) var firmwareVersion: String?
    @Published public private(set) var files: [MachineFileEntry] = []
    @Published public private(set) var currentDirectory = MachineInfo.defaultDirectory
    @Published public private(set) var isLoadingFiles = false

    private var send: ((String) -> Void)?
    private var pendingDirectory: String?
    private var pendingEntries: [MachineFileEntry] = []
    private var listingID = UUID()
    /// The firmware doesn't mark the end of a listing reliably across
    /// versions, so an "ok" ends it — or this much silence after the last line.
    private let quietTimeout: TimeInterval = 1.0

    public init() {}

    func configure(send: @escaping (String) -> Void) {
        self.send = send
    }

    // MARK: Requests

    /// Asks for the firmware version and the default directory's listing.
    public func refresh() {
        requestVersion()
        listFiles()
    }

    public func requestVersion() {
        send?("version")
    }

    /// Lists `directory` on the SD card. Don't call while a job is running or
    /// uploading — the listing's "ok" would be seen by the job as an ack.
    public func listFiles(in directory: String = MachineInfo.defaultDirectory) {
        var directory = directory
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        pendingDirectory = directory
        pendingEntries = []
        isLoadingFiles = true
        send?("ls -e -s \(MakeraFraming.escapeConsolePath(directory))")
        armTimeout()
    }

    /// Back to the empty state, on disconnect.
    func reset() {
        listingID = UUID()
        pendingDirectory = nil
        pendingEntries = []
        isLoadingFiles = false
        firmwareVersion = nil
        files = []
        currentDirectory = Self.defaultDirectory
    }

    // MARK: Incoming

    func handleMachineLine(_ line: String) {
        // The firmware can pack many lines (a whole directory listing) into
        // one frame, and the connection hands those over as a single string.
        for part in line.split(whereSeparator: \.isNewline) {
            handleSingleLine(String(part))
        }
    }

    private func handleSingleLine(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.lowercased().hasPrefix("version") {
            if let eq = text.firstIndex(of: "=") {
                firmwareVersion = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
            return
        }

        guard let directory = pendingDirectory else { return }
        if text == "ok" {
            // The listing may arrive in several pieces; give any that are
            // still in flight a moment before closing it.
            armTimeout(after: 0.4)
        } else if let entry = MachineFileEntry.parse(line: text, directory: directory) {
            if !pendingEntries.contains(entry) { pendingEntries.append(entry) }
            armTimeout()
        }
    }

    private func armTimeout(after delay: TimeInterval? = nil) {
        let id = UUID()
        listingID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? quietTimeout)) { [weak self] in
            guard let self, self.listingID == id, self.pendingDirectory != nil else { return }
            self.finishListing()
        }
    }

    private func finishListing() {
        guard let directory = pendingDirectory else { return }
        listingID = UUID()
        currentDirectory = directory
        // Folders first, then by name.
        files = pendingEntries.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        pendingDirectory = nil
        pendingEntries = []
        isLoadingFiles = false
    }
}
