import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: new, open, save, save_as, close, bounce, bounce_section, bounce_complete, \
            tracks_hierarchy, bounce_stems, song_lengths, launch, quit, analyze. \
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
            groups: [String]?, use_reference_lengths: Bool?, execute: Bool? } \
            (plan or execute per-group stem bounces; use_reference_lengths defaults true); \
            song_lengths -> { path: String? } (per-song lengths from reference track or marker boundaries); \
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
            return await tracksHierarchy(params: params, axChannel: axChannel)

        case "bounce_stems":
            return await bounceStems(params: params, router: router, cache: cache, axChannel: axChannel)

        case "song_lengths":
            return songLengths(params: params)

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
                content: [.text("Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, bounce_section, bounce_complete, tracks_hierarchy, bounce_stems, song_lengths, analyze, launch, quit")],
                isError: true
            )
        }
    }

    // MARK: - tracks_hierarchy

    /// Return the full track tree with stacks, children, and function groups.
    private static func tracksHierarchy(
        params: [String: Value],
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

        // Read live tracks from AX (if Logic is open) for the track index map
        let liveTracks: [LiveTrackInfo]?
        if let ax = axChannel {
            liveTracks = await ax.readLiveTracksDirect()
        } else {
            liveTracks = nil
        }

        // Build Envi name → AX track index map (only when live tracks are available)
        let trackIndexMap: [String: Int]?
        if let live = liveTracks, !live.isEmpty {
            let enviNames = info.environmentLabels
            trackIndexMap = ProjectDataParser.buildTrackIndexMap(enviNames: enviNames, liveTracks: live)
        } else {
            trackIndexMap = nil
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

        var result: [String: Any] = [
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

        // Include trackIndexMap when live tracks are available
        if let indexMap = trackIndexMap, !indexMap.isEmpty {
            result["trackIndexMap"] = indexMap
        }

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
    ///   - use_reference_lengths: Bool (default true) — use reference track region length for the song
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

        // --- Read live tracks from AX (for track index mapping) ---
        let liveTracks: [LiveTrackInfo]?
        if let ax = axChannel {
            liveTracks = await ax.readLiveTracksDirect()
        } else {
            liveTracks = nil
        }

        // Build Envi name → AX track index map
        let trackIndexMap: [String: Int]
        if let live = liveTracks, !live.isEmpty {
            trackIndexMap = ProjectDataParser.buildTrackIndexMap(
                enviNames: info.environmentLabels,
                liveTracks: live
            )
        } else {
            trackIndexMap = [:]
        }

        // --- Resolve section bars ---
        let useReferenceLengths = params["use_reference_lengths"]?.boolValue ?? true

        var startBar: Int
        var endBar: Int
        var markerEndBar: Int   // marker-to-marker boundary (always computed)
        var referenceLength: [String: Any]? = nil

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
                markerEndBar = next.bar
            } else {
                markerEndBar = startBar + target.durationBars
            }

            // Look for a reference-track-derived song length
            if useReferenceLengths,
               let songLen = info.songLengths.first(where: { $0.songName.localizedCaseInsensitiveContains(markerName) })
            {
                endBar = songLen.endBar
                referenceLength = [
                    "startBar": songLen.startBar,
                    "endBar": songLen.endBar,
                    "lengthBars": songLen.lengthBars,
                    "source": songLen.source,
                ]
            } else {
                endBar = markerEndBar
            }
        } else if let sb = params["start_bar"]?.intValue, let eb = params["end_bar"]?.intValue {
            startBar = sb
            endBar = eb
            markerEndBar = eb
        } else {
            // Default: full project (bar 1 to last marker end)
            startBar = 1
            markerEndBar = (info.markers.map { $0.bar + $0.durationBars }.max() ?? 9) + 1
            endBar = markerEndBar
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
            // Channel-strip-based groups (the full sub-tracks)
            for stack in info.subTrackHierarchy {
                if let requested = requestedGroups, !requested.contains(stack.name) { continue }

                // Filter to non-generic strips (they have real content)
                let meaningfulStrips = stack.strips.filter { !$0.isGeneric }
                if meaningfulStrips.isEmpty { continue }

                // Build strip info including AX track indices
                let stripNodes: [[String: Any]] = meaningfulStrips.map { strip -> [String: Any] in
                    var node: [String: Any] = ["name": strip.name]
                    if let axIdx = trackIndexMap[strip.name] {
                        node["trackIndex"] = axIdx
                    }
                    return node
                }

                var groupEntry: [String: Any] = [
                    "name": stack.name,
                    "source": stack.source,
                    "stripOids": meaningfulStrips.map { $0.oid },
                    "stripNames": meaningfulStrips.map { $0.name },
                    "mseqOids": Array(Set(meaningfulStrips.compactMap { $0.mseqOid })).sorted(),
                    "strips": stripNodes,
                ]
                // Collect AX indices for all strips in this group
                let groupAxIndices = meaningfulStrips.compactMap { trackIndexMap[$0.name] }
                if !groupAxIndices.isEmpty {
                    groupEntry["trackIndices"] = groupAxIndices.sorted()
                }
                groups.append(groupEntry)
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
                let stripNodes: [[String: Any]] = members.map { track -> [String: Any] in
                    var node: [String: Any] = ["name": track.name]
                    if let axIdx = trackIndexMap[track.name] {
                        node["trackIndex"] = axIdx
                    }
                    return node
                }
                groups.append([
                    "name": groupName,
                    "source": "function_group_mseq",
                    "stripOids": members.map { $0.oid },
                    "stripNames": members.map { $0.name },
                    "mseqOids": members.map { $0.oid },
                    "strips": stripNodes,
                ])
            }
        }

        // --- Build plan ---
        var plan: [String: Any] = [
            "song": info.projectName,
            "bars": [startBar, endBar],
            "markerBars": [startBar, markerEndBar],
            "channelStripCount": info.channelStrips.count,
            "namedStrips": info.channelStrips.filter { !$0.isGeneric }.count,
            "groups": groups,
        ]

        if let refLen = referenceLength {
            plan["referenceLength"] = refLen
        }

        // Include per-song lengths table
        if !info.songLengths.isEmpty {
            let songLengthsJson = info.songLengths.map { sl -> [String: Any] in
                return [
                    "songName": sl.songName,
                    "startBar": sl.startBar,
                    "endBar": sl.endBar,
                    "lengthBars": sl.lengthBars,
                    "source": sl.source,
                ]
            }
            plan["songLengths"] = songLengthsJson
        }

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

        // Set cycle range using the confirmed-working AX + osascript approach
        let cycleOk = setCycleRange(startBar: startBar, endBar: endBar)
        if cycleOk {
            log.append("  Cycle set to bars \(startBar)–\(endBar)")
        } else {
            log.append("  WARNING: setCycleRange failed for bars \(startBar)–\(endBar)")
        }

        for group in groups {
            guard let groupName = group["name"] as? String else { continue }
            let stripNames = group["stripNames"] as? [String] ?? []
            log.append("  Group '\(groupName)': \(stripNames.joined(separator: ", "))")

            // Clear ALL solos before starting this group (Ctrl+Option+Cmd+S)
            let clearProc = Process()
            clearProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            clearProc.arguments = ["-e", "tell application \"System Events\" to keystroke \"s\" using {command down, option down, control down}"]
            clearProc.standardOutput = FileHandle.nullDevice
            clearProc.standardError = FileHandle.nullDevice
            try? clearProc.run()
            clearProc.waitUntilExit()
            usleep(200_000) // 200ms for Logic to process

            var soloedNames: [String] = []

            if !stripNames.isEmpty {
                // Solo each track: select by name via menu, then osascript keystroke "s"
                for stripName in stripNames {
                    let selected = AccessibilityChannel.selectTrackByNameViaMenu(stripName)
                    if selected {
                        usleep(150_000) // 150 ms — let Logic register the selection
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        proc.arguments = ["-e", "tell application \"System Events\" to keystroke \"s\""]
                        proc.standardOutput = FileHandle.nullDevice
                        proc.standardError = FileHandle.nullDevice
                        do {
                            try proc.run()
                            proc.waitUntilExit()
                            soloedNames.append(stripName)
                            log.append("    Soloed '\(stripName)' via menu search + osascript keystroke s")
                        } catch {
                            log.append("    WARNING: selected '\(stripName)' but osascript keystroke failed: \(error)")
                        }
                    } else {
                        log.append("    WARNING: could not select '\(stripName)' via menu search — skipping solo")
                    }
                }
            } else {
                log.append("    WARNING: no strip names for group '\(groupName)' — cannot solo")
            }

            // Open bounce dialog
            let bounceResult = await router.route(operation: "project.bounce_section")
            log.append("    Bounce dialog: \(bounceResult.message)")

            // Solos will be cleared at the start of the next group iteration
            // (or after the loop ends — add a final clear below)
        }

        // Final clear all solos after last group
        let finalClear = Process()
        finalClear.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        finalClear.arguments = ["-e", "tell application \"System Events\" to keystroke \"s\" using {command down, option down, control down}"]
        finalClear.standardOutput = FileHandle.nullDevice
        finalClear.standardError = FileHandle.nullDevice
        try? finalClear.run()
        finalClear.waitUntilExit()
        log.append("  All solos cleared")

        return CallTool.Result(content: [.text(log.joined(separator: "\n"))], isError: false)
    }

    // MARK: - setCycleRange

    /// Set the Logic Pro cycle range to exact bar positions using the confirmed-working
    /// Navigate > Go To > Position... dialog + locator keyboard shortcuts.
    ///
    /// Steps:
    ///  1. AX menu: Navigate > Go To > Position... (opens Go To Position dialog)
    ///  2. osascript: Cmd+A, type "\(startBar) 1 1 1", Return  (moves playhead)
    ///  3. osascript: Cmd+Ctrl+[  (set left locator to playhead)
    ///  4. Repeat 1–2 for endBar
    ///  5. osascript: Cmd+Ctrl+]  (set right locator to playhead)
    ///  6. osascript: "c"          (enable cycle)
    @discardableResult
    private static func setCycleRange(startBar: Int, endBar: Int) -> Bool {
        func runOsascript(_ script: String) -> Bool {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }

        // Step 1: Open Navigate > Go To > Position...
        let opened1 = AXLogicProElements.clickMenuItem(path: ["Navigate", "Go To", "Position\u{2026}"])
                   || AXLogicProElements.clickMenuItem(path: ["Navigate", "Go To", "Position..."])
        guard opened1 else { return false }
        Thread.sleep(forTimeInterval: 0.5)

        // Step 2: Select all + type start bar position + Return
        let typeStart = """
            tell application "System Events"
                keystroke "a" using {command down}
                keystroke "\(startBar) 1 1 1"
                key code 36
            end tell
            """
        _ = runOsascript(typeStart)
        Thread.sleep(forTimeInterval: 0.5)

        // Step 3: Set left locator (Cmd+Ctrl+[)
        let setLeft = """
            tell application "System Events"
                key code 33 using {command down, control down}
            end tell
            """
        _ = runOsascript(setLeft)
        Thread.sleep(forTimeInterval: 0.3)

        // Step 4: Open Navigate > Go To > Position... again
        let opened2 = AXLogicProElements.clickMenuItem(path: ["Navigate", "Go To", "Position\u{2026}"])
                   || AXLogicProElements.clickMenuItem(path: ["Navigate", "Go To", "Position..."])
        guard opened2 else { return false }
        Thread.sleep(forTimeInterval: 0.5)

        // Step 5: Select all + type end bar position + Return
        let typeEnd = """
            tell application "System Events"
                keystroke "a" using {command down}
                keystroke "\(endBar) 1 1 1"
                key code 36
            end tell
            """
        _ = runOsascript(typeEnd)
        Thread.sleep(forTimeInterval: 0.5)

        // Step 6: Set right locator (Cmd+Ctrl+])
        let setRight = """
            tell application "System Events"
                key code 30 using {command down, control down}
            end tell
            """
        _ = runOsascript(setRight)
        Thread.sleep(forTimeInterval: 0.3)

        // Step 7: Enable cycle (C key)
        let enableCycle = """
            tell application "System Events"
                keystroke "c"
            end tell
            """
        _ = runOsascript(enableCycle)

        return true
    }

    // MARK: - song_lengths

    /// Return per-song lengths derived from the reference track regions (or marker boundaries).
    private static func songLengths(params: [String: Value]) -> CallTool.Result {
        let path: String?
        if let explicit = params["path"]?.stringValue, !explicit.isEmpty {
            path = explicit
        } else {
            path = currentLogicProProjectPath()
        }

        guard let projectPath = path else {
            return CallTool.Result(
                content: [.text("song_lengths: could not determine project path. Pass 'path' param or ensure Logic Pro is open.")],
                isError: true
            )
        }

        guard let info = ProjectDataParser.parse(path: projectPath) else {
            return CallTool.Result(
                content: [.text("song_lengths: failed to parse ProjectData at '\(projectPath)'.")],
                isError: true
            )
        }

        let songLengthsJson: [[String: Any]] = info.songLengths.map { sl in
            return [
                "songName": sl.songName,
                "startBar": sl.startBar,
                "endBar": sl.endBar,
                "lengthBars": sl.lengthBars,
                "source": sl.source,
            ]
        }

        let result: [String: Any] = [
            "project": info.projectName,
            "songCount": songLengthsJson.count,
            "songLengths": songLengthsJson,
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: jsonData, encoding: .utf8) else {
            return CallTool.Result(content: [.text("song_lengths: JSON encoding failed")], isError: true)
        }

        return CallTool.Result(content: [.text(json)], isError: false)
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
