import AppKit
import Foundation

// Entry point. The command line flags exist so every interesting part of the app
// can be exercised without a person watching: the fold maths, the shader, the
// sensor, and the live capture path each have a headless route.

let arguments = CommandLine.arguments

func flag(_ name: String) -> Bool { arguments.contains(name) }

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.count > index + 1 else { return nil }
    let candidate = arguments[index + 1]
    return candidate.hasPrefix("--") ? nil : candidate
}

if flag("--help") || flag("-h") {
    print(
        """
        RuiC-FoldScreen — Fold Screen

        Usage:
          RuiC-FoldScreen                     launch as a menu bar app
          RuiC-FoldScreen --selftest          run headless self-check (math, shaders, sensor, offscreen rendering)
          RuiC-FoldScreen --sensor            read the lid angle once
          RuiC-FoldScreen --render-frames DIR export fold frames through the real pipeline for manual review
              [--size 960x600] [--steps 7] [--preset 0|1|2] [--hold 0.8] [--cycle] [--no-grain]
          RuiC-FoldScreen --scripted-lid       start with scripted lid angles (no physical lid required)
          RuiC-FoldScreen --smoke              enable the effect and write a self-check report to /tmp after 3 s

        Self-check exits 0 on success.
        """)
    exit(0)
}

if flag("--selftest") {
    let failures = Harness.runSelfTest()
    print(failures == 0 ? "\nSelf-check passed." : "\nSelf-check failed: \(failures) item(s).")
    exit(failures == 0 ? 0 : 1)
}

if flag("--render-frames") {
    exit(Int32(Harness.renderFrames(arguments)))
}

if flag("--sensor") {
    let sensor = HIDLidAngleSource()
    if let angle = sensor.read() {
        print(String(format: "Lid angle: %.0f°", angle))
    } else {
        print("No lid-angle sensor found on this machine.")
        exit(2)
    }
    exit(0)
}

// AppKit must be driven from the main actor. Top level code is nonisolated, so
// the entry into the run loop is spelled out here rather than assumed.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
