import Foundation

/// Transport state from Logic Pro.
struct TransportState: Sendable, Codable {
    var isPlaying: Bool = false
    var isRecording: Bool = false
    var isPaused: Bool = false
    var isCycleEnabled: Bool = false
    var isMetronomeEnabled: Bool = false
    var tempo: Double = 120.0
    var position: String = "1.1.1.1"  // Bar.Beat.Division.Tick
    var timePosition: String = "00:00:00.000"
    var sampleRate: Int = 44100
    var lastUpdated: Date = .distantPast
}

/// Track types in Logic Pro.
enum TrackType: String, Sendable, Codable {
    case audio
    case softwareInstrument = "software_instrument"
    case drummer
    case externalMIDI = "external_midi"
    case aux
    case bus
    case master
    case unknown
}

/// A single track's state.
struct TrackState: Sendable, Codable, Identifiable {
    let id: Int          // 0-based index
    var name: String
    var type: TrackType
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var isArmed: Bool = false
    var isSelected: Bool = false
    var volume: Double = 0.0   // dB, 0 = unity
    var pan: Double = 0.0      // -1.0 (L) to 1.0 (R)
    var color: String?
    /// Output routing label (e.g. "Stereo Out", "Bus 1"). Populated via AX inspection.
    var outputRouting: String?
    /// Nesting depth in the arrange window (0 = top-level). Populated by AX live discovery.
    var nestingDepth: Int = 0
}

/// A live track record read directly from the AX tree of the arrange window.
/// Richer than TrackState — includes nesting depth for hierarchy inference.
struct LiveTrackInfo: Sendable, Codable {
    /// 0-based display index in the arrange window.
    var index: Int
    /// Track name as shown in the arrange window header.
    var name: String
    /// Track type inferred from AX roles/descriptions.
    var type: TrackType = .unknown
    /// True when the mute button is active.
    var isMuted: Bool = false
    /// True when the solo button is active.
    var isSoloed: Bool = false
    /// True when the record-arm button is active.
    var isArmed: Bool = false
    /// True when this track is selected in the arrange window.
    var isSelected: Bool = false
    /// Nesting depth in the track stack hierarchy (0 = root level, 1 = child, etc.).
    var nestingDepth: Int = 0
    /// Output routing label if readable from AX.
    var outputRouting: String?
}

/// Mixer channel strip state (extends track with routing info).
struct ChannelStripState: Sendable, Codable {
    var trackIndex: Int
    var volume: Double = 0.0
    var pan: Double = 0.0
    var sends: [SendState] = []
    var input: String?
    var output: String?
    var eqEnabled: Bool = false
    var plugins: [PluginSlotState] = []
}

/// A send on a channel strip.
struct SendState: Sendable, Codable {
    var index: Int
    var destination: String
    var level: Double
    var isPreFader: Bool
}

/// A plugin slot.
struct PluginSlotState: Sendable, Codable {
    var index: Int
    var name: String
    var isBypassed: Bool
}

/// Region info.
struct RegionState: Sendable, Codable, Identifiable {
    let id: String
    var name: String
    var trackIndex: Int
    var startPosition: String   // Bar.Beat
    var endPosition: String
    var length: String
    var isSelected: Bool = false
    var isLooped: Bool = false
}

/// Marker info.
struct MarkerState: Sendable, Codable, Identifiable {
    let id: Int
    var name: String
    /// Bar position as a string (e.g. "1.1.1.1" or "Verse").
    var position: String
    /// Bar number extracted from position, if available (1-based).
    var bar: Int?
}

/// Automation mode.
enum AutomationMode: String, Sendable, Codable {
    case off
    case read
    case touch
    case latch
    case write
}

/// Project-level info.
struct ProjectInfo: Sendable, Codable {
    var name: String = ""
    var sampleRate: Int = 44100
    var bitDepth: Int = 24
    var tempo: Double = 120.0
    var timeSignature: String = "4/4"
    var trackCount: Int = 0
    var filePath: String?
    var lastUpdated: Date = .distantPast
}
