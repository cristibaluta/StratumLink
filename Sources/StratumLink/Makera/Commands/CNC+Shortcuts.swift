//
//  CNC.swift
//  MakeraStudio Lite
//
//  Created by Cristian Baluta on 19.08.2026.
//

import Foundation

// Shortcuts to CNC commands

public enum CNC {

    // MARK: Motion

    public static let rapidMove = RapidMoveBuilder()
    public static let linearMove = LinearMoveBuilder()
    public static let clockwiseArc = ArcBuilder(direction: .clockwise)
    public static let counterClockwiseArc = ArcBuilder(direction: .counterClockwise)

    // MARK: Timing

    public static let dwell = DwellBuilder()

    // MARK: Coordinates

    public static let setWorkspaceCoordinates = WorkspaceBuilder()
    public static let probeGrid = ProbeGridBuilder()
    public static let probe = ProbeBuilder()
    public static let machineCoordinates = MachineCoordinateBuilder()
    public static let setGlobalWorkspace = GlobalWorkspaceBuilder()
    public static let setMachineHoming = MachineHomingBuilder()

    // MARK: Spindle

    public static let spindleOn = SpindleBuilder()

    // MARK: Tool

    public static let toolChange = ToolChangeBuilder()

    // MARK: Overrides

    public static let feedOverride = PercentageBuilder(command: { .feedOverride(percent: $0) })
    public static let spindleSpeedOverride = PercentageBuilder(command: { .spindleSpeedOverride(percent: $0) })
    public static let laserPowerOverride = PercentageBuilder(command: { .laserPowerOverride(percent: $0) })

    // MARK: ATC

    public static let automaticToolChangeStatus = ATCStatusBuilder()

    // MARK: Vacuum

    public static let internalVacuumOn = PercentageBuilder(command: { .internalVacuumOn(percent: $0) })

    // MARK: Cooling

    public static let spindleCoolingFanOn = PercentageBuilder(command: { .spindleCoolingFanOn(percent: $0) })

    // MARK: Extended Port

    public static let extendedPortOn = PercentageBuilder(command: { .extendedPortOn(percent: $0) })

    // MARK: Parameterless Commands

    public static let selectXYZPlane = CNCCommand.selectXYZPlane
    public static let selectXZYPlane = CNCCommand.selectXZYPlane
    public static let selectYZXPlane = CNCCommand.selectYZXPlane

    public static let inchMode = CNCCommand.inchMode
    public static let millimeterMode = CNCCommand.millimeterMode

    public static let clearancePosition = CNCCommand.clearancePosition

    public static let workspaceG54 = CNCCommand.workspaceG54

    public static let absoluteMode = CNCCommand.absoluteMode
    public static let relativeMode = CNCCommand.relativeMode

    public static let spindleOff = CNCCommand.spindleOff

    public static let airflowOn = CNCCommand.airflowOn
    public static let airflowOff = CNCCommand.airflowOff

    public static let programEnd = CNCCommand.programEnd
    public static let spindleTemperature = CNCCommand.spindleTemperature

    public static let enterLaserMode = CNCCommand.enterLaserMode
    public static let exitLaserMode = CNCCommand.exitLaserMode

    public static let enterLaserTestMode = CNCCommand.enterLaserTestMode
    public static let exitLaserTestMode = CNCCommand.exitLaserTestMode

    public static let automaticVacuumOn = CNCCommand.automaticVacuumOn
    public static let automaticVacuumOff = CNCCommand.automaticVacuumOff

    public static let clearBedLeveling = CNCCommand.clearBedLeveling
    public static let displayBedLevelingGrid = CNCCommand.displayBedLevelingGrid

    public static let deviceMACAddress = CNCCommand.deviceMACAddress
    public static let deviceIPAddress = CNCCommand.deviceIPAddress

    public static let automaticToolChangerHome = CNCCommand.automaticToolChangerHome

    public static let tightenSpindleCollet = CNCCommand.tightenSpindleCollet

    public static let loosenSpindleCollet = CNCCommand.loosenSpindleCollet

    public static let calibrateTool = CNCCommand.calibrateTool

    public static let pause = CNCCommand.pause

    public static let internalVacuumOff = CNCCommand.internalVacuumOff

    public static let spindleCoolingFanOff = CNCCommand.spindleCoolingFanOff

    public static let lightOn = CNCCommand.lightOn
    public static let lightOff = CNCCommand.lightOff

    public static let toolDetectorLaserOn = CNCCommand.toolDetectorLaserOn

    public static let toolDetectorLaserOff = CNCCommand.toolDetectorLaserOff

    public static let wirelessProbeChargingOn = CNCCommand.wirelessProbeChargingOn

    public static let wirelessProbeChargingOff = CNCCommand.wirelessProbeChargingOff

    public static let extendedPortOff = CNCCommand.extendedPortOff

    public static let beepOn = CNCCommand.beepOn
    public static let beepOff = CNCCommand.beepOff
}
