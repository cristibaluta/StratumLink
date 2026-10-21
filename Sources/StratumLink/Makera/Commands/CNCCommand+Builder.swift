
import Foundation

public struct RapidMoveBuilder {
    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil, a: Double? = nil, feed: Double? = nil) -> CNCCommand {
        .rapidMove(x: x, y: y, z: z, a: a, feed: feed)
    }
}

public struct LinearMoveBuilder {
    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil, a: Double? = nil, feed: Double? = nil) -> CNCCommand {
        .linearMove(x: x, y: y, z: z, a: a, feed: feed)
    }
}

public enum ArcDirection {
    case clockwise
    case counterClockwise
}

public struct ArcBuilder {
    public let direction: ArcDirection

    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil,
              i: Double? = nil, j: Double? = nil, k: Double? = nil,
              feed: Double? = nil) -> CNCCommand {
        switch direction {
            case .clockwise:
                return .clockwiseArc(x: x, y: y, z: z, i: i, j: j, k: k, feed: feed)
            case .counterClockwise:
                return .counterClockwiseArc(x: x, y: y, z: z, i: i, j: j, k: k, feed: feed)
        }
    }
}

public struct DwellBuilder {
    public func with(seconds: Double) -> CNCCommand {
        .dwell(seconds: seconds)
    }
}

public struct WorkspaceBuilder {
    public func with(workspace: Int, x: Double? = nil, y: Double? = nil, z: Double? = nil) -> CNCCommand {
        .setWorkspaceCoordinates(workspace: workspace, x: x, y: y, z: z)
    }
}

public struct ProbeGridBuilder {
    public func with(r: Int = 1,
              x: Double, y: Double,
              a: Double, b: Double,
              i: Double? = nil, j: Double? = nil,
              h: Double) -> CNCCommand {
        .probeGrid(r: r, x: x, y: y, a: a, b: b, i: i, j: j, h: h)
    }
}

public struct ProbeBuilder {
    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil, feed: Double? = nil) -> CNCCommand {
        .probe(x: x, y: y, z: z, feed: feed)
    }
}

public struct MachineCoordinateBuilder {
    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil, feed: Double? = nil) -> CNCCommand {
        .machineCoordinates(x: x, y: y, z: z, feed: feed)
    }
}

public struct GlobalWorkspaceBuilder {
    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil) -> CNCCommand {
        .setGlobalWorkspace(x: x, y: y, z: z)
    }
}

public struct MachineHomingBuilder {
    public func with(x: Double? = nil, y: Double? = nil, z: Double? = nil) -> CNCCommand {
        .setMachineHoming(x: x, y: y, z: z)
    }
}

public struct SpindleBuilder {
    public func with(rpm: Int) -> CNCCommand {
        .spindleOn(rpm: rpm)
    }
}

public struct ToolChangeBuilder {
    public func with(tool: Int) -> CNCCommand {
        .toolChange(tool: tool)
    }
}

public struct PercentageBuilder: Sendable {
    private let command: @Sendable (Int) -> CNCCommand

    public init(command: @Sendable @escaping (Int) -> CNCCommand) {
        self.command = command
    }

    public func with(percent: Int) -> CNCCommand {
        command(min(max(percent, 0), 100))
    }
}

public struct ATCStatusBuilder {
    public func with(status: ATCStatus) -> CNCCommand {
        .automaticToolChangeStatus(status: status)
    }

    public func with(status: Int) -> CNCCommand {
        guard let status = ATCStatus(rawValue: status) else {
            fatalError("Invalid M497 status: \(status)")
        }

        return .automaticToolChangeStatus(status: status)
    }
}
