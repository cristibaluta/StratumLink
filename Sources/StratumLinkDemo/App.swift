//
//  App.swift
//  StratumLinkDemo
//
//  A single-window test bench for the StratumLink library: machine discovery
//  and connection, status, jogging, spindle, probing, ATC, accessories, job
//  upload/run control, MDI terminal and alerts — all wired straight to
//  `MachineSession`, no app logic in between.
//
//  Run with:  swift run StratumLinkDemo
//  Pick "Mock Machine" in the list to try everything without hardware.
//

import SwiftUI
import AppKit

@main
struct StratumLinkDemoApp: App {

    init() {
        // A SwiftPM executable isn't a bundled app: make it a regular,
        // foreground app so the window and keyboard focus work.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("StratumLink Demo") {
            ContentView()
        }
    }
}
