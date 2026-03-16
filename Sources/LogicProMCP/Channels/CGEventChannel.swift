import CoreGraphics
import Foundation

/// Channel that sends keyboard shortcuts to Logic Pro via CGEvent.
/// Uses CGEvent.postToPid() to deliver keystrokes directly without requiring window focus.
/// This is the primary channel for transport control and editing operations.
actor CGEventChannel: Channel {
    let id: ChannelID = .cgEvent

    /// A keyboard shortcut definition.
    private struct Shortcut: Sendable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags

        static func key(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [])
        }

        static func cmd(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskCommand)
        }

        static func cmdShift(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskShift])
        }

        static func option(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskAlternate)
        }

        static func cmdOption(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskAlternate])
        }
    }

    /// Mapping from operation strings to keyboard shortcuts.
    /// Key codes: https://developer.apple.com/documentation/coregraphics/cgkeycode
    private static let keyMap: [String: Shortcut] = [
        // Transport
        "transport.play":             .key(49),         // Space
        "transport.stop":             .key(49),         // Space (toggles)
        "transport.record":           .key(15),         // R
        "transport.pause":            .key(49),         // Space
        "transport.rewind":           .key(123),        // Left arrow
        "transport.fast_forward":     .key(124),        // Right arrow
        "transport.toggle_cycle":     .key(8),          // C
        "transport.toggle_metronome": .key(40),         // K
        "transport.toggle_count_in":  .key(39),         // ' (apostrophe — Logic default for Count In)
        "transport.goto_position":    .key(47),         // / (opens Go To Position)

        // Editing
        "edit.undo":                  .cmd(6),          // Cmd+Z
        "edit.redo":                  .cmdShift(6),     // Cmd+Shift+Z
        "edit.cut":                   .cmd(7),          // Cmd+X
        "edit.copy":                  .cmd(8),          // Cmd+C
        "edit.paste":                 .cmd(9),          // Cmd+V
        "edit.delete":                .key(51),         // Delete
        "edit.select_all":            .cmd(0),          // Cmd+A
        "edit.split":                 .cmd(17),         // Cmd+T

        // Views
        "view.toggle_mixer":          .key(7),          // X
        "view.toggle_piano_roll":     .key(35),         // P
        "view.toggle_library":        .key(16),         // Y
        "view.toggle_inspector":      .key(34),         // I
        "view.toggle_score_editor":   .cmdOption(35),   // Cmd+Option+P (approximate)
        "view.toggle_step_editor":    .cmdOption(34),   // Cmd+Option+I (approximate)

        // Project
        "project.save":               .cmd(1),          // Cmd+S
        "project.save_as":            .cmdShift(1),     // Cmd+Shift+S
        "project.close":              .cmd(13),         // Cmd+W
        "project.bounce":             .cmd(11),         // Cmd+B
        "project.bounce_section":     .cmd(11),         // Cmd+B (bounce dialog)

        // Track creation
        "track.create_audio":         .cmdOption(0),    // Option+Cmd+A (approximate)
        "track.create_instrument":    .cmdOption(1),    // Option+Cmd+S (approximate)
        "track.create_drummer":       .cmdOption(6),    // (approximate)
        "track.duplicate":            .cmd(2),          // Cmd+D
        "track.delete":               .cmd(51),         // Cmd+Delete

        // Navigation
        "nav.create_marker":          .cmdOption(39),   // (approximate)
        "nav.zoom_to_fit":            .key(6),          // Z
        "edit.join":                  .cmd(38),         // Cmd+J
        "edit.quantize":              .key(44),         // Q (approximate)
        "edit.bounce_in_place":       .cmdOption(11),   // (approximate)

        // Automation
        "automation.toggle_view":     .key(0),          // A
    ]

    func start() async throws {
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at CGEvent channel start", subsystem: "cgEvent")
            return
        }
        Log.info("CGEvent channel started", subsystem: "cgEvent")
    }

    func stop() async {
        Log.info("CGEvent channel stopped", subsystem: "cgEvent")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard let pid = ProcessUtils.logicProPID() else {
            return .error("Logic Pro is not running")
        }

        // Special multi-step operations that can't be handled by the flat keyMap
        switch operation {
        case "track.select":
            return selectTrackByIndex(params: params, pid: pid)
        case "track.set_mute":
            return setTrackToggle(params: params, pid: pid, key: 46)   // M
        case "track.set_solo":
            return setTrackToggle(params: params, pid: pid, key: 1)    // S
        case "track.set_arm":
            return setTrackToggle(params: params, pid: pid, key: 15)   // R
        default:
            break
        }

        guard let shortcut = Self.keyMap[operation] else {
            return .error("No keyboard shortcut mapped for: \(operation)")
        }

        let sent = postKeyEvent(keyCode: shortcut.keyCode, flags: shortcut.flags, pid: pid)
        if sent {
            return .success("{\"operation\":\"\(operation)\",\"sent\":true}")
        } else {
            return .error("Failed to post CGEvent for \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        guard ProcessUtils.logicProPID() != nil else {
            return .unavailable("Cannot determine Logic Pro PID")
        }
        return .healthy(detail: "CGEvent ready")
    }

    // MARK: - Track Selection & Toggle via Keyboard

    /// Select a track by index using keyboard navigation.
    ///
    /// Logic Pro lets you navigate tracks with Up/Down arrow keys. This selects
    /// the track at `index` by first pressing Cmd+Up (go to first track) and
    /// then pressing Down `index` times.
    ///
    /// Key codes: Up=126, Down=125, Cmd+Up=first track (Logic shortcut).
    private func selectTrackByIndex(params: [String: String], pid: pid_t) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr), index >= 0 else {
            return .error("Missing or invalid 'index' parameter for track.select")
        }

        // Cmd+Up navigates to the first (top) track in Logic Pro
        _ = postKeyEvent(keyCode: 126, flags: .maskCommand, pid: pid)
        // Small delay to allow Logic to process the navigation
        Thread.sleep(forTimeInterval: 0.05)

        // Press Down arrow `index` times to reach the desired track
        for _ in 0..<index {
            _ = postKeyEvent(keyCode: 125, flags: [], pid: pid)
        }

        return .success("{\"selected\":\(index),\"via\":\"cgEvent\"}")
    }

    /// Select a track by index and then toggle mute/solo/arm via the corresponding key.
    ///
    /// - Parameters:
    ///   - key: Key code for M (mute=46), S (solo=1), or R (arm=15).
    private func setTrackToggle(params: [String: String], pid: pid_t, key: CGKeyCode) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr), index >= 0 else {
            return .error("Missing or invalid 'index' parameter")
        }

        // First navigate to the track
        let selectResult = selectTrackByIndex(params: params, pid: pid)
        guard selectResult.isSuccess else { return selectResult }

        // Brief pause so Logic registers the track selection before we toggle
        Thread.sleep(forTimeInterval: 0.08)

        // Press the toggle key
        let toggled = postKeyEvent(keyCode: key, flags: [], pid: pid)
        guard toggled else {
            return .error("Failed to post toggle key \(key) to Logic Pro")
        }

        let keyName: String
        switch key {
        case 46: keyName = "Mute"
        case 1:  keyName = "Solo"
        case 15: keyName = "Arm"
        default: keyName = "Key\(key)"
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(keyName)\",\"via\":\"cgEvent\"}")
    }

    /// Post a key-down/key-up pair to a specific PID.
    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error("Failed to create CGEventSource", subsystem: "cgEvent")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("Failed to create CGEvent for keyCode \(keyCode)", subsystem: "cgEvent")
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags

        // Post to HID system tap (mimics physical keyboard) rather than postToPid.
        // postToPid bypasses the window focus chain, so focus-dependent shortcuts
        // like S (solo), M (mute), C (cycle) don't work. HID posting goes through
        // the normal event dispatch and reaches the focused responder.
        keyDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between key down and up for reliability
        keyUp.post(tap: .cghidEventTap)

        Log.debug("Posted key \(keyCode) flags \(flags.rawValue) via HID tap", subsystem: "cgEvent")
        return true
    }
}
