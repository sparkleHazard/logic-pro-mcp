import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: new, open, save, save_as, close, bounce, bounce_section, bounce_complete, \
            tracks_hierarchy, bounce_stems, launch, quit, analyze. \
            Params by command: \
            open -> { path: String }; \
            save_as -> { path: String }; \
            bounce -> {} (opens bounce dialog); \
            bounce_section -> { marker_name: String } or { start_bar: Int, end_bar: Int } \
            (sets cycle range to section boundaries, enables cycle, opens bounce dialog); \
            bounce_complete -> { destination: String?, click_bounce: Bool? } \
            (best-effort AX automation of the open bounce dialog: set path, click Bounce); \
            tracks_hierarchy -> { path: String? } (full track tree with stacks and function groups); \
            bounce_stems -> { path: String?, marker_name: String?, start_bar: Int?, end_bar: Int?, \
            groups: [String]?, execute: Bool? } (plan or execute per-group stem bounces); \
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

        case "tracks_hierarchy":
            return tracksHierarchy(params: params)

        case "bounce_stems":
            return await bounceStems(params: params, router: router, cache: cache, axChannel: axChannel)

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
                content: [.text("Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, bounce_section, bounce_complete, tracks_hierarchy, bounce_stems, analyze, launch, quit")],
                isError: true
            )
        }
    }

    // MARK: - tracks_hierarchy

    /// Return the full track tree with stacks, children, and function groups.
    private static func tracksHierarchy(params: [String: Value]) -> CallTool.Result {
        let path: String?
        if let explicit = params["path"]?.stringValue, !explicit.isEmpty {
            path = explicit
        } else {
            path = currentLogicProProjectPath()
        }

        guard let projectPath = path else {
            return CallTool.Result(
                content: [.text("tracks_hierarchy: could not determine project path. Pass 'path' param or ensure Logic Pro is open.")],
                isError: true
            )
        }

        guard let info = ProjectDataParser.parse(path: projectPath) else {
            return CallTool.Result(
                content: [.text("tracks_hierarchy: failed to parse ProjectData at '\(projectPath)'.")],
                isError: true
            )
        }

        // --- Section 1: MSeq-level arrangement tracks (existing) ---
        let tracks = info.tracks
        let oidToTrack: [Int: ParsedTrack] = Dictionary(uniqueKeysWithValues: tracks.map { ($0.oid, $0) })

        func encodeNode(_ t: ParsedTrack) -> [String: Any] {
            var node: [String: Any] = [
                "name": t.name,
                "oid": t.oid,
                "stackDepth": t.stackDepth,
                "isSummingStack": t.isSummingStack,
            ]
            if let fg = t.functionGroup { node["functionGroup"] = fg }
            if let st = t.stackType { node["stackType"] = st }
            if let parent = t.parentOid { node["parentOid"] = parent }
            if !t.childOids.isEmpty {
                let children = t.childOids.compactMap { oidToTrack[$0] }.map { encodeNode($0) }
                node["children"] = children
            }
            return node
        }

        let publicOids = Set(tracks.map { $0.oid })
        let stacks = tracks.filter { t in
            !t.childOids.isEmpty && (t.parentOid == nil || !publicOids.contains(t.parentOid!))
        }.map { encodeNode($0) }

        let ungrouped = tracks.filter { t in
            t.childOids.isEmpty && (t.parentOid == nil || !publicOids.contains(t.parentOid!))
        }.map { t -> [String: Any] in
            var node: [String: Any] = ["name": t.name, "oid": t.oid]
            if let fg = t.functionGroup { node["functionGroup"] = fg }
            return node
        }

        // --- Section 2: Full sub-track hierarchy from AuCO channel strips ---
        let subHierarchy = info.subTrackHierarchy.map { stack -> [String: Any] in
            let stripNodes = stack.strips.map { strip -> [String: Any] in
                var node: [String: Any] = [
                    "name": strip.name,
                    "oid": strip.oid,
                    "isGeneric": strip.isGeneric,
                ]
                if let fg = strip.functionGroup { node["functionGroup"] = fg }
                if let routing = strip.outputRouting { node["outputRouting"] = routing }
                if let vol = strip.volume { node["volumeDB"] = String(format: "%.1f", vol) }
                if let tOid = strip.trakOid { node["trakOid"] = tOid }
                if let mOid = strip.mseqOid { node["mseqOid"] = mOid }
                return node
            }
            return [
                "name": stack.name,
                "source": stack.source,
                "stripCount": stack.strips.count,
                "strips": stripNodes,
            ]
        }

        // --- Counts ---
        let totalStrips = info.channelStrips.count
        let namedStrips = info.channelStrips.filter { !$0.isGeneric }.count
        let envLabels = info.environmentLabels

        let result: [String: Any] = [
            "project": info.projectName,
            "mseqTrackCount": tracks.count,
            "channelStripCount": totalStrips,
            "namedChannelStrips": namedStrips,
            "trakEntryCount": info.trakEntries.count,
            "environmentLabels": envLabels,
            "arrangementTracks": [
                "stacks": stacks,
                "ungrouped": ungrouped,
            ],
            "subTrackHierarchy": subHierarchy,
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: jsonData, encoding: .utf8) else {
            return CallTool.Result(content: [.text("tracks_hierarchy: JSON encoding failed")], isError: true)
        }

        return CallTool.Result(content: [.text(json)], isError: false)
    }

    // MARK: - bounce_stems

    /// Plan (or execute) per-function-group stem bounces for a song section.
    ///
    /// Params:
    ///   - path: .logicx path (optional, auto-detected if omitted)
    ///   - marker_name / start_bar + end_bar: section to bounce
    ///   - groups: array of function group / stack names to include (nil = all)
    ///   - execute: Bool (default false) — when true, solo + bounce each group
    private static func bounceStems(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        axChannel: AccessibilityChannel?
    ) async -> CallTool.Result {
        let path: String?
        if let explicit = params["path"]?.stringValue, !explicit.isEmpty {
            path = explicit
        } else {
            path = currentLogicProProjectPath()
        }

        guard let projectPath = path else {
            return CallTool.Result(
                content: [.text("bounce_stems: could not determine project path.")],
                isError: true
            )
        }

        guard let info = ProjectDataParser.parse(path: projectPath) else {
            return CallTool.Result(
                content: [.text("bounce_stems: failed to parse ProjectData at '\(projectPath)'.")],
                isError: true
            )
        }

        // --- Resolve section bars ---
        var startBar: Int
        var endBar: Int

        if let markerName = params["marker_name"]?.stringValue {
            let sorted = info.markers.sorted { $0.bar < $1.bar }
            guard let target = sorted.first(where: { $0.name.localizedCaseInsensitiveContains(markerName) }) else {
                return CallTool.Result(
                    content: [.text("bounce_stems: no marker matching '\(markerName)'.")],
                    isError: true
                )
            }
            startBar = target.bar
            if let next = sorted.first(where: { $0.bar > startBar }) {
                endBar = next.bar
            } else {
                endBar = startBar + target.durationBars
            }
        } else if let sb = params["start_bar"]?.intValue, let eb = params["end_bar"]?.intValue {
            startBar = sb; endBar = eb
        } else {
            // Default: full project (bar 1 to last marker end)
            startBar = 1
            endBar = (info.markers.map { $0.bar + $0.durationBars }.max() ?? 9) + 1
        }

        // --- Build stem groups from sub-track hierarchy (channel strips) ---
        let requestedGroups: Set<String>?
        if let gArr = params["groups"],
           case let Value.array(gVals) = gArr {
            requestedGroups = Set(gVals.compactMap { $0.stringValue })
        } else {
            requestedGroups = nil
        }

        // Use subTrackHierarchy as primary source (channel strips grouped by stack/function group)
        // Fall back to MSeq-based grouping if no channel strips found
        var groups: [[String: Any]] = []

        if !info.subTrackHierarchy.isEmpty {
            // Channel-strip-based groups (the full 449 sub-tracks)
            for stack in info.subTrackHierarchy {
                if let requested = requestedGroups, !requested.contains(stack.name) { continue }

                // Filter to non-generic strips (they have real content)
                let meaningfulStrips = stack.strips.filter { !$0.isGeneric }
                if meaningfulStrips.isEmpty { continue }

                groups.append([
                    "name": stack.name,
                    "source": stack.source,
                    "stripOids": meaningfulStrips.map { $0.oid },
                    "stripNames": meaningfulStrips.map { $0.name },
                    "mseqOids": Array(Set(meaningfulStrips.compactMap { $0.mseqOid })).sorted(),
                ])
            }
        } else {
            // Fallback: group MSeq tracks by function group (legacy behaviour)
            var groupMap: [String: [ParsedTrack]] = [:]
            for track in info.tracks {
                guard let group = track.functionGroup else { continue }
                if let requested = requestedGroups, !requested.contains(group) { continue }
                groupMap[group, default: []].append(track)
            }
            for groupName in groupMap.keys.sorted() {
                let members = groupMap[groupName]!
                groups.append([
                    "name": groupName,
                    "source": "function_group_mseq",
                    "stripOids": members.map { $0.oid },
                    "stripNames": members.map { $0.name },
                    "mseqOids": members.map { $0.oid },
                ])
            }
        }

        let plan: [String: Any] = [
            "song": info.projectName,
            "bars": [startBar, endBar],
            "channelStripCount": info.channelStrips.count,
            "namedStrips": info.channelStrips.filter { !$0.isGeneric }.count,
            "groups": groups,
        ]

        let execute = params["execute"]?.boolValue ?? false
        guard execute else {
            // Return plan only
            guard let jsonData = try? JSONSerialization.data(
                withJSONObject: plan,
                options: [.prettyPrinted, .sortedKeys]
            ), let json = String(data: jsonData, encoding: .utf8) else {
                return CallTool.Result(content: [.text("bounce_stems: JSON encoding failed")], isError: true)
            }
            return CallTool.Result(content: [.text(json)], isError: false)
        }

        // --- Execute: for each group, solo those tracks → set cycle → bounce → unsolo ---
        var log: [String] = ["bounce_stems executing for bars \(startBar)–\(endBar):"]

        // Set cycle range first
        let cycleResult = await router.route(
            operation: "transport.set_cycle_range",
            params: ["start": "\(startBar).1.1.1", "end": "\(endBar).1.1.1"]
        )
        if !cycleResult.isSuccess {
            log.append("  WARNING: set cycle range failed: \(cycleResult.message)")
        } else {
            log.append("  Cycle set to bars \(startBar)–\(endBar)")
        }
        _ = await router.route(operation: "transport.toggle_cycle")

        for group in groups {
            guard let groupName = group["name"] as? String,
                  let oids = group["stripOids"] as? [Int],
                  let names = group["stripNames"] as? [String] else { continue }

            log.append("  Group '\(groupName)': \(names.joined(separator: ", "))")

            // Solo tracks by index — use MSeq track indices where available,
            // falling back to position in the public tracks array for OID proximity
            var soloedIndices: [Int] = []
            let mseqOids = (group["mseqOids"] as? [Int]) ?? oids
            for (trackIdx, track) in info.tracks.enumerated() where mseqOids.contains(track.oid) {
                let soloResult = await router.route(
                    operation: "track.set_solo",
                    params: ["index": "\(trackIdx)", "enabled": "true"]
                )
                if soloResult.isSuccess {
                    soloedIndices.append(trackIdx)
                } else {
                    log.append("    WARNING: solo track \(trackIdx) (\(track.name)) failed: \(soloResult.message)")
                }
            }

            // Open bounce dialog
            let bounceResult = await router.route(operation: "project.bounce_section")
            log.append("    Bounce dialog: \(bounceResult.message)")

            // Un-solo
            for idx in soloedIndices {
                _ = await router.route(
                    operation: "track.set_solo",
                    params: ["index": "\(idx)", "enabled": "false"]
                )
            }
        }

        return CallTool.Result(content: [.text(log.joined(separator: "\n"))], isError: false)
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
