//
//  MakeraMachine.swift
//  Stratum CNC
//
//  Created by Cristian Baluta on 20.08.2026.
//

import Foundation

/// A Carvera machine discovered on the local network.
///
/// The firmware broadcasts a UDP packet every ~1s on port 3333 with the
/// format: "name,ip,port,busy" (busy is "1" or "0").
/// See: Carvera_Controller/carveracontroller/WIFIStream.py -> MachineDetector
public struct MakeraMachine: Identifiable, Equatable, Hashable {
    public let id: String   // name+ip is stable enough to dedupe on
    public let name: String
    public let ip: String
    public let port: UInt16
    public let busy: Bool

    // Identity is `id` only. Discovery refreshes `busy` every second; with
    // synthesized conformances the refreshed value would no longer equal the
    // one held by a `Picker`/`List` selection, which then shows no selection
    // and fires spurious `onChange`s (disconnect + reconnect).
    public static func == (lhs: MakeraMachine, rhs: MakeraMachine) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(name: String, ip: String, port: UInt16, busy: Bool) {
        self.name = name
        self.ip = ip
        self.port = port
        self.busy = busy
        self.id = "\(name)@\(ip)"
    }
}

extension MakeraMachine {
    /// A fake machine that's always available to pick from
    /// `MachinesList`/`MachineConnectSheet`, so the UI — connecting,
    /// jogging, probing, the pre-run review, uploading and running a job —
    /// can be exercised without real hardware. `MachineDiscovery` seeds its
    /// list with exactly this value, and `MachineConnection.connect(to:)`
    /// checks `isMock` to route to `MockMachineSimulator` instead of
    /// opening a real socket.
    public static let mock = MakeraMachine(name: "Mock Machine", ip: "00.00.00.00", port: 0, busy: false)

    /// The sentinel IP `.mock` uses is never a routable address, so it's
    /// safe as the marker — checked by IP/port rather than `self == .mock`
    /// so it still recognises the entry after `MachineDiscovery` overwrites
    /// `busy` on a refresh (structural `Equatable` would otherwise stop
    /// matching the moment any field differs).
    public var isMock: Bool { ip == MakeraMachine.mock.ip && port == MakeraMachine.mock.port }
}
