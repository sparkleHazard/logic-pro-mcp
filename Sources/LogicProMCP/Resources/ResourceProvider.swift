import Foundation
import MCP

/// Registers MCP resources for zero-cost state reads.
/// Resources are URI-addressable data pulled on demand — they don't appear in the tool list.
struct ResourceProvider {
    static let resources: [Resource] = [
        Resource(
            name: "Transport State",
            uri: "logic://transport/state",
            description: "Current transport state: playing, recording, tempo, position, cycle, metronome",
            mimeType: "application/json"
        ),
        Resource(
            name: "Tracks",
            uri: "logic://tracks",
            description: "All tracks: name, type (audio/software_instrument/drummer/aux/bus/folder), index, mute/solo/arm states, output routing",
            mimeType: "application/json"
        ),
        Resource(
            name: "Mixer",
            uri: "logic://mixer",
            description: "All channel strips: volume, pan, plugins, sends",
            mimeType: "application/json"
        ),
        Resource(
            name: "Project Info",
            uri: "logic://project/info",
            description: "Project name, tempo, time signature, sample rate, bit depth, track count. Read directly from Logic Pro via AX for freshness.",
            mimeType: "application/json"
        ),
        Resource(
            name: "Markers",
            uri: "logic://markers",
            description: "All arrangement markers: name, bar position (1-based), position string. Read via Accessibility API.",
            mimeType: "application/json"
        ),
        Resource(
            name: "MIDI Ports",
            uri: "logic://midi/ports",
            description: "Available MIDI ports (system + virtual)",
            mimeType: "application/json"
        ),
        Resource(
            name: "System Health",
            uri: "logic://system/health",
            description: "Channel status, cache freshness, permission state",
            mimeType: "application/json"
        ),
    ]

    static let templates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: "logic://tracks/{index}",
            name: "Track Detail",
            description: "Single track detail by index (including type, mute/solo/arm, output routing)",
            mimeType: "application/json"
        ),
    ]
}
