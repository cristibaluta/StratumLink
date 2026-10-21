//
//  MachineAlert.swift
//  StratumLink
//

import Foundation

/// Something the person at the machine needs to know about *now* — a tool
/// change waiting on them, an alarm, an error. Deliberately not the same as
/// a line in the terminal log, which is easy to miss mid-job.
///
/// The library only *describes* the alert (`MachineSession` emits it through
/// `MachineSessionEvent.alert`); how it is presented — dialog, sound, Dock
/// bounce, system notification — is up to the host app.
public struct MachineAlert: Identifiable, Equatable {

    public enum Kind: Hashable {
        /// The machine wants a tool swapped (needs the person, then Resume).
        case toolChange
        /// The machine paused the job and we can't tell why.
        case paused
        case alarm
        case error
        case connectionLost
        /// A job was already suspended on the machine when we connected —
        /// e.g. the app was closed while it waited. Informational: nothing
        /// is going wrong, it's just there to be picked back up.
        case suspendedJob
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let message: String

    public init(kind: Kind, title: String, message: String) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    /// The alert is about a stopped job that continues when the person says
    /// so, so the dialog offers a Resume button.
    public var offersResume: Bool {
        kind == .toolChange || kind == .paused || kind == .suspendedJob
    }

    /// Kinds that keep repeating a sound until dismissed — the ones where
    /// the machine is stuck until someone acts.
    public var isPersistent: Bool {
        kind != .error && kind != .suspendedJob
    }
}

/// Recognizes alerts in the machine's text output.
///
/// Alarm and error lines follow grbl/Smoothieware conventions (`ALARM: …`,
/// `error: …`, `!!` for a halt). The tool-change matching is a *heuristic*:
/// nothing in this project records the exact wording the firmware uses when
/// it wants a tool swapped, so it looks for a line that mentions a tool and
/// a change/insert/load-type verb. Capture what a real M6 prints in the
/// terminal and tighten `isToolChangePrompt` to that.
public enum MachineAlertRules {

    public static func alert(forLine line: String) -> MachineAlert? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !text.isEmpty, lower != "ok", !lower.hasPrefix("ok ") else { return nil }

        if lower.hasPrefix("alarm") || lower.hasPrefix("!!") {
            return MachineAlert(kind: .alarm, title: "Machine alarm", message: stripPrefix(text))
        }
        if lower.hasPrefix("error") {
            return MachineAlert(kind: .error, title: "Machine error", message: stripPrefix(text))
        }
        if isToolChangePrompt(lower) {
            let title = toolNumber(in: lower).map { "Tool change needed (T\($0))" } ?? "Tool change needed"
            return MachineAlert(kind: .toolChange, title: title, message: text)
        }
        return nil
    }

    public static func isToolChangePrompt(_ lower: String) -> Bool {
        guard lower.contains("tool") else { return false }
        let asks = ["change", "insert", "install", "load", "replace", "swap"]
        let finished = ["done", "complete", "finish", "success"]
        return asks.contains { lower.contains($0) } && !finished.contains { lower.contains($0) }
    }

    public static func toolNumber(in lower: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\bt(?:ool)?\s*#?\s*(\d+)\b"#),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower) else { return nil }
        return Int(lower[range])
    }

    /// "ALARM: Hard limit" → "Hard limit".
    private static func stripPrefix(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"^(?i)(alarm|error|!!)\s*:?\s*"#, with: "", options: .regularExpression
        )
        return stripped.isEmpty ? text : stripped
    }
}
