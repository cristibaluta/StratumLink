//
//  SL.swift
//  StratumLink
//

import Foundation

/// The StratumLink namespace
/// Hosts should refer to the library's types as `SL.Session`, `SL.Connection`,
/// and so on.
public enum SL {

    // MARK: Session
    public typealias Session = MachineSession
    public typealias RunOptions = MachineRunOptions
    public typealias SessionEvent = MachineSessionEvent
    public typealias Alert = MachineAlert
    public typealias AlertRules = MachineAlertRules

    // MARK: Connection
    public typealias Connection = MachineConnection
    public typealias Discovery = MachineDiscovery
    public typealias RealtimeCommand = MachineRealtimeCommand
    public typealias ConnectionError = MachineConnectionError

    // MARK: Makera
    public typealias MakeraMachine = StratumLink.MakeraMachine
    public typealias MakeraStatus = MakeraMachineStatus
    public typealias MakeraPlayback = StratumLink.MakeraPlayback
    public typealias MakeraWireProtocol = StratumLink.MakeraWireProtocol

    // MARK: G-code
    public typealias Uploader = GCodeUploader
    public typealias JobRunner = GCodeJobRunner
    public typealias Bounds = GCodeBounds

    // MARK: Machine files & info
    public typealias Info = MachineInfo
    public typealias FileEntry = MachineFileEntry
    public typealias Downloader = MachineFileDownloader

    // MARK: Commands
    public typealias Command = CNCCommand
    public typealias ATCStatus = StratumLink.ATCStatus
}
