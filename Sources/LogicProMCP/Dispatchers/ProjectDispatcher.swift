import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: new, open, save, save_as, close, bounce, bounce_section, bounce_complete, launch, quit, analyze. \
            Params by command: \
            open -> { path: String }; \
            save_as -> { path: String }; \
            bounce -> {} (opens bounce dialog); \
            bounce_section -> { marker_name: String } or { start_bar: Int, end_bar: Int } \
            (sets cycle range to section boundaries, enables cycle, opens bounce dialog); \
            bounce_complete -> { destination: String?, click_bounce: Bool? } \
            (best-effort AX automation of the open bounce dialog: set path, click Bounce); \
            analyze -> { path: String? } (parse ProjectData binary; defaults to current project); \
            launch/quit -> {} (app lifecycle); \
            Others -> {}
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Project command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        axChannel: AccessibilityChannel? = nil
    ) async -> CallTool.Result {
        switch command {
        case "new":
            let result = await router.route(operation: "project.new")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "open":
            let path = params["path"]?.stringValue ?? ""
            guard !path.isEmpty else {
                return CallTool.Result(content: [.text("open requires 'path' param")], isError: true)
            }
            let result = await router.route(
                operation: "project.open",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save":
            let result = await router.route(operation: "project.save")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save_as":
            let path = params["path"]?.stringValue ?? ""
            guard !path.isEmpty else {
                return CallTool.Result(content: [.text("save_as requires 'path' param")], isError: true)
            }
            let result = await router.route(
                operation: "project.save_as",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "close":
            let result = await router.route(operation: "project.close")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "bounce":
            let result = await router.route(operation: "project.bounce")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "bounce_section":
            return await bounceSection(params: params, router: router, cache: cache, axChannel: axChannel)

        case "analyze":
            return analyzeProject(params: params)

        case "bounce_complete":
            return await bounceComplete(params: params, axChannel: axChannel)

        case "launch":
            if ProcessUtils.isLogicProRunning {
                return CallTool.Result(content: [.text("Logic Pro is already running")], isError: false)
            }
            let script = "tell application \"Logic Pro\" to activate"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            do {
                try process.run()
                process.waitUntilExit()
                return CallTool.Result(content: [.text("Logic Pro launched")], isError: false)
            } catch {
                return CallTool.Result(content: [.text("Failed to launch Logic Pro: \(error)")], isError: true)
            }

        case "quit":
            if !ProcessUtils.isLogicProRunning {
                return CallTool.Result(content: [.text("Logic Pro is not running")], isError: false)
            }
            let script = "tell application \"Logic Pro\" to quit"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            do {
                try process.run()
                process.waitUntilExit()
                return CallTool.Result(content: [.text("Logic Pro quit")], isError: false)
            } catch {
                return CallTool.Result(content: [.text("Failed to quit Logic Pro: \(error)")], isError: true)
            }

        default:
            return CallTool.Result(
                content: [.text("Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, bounce_section, bounce_complete, analyze, launch, quit")],
                isError: true
            )
        }
    }

    // MARK: - analyze

    /// Parse the ProjectData binary for the given (or current) Logic Pro project and return
    /// a JSON summary of markers, tempo map, tracks, and project metadata.
    private static func analyzeProject(params: [String: Value]) -> CallTool.Result {
        // Prefer explicitly supplied path; fall back to AppleScript discovery.
        let path: String?
        if let explicit = params["path"]?.stringValue, !explicit.isEmpty {
            path = explicit
        } else {
            path = currentLogicProProjectPath()
        }

        guard let projectPath = path else {
            return CallTool.Result(
                content: [.text("analyze: could not determine project path. Pass 'path' param or ensure Logic Pro is open.")],
                isError: true
            )
        }

        guard let info = ProjectDataParser.parse(path: projectPath) else {
            return CallTool.Result(
                content: [.text("analyze: failed to parse ProjectData at '\(projectPath)'. Check the path and that the file is a valid .logicx project.")],
                isError: true
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(info),
              let json = String(data: data, encoding: .utf8) else {
            return CallTool.Result(
                content: [.text("analyze: failed to encode result as JSON")],
                isError: true
            )
        }

        return CallTool.Result(content: [.text(json)], isError: false)
    }

    // MARK: - bounce_section

    /// Set cycle range to the section boundaries, enable cycle mode, then open the bounce dialog.
    ///
    /// Accepts either:
    ///   - `marker_name`: looks up a marker by name and uses its bar position
    ///   - `start_bar` + `end_bar`: explicit bar range
    private static func bounceSection(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        axChannel: AccessibilityChannel?
    ) async -> CallTool.Result {
        var startBar: Int
        var endBar: Int

        if let markerName = params["marker_name"]?.stringValue {
            // Resolve marker boundaries: find this marker and the next one.
            let markers: [MarkerState]
            if let ax = axChannel, let live = await ax.readMarkersDirect() {
                await cache.updateMarkers(live)
                markers = live
            } else {
                markers = await cache.getMarkers()
            }

            guard let target = markers.first(where: { $0.name.localizedCaseInsensitiveContains(markerName) }) else {
                return CallTool.Result(
                    content: [.text("No marker found matching '\(markerName)'. Use list_markers to see available markers.")],
                    isError: true
                )
            }

            // Extract start bar from marker position
            guard let targetBar = target.bar ?? barFromPositionString(target.position) else {
                return CallTool.Result(
                    content: [.text("Cannot determine bar position for marker '\(target.name)' (position: \(target.position))")],
                    isError: true
                )
            }
            startBar = targetBar

            // End bar: look for the next marker with a higher bar number, or default to start + 8
            let sortedMarkers = markers.compactMap { m -> (bar: Int, marker: MarkerState)? in
                guard let b = m.bar ?? barFromPositionString(m.position) else { return nil }
                return (bar: b, marker: m)
            }.sorted { $0.bar < $1.bar }

            if let nextEntry = sortedMarkers.first(where: { $0.bar > startBar }) {
                endBar = nextEntry.bar
            } else {
                endBar = startBar + 8
            }
        } else if let sb = params["start_bar"]?.intValue, let eb = params["end_bar"]?.intValue {
            startBar = sb
            endBar = eb
        } else {
            return CallTool.Result(
                content: [.text("bounce_section requires 'marker_name' or both 'start_bar' and 'end_bar'")],
                isError: true
            )
        }

        guard endBar > startBar else {
            return CallTool.Result(
                content: [.text("end_bar (\(endBar)) must be greater than start_bar (\(startBar))")],
                isError: true
            )
        }

        // Step 1: Set cycle range
        let cycleResult = await router.route(
            operation: "transport.set_cycle_range",
            params: ["start": "\(startBar).1.1.1", "end": "\(endBar).1.1.1"]
        )
        if !cycleResult.isSuccess {
            return CallTool.Result(
                content: [.text("Failed to set cycle range [\(startBar)-\(endBar)]: \(cycleResult.message)")],
                isError: true
            )
        }

        // Step 2: Enable cycle mode
        let toggleResult = await router.route(operation: "transport.toggle_cycle")
        // Not fatal if this fails — cycle may already be enabled

        // Step 3: Open bounce dialog (Cmd+B)
        let bounceResult = await router.route(operation: "project.bounce_section")
        let cycleNote = toggleResult.isSuccess ? "" : " (cycle toggle may have failed: \(toggleResult.message))"
        let summary = "Cycle set to bars \(startBar)–\(endBar)\(cycleNote). Bounce dialog: \(bounceResult.message)"
        return CallTool.Result(
            content: [.text(summary)],
            isError: !bounceResult.isSuccess
        )
    }

    // MARK: - bounce_complete

    /// Best-effort automation of the bounce dialog opened by bounce_section.
    ///
    /// Uses the Accessibility API to:
    ///   1. Locate the bounce dialog window in Logic Pro.
    ///   2. Optionally set output format controls (WAV 48 kHz 24-bit) via AX.
    ///   3. Optionally set the destination path via an AX text field.
    ///   4. Click the "Bounce" button.
    ///
    /// This is best-effort — the exact AX element structure may change between Logic versions.
    /// If the dialog cannot be found, an error is returned suggesting manual completion.
    ///
    /// Params:
    ///   - destination: Optional output file path to set in the dialog.
    ///   - click_bounce: Bool (default true) — whether to click the Bounce button.
    private static func bounceComplete(
        params: [String: Value],
        axChannel: AccessibilityChannel?
    ) async -> CallTool.Result {
        guard let ax = axChannel else {
            return CallTool.Result(
                content: [.text("bounce_complete requires AX channel (axChannel unavailable)")],
                isError: true
            )
        }

        let destination = params["destination"]?.stringValue
        let shouldClick = params["click_bounce"]?.boolValue ?? true

        // Delegate to the AccessibilityChannel actor
        let result = await ax.completeBounceDialog(destination: destination, clickBounce: shouldClick)
        return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
    }

    /// Parse a bar number from a "Bar.Beat.Division.Tick" or plain integer string.
    private static func barFromPositionString(_ position: String) -> Int? {
        let trimmed = position.trimmingCharacters(in: .whitespaces)
        if let bar = Int(trimmed) { return bar }
        let components = trimmed.components(separatedBy: ".")
        if let first = components.first, let bar = Int(first) { return bar }
        return nil
    }
}
