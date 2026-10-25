//
//  MachineInfoTests.swift
//  StratumLink
//
//  Created by Cristian Baluta on 25.10.2026.
//

import XCTest
@testable import StratumLink

final class MachineInfoTests: XCTestCase {

    func testParsesFileLine() {
        let e = MachineFileEntry.parse(line: "my part v2.nc 18342 20260920101530", directory: "/sd/gcodes")
        XCTAssertEqual(e?.name, "my part v2.nc")
        XCTAssertEqual(e?.path, "/sd/gcodes/my part v2.nc")
        XCTAssertEqual(e?.size, 18342)
        XCTAssertFalse(e!.isDirectory)
        XCTAssertNotNil(e?.modified)
    }

    func testParsesDirectoryAndIgnoresNoise() {
        XCTAssertTrue(MachineFileEntry.parse(line: "macros/ 0 20260101120000", directory: "/sd/gcodes")!.isDirectory)
        XCTAssertNil(MachineFileEntry.parse(line: "ok", directory: "/sd"))
        XCTAssertNil(MachineFileEntry.parse(line: "version = 1.1.2.0.1.13", directory: "/sd"))
        XCTAssertNil(MachineFileEntry.parse(line: "<Idle|MPos:0,0,0>", directory: "/sd"))
    }

    @MainActor
    func testListingAndVersion() {
        let info = MachineInfo()
        var sent: [String] = []
        info.configure { sent.append($0) }
        info.refresh()
        XCTAssertEqual(sent, ["version", "ls -e -s /sd/gcodes"])
        info.handleMachineLine("version = 1.1.2.0.1.13")
        info.handleMachineLine("b.nc 10 20260101000000")
        info.handleMachineLine("sub/ 0 20260101000000")
        info.handleMachineLine("ok")
        XCTAssertEqual(info.firmwareVersion, "1.1.2.0.1.13")
        XCTAssertEqual(info.files.map(\.name), ["sub", "b.nc"])
        XCTAssertFalse(info.isLoadingFiles)
    }
}
