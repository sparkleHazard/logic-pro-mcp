import Foundation
import MCP

/// Handles MCP resource read requests for logic:// URIs.
struct ResourceHandlers {

    /// Handle a ReadResource request by URI.
    ///
    /// - Parameters:
    ///   - axChannel: When provided, resources perform direct synchronous AX reads instead
    ///     of relying solely on the background-polled StateCache. This ensures correct
    ///     results in one-shot / short-lived invocations where the poller hasn't had
    ///     time to warm the cache.
    static func read(
        uri: String,
        cache: StateCache,
        router: ChannelRouter,
        axChannel: AccessibilityChannel? = nil
    ) async throws -> ReadResource.Result {
        await cache.recordToolAccess()

        // Handle parameterized URIs like logic://tracks/{index}
        if uri.hasPrefix("logic://tracks/") {
            let indexStr = String(uri.dropFirst("logic://tracks/".count))
            if let index = Int(indexStr) {
                return try await readTrack(at: index, cache: cache, axChannel: axChannel, uri: uri)
            }
        }

        switch uri {
        case "logic://transport/state":
            return try await readTransportState(cache: cache, axChannel: axChannel, uri: uri)

        case "logic://tracks":
            return try await readTracks(cache: cache, axChannel: axChannel, uri: uri)

        case "logic://tracks/live":
            return try await readLiveTracks(cache: cache, axChannel: axChannel, uri: uri)

        case "logic://mixer":
            return try await readMixer(cache: cache, axChannel: axChannel, uri: uri)

        case "logic://project/info":
            return try await readProjectInfo(cache: cache, axChannel: axChannel, uri: uri)

        case "logic://markers":
            return try await readMarkers(cache: cache, axChannel: axChannel, uri: uri)

        case "logic://midi/ports":
            return try await readMIDIPorts(router: router, uri: uri)

        case "logic://system/health":
            return try await readSystemHealth(cache: cache, router: router, uri: uri)

        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    // MARK: - Individual resource handlers

    private static func readTransportState(
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        // Prefer a direct AX read for freshness; fall back to cache if AX is unavailable.
        let state: TransportState
        if let ax = axChannel, let live = await ax.readTransportStateDirect() {
            await cache.updateTransport(live)
            state = live
        } else {
            state = await cache.getTransport()
        }
        let json = encodeJSON(state)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTracks(
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        let tracks: [TrackState]
        if let ax = axChannel, let live = await ax.readTracksDirect() {
            await cache.updateTracks(live)
            tracks = live
        } else {
            tracks = await cache.getTracks()
        }
        let json = encodeJSON(tracks)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readLiveTracks(
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        // Read full live track list including nesting depth from AX tree.
        if let ax = axChannel, let live = await ax.readLiveTracksDirect() {
            let json = encodeJSON(live)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        // Fallback: standard tracks from cache (no nesting depth)
        let tracks = await cache.getTracks()
        let liveInfos = tracks.map { t in
            LiveTrackInfo(
                index: t.id,
                name: t.name,
                type: t.type,
                isMuted: t.isMuted,
                isSoloed: t.isSoloed,
                isArmed: t.isArmed,
                isSelected: t.isSelected,
                nestingDepth: t.nestingDepth,
                outputRouting: t.outputRouting
            )
        }
        let json = encodeJSON(liveInfos)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTrack(
        at index: Int,
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        // Refresh full track list, then slice the requested index.
        let tracks: [TrackState]
        if let ax = axChannel, let live = await ax.readTracksDirect() {
            await cache.updateTracks(live)
            tracks = live
        } else {
            tracks = await cache.getTracks()
        }
        if tracks.indices.contains(index) {
            let json = encodeJSON(tracks[index])
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        throw MCPError.invalidParams("No track at index \(index)")
    }

    private static func readMixer(
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        let strips: [ChannelStripState]
        if let ax = axChannel, let live = await ax.readMixerDirect() {
            await cache.updateChannelStrips(live)
            strips = live
        } else {
            strips = await cache.getChannelStrips()
        }
        let json = encodeJSON(strips)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readProjectInfo(
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        var info: ProjectInfo
        if let ax = axChannel, let live = await ax.readProjectInfoDirect() {
            // Merge track count from cache when AX doesn't populate it
            let cachedTrackCount = await cache.getTracks().count
            var merged = live
            if merged.trackCount == 0 && cachedTrackCount > 0 {
                merged.trackCount = cachedTrackCount
            }
            await cache.updateProject(merged)
            info = merged
        } else {
            info = await cache.getProject()
        }

        // Enrich with binary-parsed data (tempo, time signature, project name) when available.
        if let projectPath = currentLogicProProjectPath(),
           let parsed = ProjectDataParser.parse(path: projectPath) {
            // Fill in fields that AX may leave empty
            if !parsed.projectName.isEmpty && info.name.isEmpty {
                info.name = parsed.projectName
            }
            if parsed.sampleRate > 0 && info.sampleRate == 0 {
                info.sampleRate = parsed.sampleRate
            }
            if parsed.timeSignature != "4/4" || info.timeSignature == "4/4" {
                info.timeSignature = parsed.timeSignature
            }
            if let first = parsed.tempoMap.first, info.tempo == 120.0 {
                info.tempo = first.bpm
            }
        }

        let json = encodeJSON(info)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readMarkers(
        cache: StateCache,
        axChannel: AccessibilityChannel?,
        uri: String
    ) async throws -> ReadResource.Result {
        // Try binary parser first — it gives richer data (bar, tick, duration) without AX.
        if let projectPath = currentLogicProProjectPath(),
           let parsed = ProjectDataParser.parse(path: projectPath),
           !parsed.markers.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(parsed.markers),
               let json = String(data: data, encoding: .utf8) {
                return ReadResource.Result(
                    contents: [.text(json, uri: uri, mimeType: "application/json")]
                )
            }
        }

        // Fall back to AX / cache
        let markers: [MarkerState]
        if let ax = axChannel, let live = await ax.readMarkersDirect() {
            await cache.updateMarkers(live)
            markers = live
        } else {
            markers = await cache.getMarkers()
        }
        let json = encodeJSON(markers)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readMIDIPorts(router: ChannelRouter, uri: String) async throws -> ReadResource.Result {
        let result = await router.route(operation: "midi.list_ports")
        return ReadResource.Result(
            contents: [.text(result.message, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readSystemHealth(
        cache: StateCache,
        router: ChannelRouter,
        uri: String
    ) async throws -> ReadResource.Result {
        let report = await router.healthReport()
        var channels: [[String: String]] = []
        for (id, health) in report.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            channels.append([
                "channel": id.rawValue,
                "available": String(health.available),
                "latency_ms": health.latencyMs.map { String(format: "%.1f", $0) } ?? "N/A",
                "detail": health.detail,
            ])
        }
        let snap = await cache.snapshot()
        let permissions = PermissionChecker.check()
        let channelsJSON = encodeJSON(channels)
        let json = """
            {
              "logic_pro_running": \(ProcessUtils.isLogicProRunning),
              "channels": \(channelsJSON),
              "cache": {
                "poll_mode": "\(snap.pollMode)",
                "transport_age_sec": \(String(format: "%.1f", snap.transportAge)),
                "track_count": \(snap.trackCount),
                "project": "\(snap.projectName)"
              },
              "permissions": {
                "accessibility": \(permissions.accessibility),
                "automation": \(permissions.automationLogicPro)
              }
            }
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }
}
