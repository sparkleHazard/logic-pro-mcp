import Foundation
import MCP

struct NavigateDispatcher {
    static let tool = Tool(
        name: "logic_navigate",
        description: """
            Navigation and markers in Logic Pro. \
            Commands: goto_bar, goto_marker, create_marker, delete_marker, \
            rename_marker, list_markers, zoom_to_fit, set_zoom, toggle_view. \
            Params by command: \
            goto_bar -> { bar: Int }; \
            goto_marker -> { index: Int } or { name: String }; \
            create_marker -> { name: String } (at current playhead); \
            rename_marker -> { index: Int, name: String }; \
            delete_marker -> { index: Int }; \
            list_markers -> {} (returns all markers with name and bar position); \
            set_zoom -> { level: String } ("in", "out", "fit"); \
            toggle_view -> { view: String } ("mixer", "piano_roll", "score", \
            "step_editor", "library", "inspector", "automation")
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Navigation command to execute"),
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
        case "goto_bar":
            let bar = params["bar"]?.intValue ?? 1
            let result = await router.route(
                operation: "nav.goto_bar",
                params: ["bar": String(bar)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "goto_marker":
            if let index = params["index"]?.intValue {
                let result = await router.route(
                    operation: "nav.goto_marker",
                    params: ["index": String(index)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            if let name = params["name"]?.stringValue {
                // Prefer a fresh AX read so name-based lookup works in one-shot mode.
                let markers: [MarkerState]
                if let ax = axChannel, let live = await ax.readMarkersDirect() {
                    await cache.updateMarkers(live)
                    markers = live
                } else {
                    markers = await cache.getMarkers()
                }
                if let marker = markers.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "nav.goto_marker",
                        params: ["index": String(marker.id)]
                    )
                    return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
                }
                return CallTool.Result(
                    content: [.text("No marker found matching '\(name)'. Use list_markers to see available markers.")],
                    isError: true
                )
            }
            return CallTool.Result(content: [.text("goto_marker requires 'index' or 'name' param")], isError: true)

        case "list_markers":
            // Try binary parser first for richer data (bar, tick, duration).
            if let projectPath = currentLogicProProjectPath(),
               let parsed = ProjectDataParser.parse(path: projectPath),
               !parsed.markers.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(parsed.markers),
                   let json = String(data: data, encoding: .utf8) {
                    return CallTool.Result(content: [.text(json)], isError: false)
                }
            }

            // Fall back to direct AX read, then cache.
            let markers: [MarkerState]
            if let ax = axChannel, let live = await ax.readMarkersDirect() {
                await cache.updateMarkers(live)
                markers = live
            } else {
                markers = await cache.getMarkers()
            }
            if markers.isEmpty {
                return CallTool.Result(
                    content: [.text("{\"markers\":[],\"note\":\"No markers found — is a project with markers open?\"}")],
                    isError: false
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(markers),
               let json = String(data: data, encoding: .utf8) {
                return CallTool.Result(content: [.text(json)], isError: false)
            }
            return CallTool.Result(content: [.text("Failed to encode markers")], isError: true)

        case "create_marker":
            let name = params["name"]?.stringValue ?? "Marker"
            let result = await router.route(
                operation: "nav.create_marker",
                params: ["name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "delete_marker":
            let index = params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "nav.delete_marker",
                params: ["index": String(index)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "rename_marker":
            let index = params["index"]?.intValue ?? 0
            let name = params["name"]?.stringValue ?? ""
            let result = await router.route(
                operation: "nav.rename_marker",
                params: ["index": String(index), "name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "zoom_to_fit":
            let result = await router.route(operation: "nav.zoom_to_fit")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_zoom":
            let level = params["level"]?.stringValue ?? "fit"
            switch level {
            case "in":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "8"]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            case "out":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "2"]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            case "fit":
                let result = await router.route(operation: "nav.zoom_to_fit")
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            default:
                // Treat as numeric zoom level
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": level]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }

        case "toggle_view":
            let view = params["view"]?.stringValue ?? "mixer"
            let operation: String
            switch view {
            case "mixer": operation = "view.toggle_mixer"
            case "piano_roll": operation = "view.toggle_piano_roll"
            case "score": operation = "view.toggle_score_editor"
            case "step_editor": operation = "view.toggle_step_editor"
            case "library": operation = "view.toggle_library"
            case "inspector": operation = "view.toggle_inspector"
            case "automation": operation = "automation.toggle_view"
            default:
                return CallTool.Result(
                    content: [.text("Unknown view: \(view). Available: mixer, piano_roll, score, step_editor, library, inspector, automation")],
                    isError: true
                )
            }
            let result = await router.route(operation: operation)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown navigate command: \(command). Available: goto_bar, goto_marker, create_marker, delete_marker, rename_marker, list_markers, zoom_to_fit, set_zoom, toggle_view")],
                isError: true
            )
        }
    }
}
