import Foundation

// MARK: - Top-level result

/// Full parsed result from a Logic Pro ProjectData binary file.
struct ProjectDataInfo: Sendable, Codable {
    /// Arrangement markers with names and bar positions.
    var markers: [ParsedMarker] = []
    /// Tempo map entries (may have multiple for tempo changes).
    var tempoMap: [TempoEntry] = []
    /// Track names extracted from MSeq chunks.
    var tracks: [ParsedTrack] = []
    /// Time signature string (e.g. "4/4"), sourced from plists in the package.
    var timeSignature: String = "4/4"
    /// Sample rate from project plist (0 if unavailable).
    var sampleRate: Int = 0
    /// Project name derived from the .logicx directory name.
    var projectName: String = ""
}

// MARK: - Arrangement Markers

/// An arrangement marker parsed from TxSq (name) and EvSq type-18 (position).
struct ParsedMarker: Sendable, Codable {
    /// Human-readable marker name (RTF-stripped).
    var name: String
    /// Bar number (1-based). Computed from tick / 3840 + 1 in 4/4.
    var bar: Int
    /// Absolute tick position.
    var tick: Int
    /// Duration in ticks (from the type-18 row).
    var durationTicks: Int
    /// Duration in bars (durationTicks / 3840, rounded).
    var durationBars: Int
    /// Object identifier from the TxSq chunk header.
    var oid: Int
}

// MARK: - Tempo Map

/// A single tempo entry from an EvSq chunk.
struct TempoEntry: Sendable, Codable {
    /// Beats per minute.
    var bpm: Double
    /// Absolute tick position of this tempo event.
    var tick: Int
    /// Bar number (1-based), computed from tick / 3840 + 1.
    var bar: Int
}

// MARK: - Tracks

/// A track name parsed from an MSeq chunk.
struct ParsedTrack: Sendable, Codable {
    /// Track name (ASCII).
    var name: String
    /// Object identifier from the MSeq chunk header.
    var oid: Int
}
