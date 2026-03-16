import Foundation

// MARK: - ProjectDataParser

/// Parses Logic Pro binary ProjectData files to extract arrangement markers,
/// tempo maps, track names, regions, audio files, plugins, and mixer data —
/// without using the Accessibility API.
///
/// File layout:
/// - Magic:  23 47 C0 AB  (4 bytes at offset 0)
/// - Chunk stream starting at ~0x18
///
/// Each chunk has a 36-byte header:
///   0x00  4B  ID (reversed bytes, e.g. "qSxT" on disk = "TxSq")
///   0x04  6B  metadata/flags
///   0x0A  4B  OID (LE u32)
///   0x0E  8B  padding
///   0x16  6B  anchor: 02 00 00 00 [01|02] 00
///   0x1C  8B  body length (LE u64)
///
/// Chunks are discovered by scanning for the anchor pattern.
enum ProjectDataParser {

    // MARK: - Constants

    private static let magicBytes: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    private static let anchorPrefix: [UInt8] = [0x02, 0x00, 0x00, 0x00]
    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16          // within header
    private static let oidOffset = 0x0A             // within header
    private static let lengthOffset = 0x1C          // within header
    private static let idOffset = 0x00              // within header
    private static let ticksPerBar = 3840           // 4/4 at Logic resolution

    // Chunk IDs (as they appear after reversing the 4 on-disk bytes)
    private static let idTxSq = "TxSq"
    private static let idEvSq = "EvSq"
    private static let idMSeq = "MSeq"
    private static let idAuRg = "AuRg"
    private static let idAuFl = "AuFl"
    private static let idAuCO = "AuCO"

    // Unity gain raw value for volume dB formula: dB = 40 * log10(value / unityGain)
    private static let unityGainRaw: Double = 1_509_949_440.0

    // Arrangement marker OIDs vary per project — we scan ALL TxSq chunks
    // and identify markers by RTF content rather than hardcoded OIDs

    // Tempo event signature: 7F 00 00 01 ...
    private static let tempoSignature: [UInt8] = [0x7F, 0x00, 0x00, 0x01]

    // MARK: - Public API

    /// Parse the ProjectData for a given `.logicx` bundle or raw `ProjectData` file path.
    ///
    /// - Parameter path: Either a `.logicx` directory or a raw `ProjectData` file.
    /// - Returns: Parsed `ProjectDataInfo`, or `nil` if the file cannot be found / validated.
    static func parse(path: String) -> ProjectDataInfo? {
        let url = URL(fileURLWithPath: path)
        let projectDataURL: URL
        let logicxURL: URL?

        if path.hasSuffix(".logicx") || url.pathExtension == "logicx" {
            logicxURL = url
            guard let found = findProjectData(in: url) else { return nil }
            projectDataURL = found
        } else {
            // Treat as raw ProjectData file; walk up to find .logicx for plist parsing
            projectDataURL = url
            logicxURL = findLogicxParent(of: url)
        }

        guard let data = try? Data(contentsOf: projectDataURL) else { return nil }
        guard validateMagic(data) else { return nil }

        let projectName = logicxURL.map { $0.deletingPathExtension().lastPathComponent } ?? ""

        // Scan all chunks
        let chunks = scanChunks(data: data)

        // Extract per-type maps
        let txSqMap = extractTxSqNames(chunks: chunks, data: data)       // oid -> name
        let evSqMarkerEvents = extractMarkerEvents(chunks: chunks, data: data) // [(oid, startTick, durationTicks)]
        var tempoMap = extractTempoMap(chunks: chunks, data: data)
        var parsedTracks = extractTracks(chunks: chunks, data: data)

        // If no tempo found at tick=0, try to get initial BPM from plists
        if let lx = logicxURL, !tempoMap.contains(where: { $0.tick == 0 }) {
            if let plistBPM = readBPMFromPlist(logicx: lx) {
                let initial = TempoEntry(bpm: plistBPM, tick: 0, bar: 1)
                tempoMap.insert(initial, at: 0)
            }
        }

        // Join marker names with positions
        let markers = buildMarkers(txSqMap: txSqMap, events: evSqMarkerEvents)

        // Time signature from plists
        let timeSignature = logicxURL.flatMap { readTimeSignature(logicx: $0) } ?? "4/4"
        let sampleRate = logicxURL.flatMap { readSampleRate(logicx: $0) } ?? 0

        // Extract audio file references
        let audioFiles = extractAudioFiles(chunks: chunks, data: data)

        // Extract audio regions
        var regions = extractRegions(chunks: chunks, data: data)

        // Apply track-to-region mapping
        applyTrackRegionMapping(
            chunks: chunks,
            data: data,
            tracks: &parsedTracks,
            regions: &regions
        )

        // Enrich tracks with AuCO mixer data (volume, pan, output routing)
        enrichTracksWithAuCO(chunks: chunks, data: data, tracks: &parsedTracks)

        // Extract plugin list
        let plugins = extractPlugins(chunks: chunks, data: data)

        var info = ProjectDataInfo()
        info.markers = markers
        info.tempoMap = tempoMap
        info.tracks = parsedTracks
        info.regions = regions
        info.audioFiles = audioFiles
        info.plugins = plugins
        info.timeSignature = timeSignature
        info.sampleRate = sampleRate
        info.projectName = projectName
        return info
    }

    // MARK: - File Discovery

    /// Find the ProjectData file inside a .logicx bundle.
    /// Scans Alternatives/000, Alternatives/001, etc.
    private static func findProjectData(in logicxURL: URL) -> URL? {
        let altRoot = logicxURL.appendingPathComponent("Alternatives")
        let fm = FileManager.default

        // Try numbered alternatives 000..009
        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let candidate = altRoot
                .appendingPathComponent(indexStr)
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: scan directory entries
        if let entries = try? fm.contentsOfDirectory(atPath: altRoot.path) {
            for entry in entries.sorted() {
                let candidate = altRoot
                    .appendingPathComponent(entry)
                    .appendingPathComponent("ProjectData")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Walk up the directory tree from a raw ProjectData file to find the parent .logicx bundle.
    private static func findLogicxParent(of url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<5 {
            if current.pathExtension == "logicx" { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Magic Validation

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x23 && data[1] == 0x47 && data[2] == 0xC0 && data[3] == 0xAB
    }

    // MARK: - Chunk Scanning

    /// Describes a located chunk.
    private struct ChunkInfo {
        let id: String      // reversed 4-char ID
        let oid: UInt32
        let bodyOffset: Int // offset within data where body begins
        let bodyLength: Int
    }

    /// Scan the entire data blob for valid chunks using the anchor-signature method.
    ///
    /// Anchor at offset 0x16 within a 36-byte header:
    ///   02 00 00 00 [01|02] 00
    ///
    /// The chunk ID is 4 bytes at the very start of the header, i.e. 0x16 bytes before
    /// the anchor.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let bytes = data
        let total = bytes.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            // Look for anchor pattern: 02 00 00 00 [01 or 02] 00
            // We scan byte-by-byte; for performance we look for 0x02 first.
            guard bytes[offset + anchorOffset] == 0x02,
                  bytes[offset + anchorOffset + 1] == 0x00,
                  bytes[offset + anchorOffset + 2] == 0x00,
                  bytes[offset + anchorOffset + 3] == 0x00,
                  (bytes[offset + anchorOffset + 4] == 0x01 || bytes[offset + anchorOffset + 4] == 0x02),
                  bytes[offset + anchorOffset + 5] == 0x00
            else {
                offset += 1
                continue
            }

            // Looks like an anchor; read length field
            let bodyLength = Int(readLE64(data, at: offset + lengthOffset))
            let bodyStart = offset + chunkHeaderSize

            // Validate bounds
            guard bodyLength >= 0,
                  bodyStart + bodyLength <= total
            else {
                offset += 1
                continue
            }

            // Read 4-byte ID (reversed)
            let rawID = Array(bytes[offset..<(offset + 4)])
            let id = reverseID(rawID)

            // Read OID
            let oid = readLE32(data, at: offset + oidOffset)

            result.append(ChunkInfo(
                id: id,
                oid: oid,
                bodyOffset: bodyStart,
                bodyLength: bodyLength
            ))

            // Advance past this chunk
            offset = bodyStart + bodyLength
        }
        return result
    }

    // MARK: - TxSq Name Extraction

    /// Extract RTF text from ALL TxSq chunks.
    /// Returns a map of OID -> cleaned name.
    /// Marker OIDs vary per project, so we extract everything and let the
    /// EvSq type-18 join determine which are actual arrangement markers.
    private static func extractTxSqNames(chunks: [ChunkInfo], data: Data) -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        for chunk in chunks where chunk.id == idTxSq {
            guard chunk.bodyLength > 0 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            if let name = extractRTFText(body) {
                result[chunk.oid] = name
            }
        }
        return result
    }

    /// Extract plain text from an RTF body.
    /// Logic TxSq RTF typically has content after `\fs24` tag.
    /// Strategy: decode as ASCII (ignoring non-printable), find `\fs24 ` or similar,
    /// then extract the text between that and the closing `}`.
    private static func extractRTFText(_ body: Data) -> String? {
        // Decode as ASCII, replacing non-printable with dots
        let asciiStr = String(body.map { b -> Character in
            let s = Unicode.Scalar(b)
            return s.value >= 32 && s.value < 127 ? Character(s) : Character(".")
        })

        // Must contain RTF marker
        guard asciiStr.contains("{\\rtf") || asciiStr.contains("\\fs") else {
            return extractDirectString(body)
        }

        // Find content after \fs<N> (font size tag) — the actual text follows
        // Pattern: \fs24 <space or \cf2> TEXT}
        if let fsRange = asciiStr.range(of: "\\fs", options: .literal) {
            // Skip past the font size number
            var idx = fsRange.upperBound
            while idx < asciiStr.endIndex && (asciiStr[idx].isNumber) {
                idx = asciiStr.index(after: idx)
            }
            // Skip whitespace and \cf2 color tags
            var textStart = idx
            while textStart < asciiStr.endIndex {
                if asciiStr[textStart] == " " {
                    textStart = asciiStr.index(after: textStart)
                    continue
                }
                if asciiStr[textStart] == "\\" {
                    // Skip control word
                    var j = asciiStr.index(after: textStart)
                    while j < asciiStr.endIndex && (asciiStr[j].isLetter || asciiStr[j].isNumber) {
                        j = asciiStr.index(after: j)
                    }
                    if j < asciiStr.endIndex && asciiStr[j] == " " {
                        j = asciiStr.index(after: j)
                    }
                    textStart = j
                    continue
                }
                break
            }

            // Extract text until closing brace
            var textEnd = textStart
            while textEnd < asciiStr.endIndex && asciiStr[textEnd] != "}" {
                textEnd = asciiStr.index(after: textEnd)
            }

            if textStart < textEnd {
                var text = String(asciiStr[textStart..<textEnd])
                // Clean up: remove stray dots, trim
                text = text.replacingOccurrences(of: "..", with: " ")
                text = text.replacingOccurrences(of: ".", with: "")
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Remove leading/trailing non-alphanumeric
                while text.first != nil && !text.first!.isLetter && !text.first!.isNumber {
                    text.removeFirst()
                }
                while text.last != nil && !text.last!.isLetter && !text.last!.isNumber {
                    text.removeLast()
                }
                return text.isEmpty ? nil : text
            }
        }

        return nil
    }

    /// Fallback: try to read a length-prefixed ASCII string from raw body bytes.
    private static func extractDirectString(_ body: Data) -> String? {
        guard body.count >= 3 else { return nil }
        // Check for 2-byte LE length prefix
        let len = Int(body[0]) | (Int(body[1]) << 8)
        if len > 0 && len < body.count - 2 {
            if let s = String(data: body[2..<(2 + len)], encoding: .utf8) {
                let cleaned = s.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    // MARK: - EvSq Marker Event Extraction

    struct MarkerEvent {
        let oid: UInt32
        let startTick: UInt32
        let durationTicks: UInt32
    }

    /// Scan EvSq chunks for type-18 triplet sequences that encode arrangement marker positions.
    ///
    /// Per spec, small EvSq(oid=0) chunks contain 16-byte aligned triplets:
    ///   head:   [u32=18, u32=start_tick, u32=0, ...]
    ///   marker: [u32=marker_oid, u32=0x88000000, u32=marker_type, u32=duration_ticks]
    ///   tail:   [u32=0, u32=0x88000000, u32=0, u32=0]
    private static func extractMarkerEvents(chunks: [ChunkInfo], data: Data) -> [MarkerEvent] {
        var result: [MarkerEvent] = []

        for chunk in chunks where chunk.id == idEvSq {
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            let events = parseType18Triplets(body: body)
            result.append(contentsOf: events)
        }

        // Deduplicate by OID, keeping first occurrence
        var seen = Set<UInt32>()
        var deduped: [MarkerEvent] = []
        for e in result {
            if seen.insert(e.oid).inserted {
                deduped.append(e)
            }
        }
        return deduped
    }

    /// Parse type-18 triplets from an EvSq body.
    private static func parseType18Triplets(body: Data) -> [MarkerEvent] {
        var events: [MarkerEvent] = []
        // Rebase to 0-based
        let body = Data(body)
        let count = body.count / 16
        guard count >= 3 else { return events }

        var i = 0
        while i + 2 < count {
            let headOffset = i * 16
            let markerOffset = (i + 1) * 16
            let tailOffset = (i + 2) * 16

            guard headOffset + 16 <= body.count,
                  markerOffset + 16 <= body.count,
                  tailOffset + 16 <= body.count
            else { break }

            let h0 = readLE32(body, at: headOffset + 0)
            let h1 = readLE32(body, at: headOffset + 4)

            let m0 = readLE32(body, at: markerOffset + 0)
            let m1 = readLE32(body, at: markerOffset + 4)
            let m3 = readLE32(body, at: markerOffset + 12)

            let t0 = readLE32(body, at: tailOffset + 0)
            let t1 = readLE32(body, at: tailOffset + 4)

            // Check triplet pattern:
            // head[0] == 18, marker[1] == 0x88000000, tail[0] == 0, tail[1] == 0x88000000
            if h0 == 18
                && m1 == 0x88000000
                && t0 == 0
                && t1 == 0x88000000
            {
                events.append(MarkerEvent(oid: m0, startTick: h1, durationTicks: m3))
                i += 3
                continue
            }
            i += 1
        }
        return events
    }

    // MARK: - Tempo Map Extraction

    /// Extract tempo events from EvSq chunks using multiple strategies:
    ///   1. Standard 7F 00 00 01 signature (existing method)
    ///   2. Type-96 tempo bridge: row A [96, seq_tick, 0, 0x0100007F|0x8100007F],
    ///      row B [tempo_raw, 0x88400000, tempo_tick_abs, 0]
    private static func extractTempoMap(chunks: [ChunkInfo], data: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []

        for chunk in chunks where chunk.id == idEvSq {
            guard chunk.bodyLength >= 20 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Strategy 1: standard 7F 00 00 01 signature
            let standardTempos = parseTempoEvents(body: body)
            entries.append(contentsOf: standardTempos)

            // Strategy 2: type-96 bridge (16-byte aligned pairs)
            let bridgeTempos = parseType96TempoEvents(body: body)
            entries.append(contentsOf: bridgeTempos)
        }

        // Sort by tick and deduplicate
        entries.sort { $0.tick < $1.tick }
        var seen = Set<Int>()
        return entries.filter { seen.insert($0.tick).inserted }
    }

    private static func parseTempoEvents(body: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []
        // Rebase slice to 0-based indices so direct subscript access works
        let bytes = Data(body)
        let total = bytes.count
        var offset = 0

        while offset + 20 <= total {
            // Look for tempo signature: 7F 00 00 01
            guard bytes[offset] == 0x7F,
                  bytes[offset + 1] == 0x00,
                  bytes[offset + 2] == 0x00,
                  bytes[offset + 3] == 0x01
            else {
                offset += 1
                continue
            }

            // Read millitempo (4 bytes LE at offset+4)
            let milliTempo = readLE32(body, at: offset + 4)
            guard milliTempo > 0 else { offset += 1; continue }

            // Read tick position (8 bytes LE at offset+12, but we use low 4 bytes for now)
            let tickLow = readLE32(body, at: offset + 12)
            let tickHigh = readLE32(body, at: offset + 16)
            let tick = Int(tickLow) | (Int(tickHigh) << 32)

            let bpm = Double(milliTempo) / 10000.0
            guard bpm > 10.0 && bpm < 1000.0 else { offset += 4; continue }

            let bar = tick / ticksPerBar + 1
            entries.append(TempoEntry(bpm: bpm, tick: tick, bar: bar))
            offset += 20
        }
        return entries
    }

    /// Parse type-96 tempo bridge format from EvSq body.
    ///
    /// Format (16-byte aligned rows):
    ///   row A: [u32=96, u32=sequence_tick, u32=0, u32=0x0100007F or 0x8100007F]
    ///   row B: [u32=tempo_raw, u32=0x88400000, u32=tempo_tick_abs, u32=0]
    ///   tempo_raw = BPM * 10000
    private static func parseType96TempoEvents(body: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []
        let bytes = Data(body)
        let count = bytes.count / 16
        guard count >= 2 else { return entries }

        var i = 0
        while i + 1 < count {
            let aOff = i * 16
            let bOff = (i + 1) * 16

            guard aOff + 16 <= bytes.count, bOff + 16 <= bytes.count else { break }

            let a0 = readLE32(bytes, at: aOff + 0)   // should be 96
            let a3 = readLE32(bytes, at: aOff + 12)  // should be 0x0100007F or 0x8100007F

            // Row A signature check
            guard a0 == 96,
                  (a3 == 0x0100007F || a3 == 0x8100007F)
            else {
                i += 1
                continue
            }

            let b0 = readLE32(bytes, at: bOff + 0)   // tempo_raw = BPM * 10000
            let b1 = readLE32(bytes, at: bOff + 4)   // should be 0x88400000
            let b2 = readLE32(bytes, at: bOff + 8)   // tempo_tick_abs
            // b3 should be 0

            guard b1 == 0x88400000, b0 > 0 else {
                i += 1
                continue
            }

            let bpm = Double(b0) / 10000.0
            guard bpm > 10.0 && bpm < 1000.0 else {
                i += 1
                continue
            }

            let tick = Int(b2)
            let bar = tick / ticksPerBar + 1
            entries.append(TempoEntry(bpm: bpm, tick: tick, bar: bar))
            i += 2  // consumed both rows
        }
        return entries
    }

    // MARK: - Track Name Extraction (MSeq)

    /// Extract track names from MSeq chunks.
    ///
    /// MSeq body layout:
    ///   0x10  2B  name_length (LE u16)
    ///   0x12  *B  name (ASCII)
    private static func extractTracks(chunks: [ChunkInfo], data: Data) -> [ParsedTrack] {
        var result: [ParsedTrack] = []
        var seen = Set<UInt32>()

        for chunk in chunks where chunk.id == idMSeq {
            guard chunk.bodyLength > 0x12 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            guard body.count > 0x12 else { continue }
            let nameLen = Int(readLE16(body, at: 0x10))
            guard nameLen > 0, 0x12 + nameLen <= body.count else { continue }

            guard let name = String(data: body[0x12..<(0x12 + nameLen)], encoding: .utf8)
                    ?? String(data: body[0x12..<(0x12 + nameLen)], encoding: .isoLatin1)
            else { continue }

            let cleaned = name.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            guard !cleaned.isEmpty else { continue }
            // Filter out generic/internal tracks
            guard !cleaned.hasPrefix("*Automation"),
                  cleaned != "Untitled",
                  !cleaned.hasPrefix("Track Automation")
            else { continue }

            if seen.insert(chunk.oid).inserted {
                result.append(ParsedTrack(name: cleaned, oid: Int(chunk.oid)))
            }
        }
        return result
    }

    // MARK: - Audio File References (AuFl)

    /// Extract audio file paths from AuFl chunks.
    ///
    /// AuFl body layout:
    ///   0x08  2B  character count (LE u16) — number of UTF-16 code units
    ///   0x0A  *B  UTF-16LE encoded file path (char_count * 2 bytes)
    ///
    /// Note: the spec says "starts at offset 0x0A"; the char count at 0x08 gives
    /// the exact length, avoiding ambiguity with null-terminator detection.
    private static func extractAudioFiles(chunks: [ChunkInfo], data: Data) -> [ParsedAudioFile] {
        var result: [ParsedAudioFile] = []
        var seen = Set<UInt32>()

        for chunk in chunks where chunk.id == idAuFl {
            guard chunk.bodyLength > 0x0C else { continue }
            if !seen.insert(chunk.oid).inserted { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Read char count at 0x08 (LE u16 = number of UTF-16 code units)
            let charCount = Int(readLE16(body, at: 0x08))
            let byteCount = charCount * 2
            let pathOffset = 0x0A

            if charCount > 0, pathOffset + byteCount <= body.count {
                // Use length-prefixed decode (most reliable)
                let pathSlice = Data(body[pathOffset..<(pathOffset + byteCount)])
                if let path = String(data: pathSlice, encoding: .utf16LittleEndian), !path.isEmpty {
                    result.append(ParsedAudioFile(path: path, oid: Int(chunk.oid)))
                    continue
                }
            }

            // Fallback: null-terminator scan for UTF-16LE
            guard body.count > pathOffset + 2 else { continue }
            let pathData = Data(body[pathOffset...])
            var pathEnd = 0
            while pathEnd + 1 < pathData.count {
                if pathData[pathEnd] == 0 && pathData[pathEnd + 1] == 0 { break }
                pathEnd += 2
            }
            guard pathEnd > 0 else { continue }
            let utf16Slice = Data(pathData[0..<pathEnd])
            if let path = String(data: utf16Slice, encoding: .utf16LittleEndian), !path.isEmpty {
                result.append(ParsedAudioFile(path: path, oid: Int(chunk.oid)))
            }
        }
        return result
    }

    // MARK: - Audio Region Extraction (AuRg)

    /// Extract audio regions from AuRg chunks.
    ///
    /// AuRg body layout:
    ///   0x30  8B  legacy start tick (LE u64) — tried FIRST
    ///   0x10  4B  start_bar_int (LE u32)     — bar-field fallback
    ///   0x14  4B  start_bar_frac_hi (LE u32) — fractional bars: frac = (value >> 16) / 65536
    ///   0x18  4B  length_bar_int (LE u32)
    ///   0x1C  4B  length_bar_frac_hi (LE u32)
    ///   0x4A  2B  name_length (LE u16)
    ///   0x4C  *B  name (ASCII)
    ///
    /// The AuRg OID matches the AuFl OID that owns this audio asset.
    private static func extractRegions(chunks: [ChunkInfo], data: Data) -> [ParsedRegion] {
        var result: [ParsedRegion] = []

        for chunk in chunks where chunk.id == idAuRg {
            guard chunk.bodyLength > 0x4C else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // --- Timeline placement ---
            var startBar: Double = 0
            var lengthBars: Double = 0
            var startTick: Int = 0
            var lengthTicks: Int = 0

            // Bug 3 Fix: Try legacy tick mode FIRST.
            // 8-byte LE tick at body offset 0x30; bar = tick / 3840 + 1.
            // Accept if bar is in reasonable range (1-5000).
            // Only fall back to bar-field mode if legacy gives 0 or unreasonable values.
            var usedLegacy = false
            if body.count >= 0x38 {
                // Read full 8-byte LE tick at 0x30
                let rawStartTick = Int(readLE64(body, at: 0x30))
                let legacyBar = rawStartTick / ticksPerBar + 1
                if rawStartTick > 0 && legacyBar >= 1 && legacyBar <= 5000 {
                    startTick = rawStartTick
                    startBar = Double(rawStartTick) / Double(ticksPerBar) + 1.0
                    // Length at 0x38 (8-byte LE tick)
                    if body.count >= 0x40 {
                        let rawLenTick = Int(readLE64(body, at: 0x38))
                        lengthTicks = rawLenTick
                        lengthBars = Double(rawLenTick) / Double(ticksPerBar)
                    } else if body.count >= 0x3C {
                        let rawLenLow = readLE32(body, at: 0x38)
                        lengthTicks = Int(rawLenLow)
                        lengthBars = Double(lengthTicks) / Double(ticksPerBar)
                    }
                    usedLegacy = true
                } else if rawStartTick > 0 {
                    // Tick is non-zero but bar is out of range — check for large pre-roll offset.
                    // Some projects encode absolute timeline ticks; subtract any offset > 5000 bars.
                    // If after subtracting some pre-roll the bar lands in 1-5000, accept it.
                    let barsFromZero = rawStartTick / ticksPerBar
                    if barsFromZero > 5000 {
                        // Try bar-field below — don't use this tick value
                    } else if legacyBar > 5000 {
                        // legacyBar > 5000: bar-field will be tried below
                    }
                }
            }

            if !usedLegacy {
                // Bar-field mode fallback: offsets 0x10..0x1F
                let startBarInt = readLE32(body, at: 0x10)
                let startBarFracRaw = readLE32(body, at: 0x14)
                let lengthBarInt = readLE32(body, at: 0x18)
                let lengthBarFracRaw = readLE32(body, at: 0x1C)

                let startBarFrac = Double(startBarFracRaw >> 16) / 65536.0
                let lengthBarFrac = Double(lengthBarFracRaw >> 16) / 65536.0

                let candidateBar = Double(startBarInt) + startBarFrac
                // Validate bar-field values — reject if out of reasonable range
                if (startBarInt > 0 || startBarFrac > 0) && candidateBar <= 5000.0 {
                    startBar = candidateBar
                    lengthBars = Double(lengthBarInt) + lengthBarFrac
                    startTick = Int((startBar - 1.0) * Double(ticksPerBar))
                    lengthTicks = Int(lengthBars * Double(ticksPerBar))
                }
            }

            // --- Region name ---
            let nameLen = Int(readLE16(body, at: 0x4A))
            guard nameLen > 0, 0x4C + nameLen <= body.count else {
                // Still add a region with empty name if timing data is valid
                if startTick > 0 || startBar > 0 {
                    result.append(ParsedRegion(
                        name: "",
                        oid: Int(chunk.oid),
                        startTick: startTick,
                        startBar: startBar,
                        lengthTicks: lengthTicks,
                        lengthBars: lengthBars,
                        audioFileOid: Int(chunk.oid),
                        trackOid: nil
                    ))
                }
                continue
            }

            let nameSlice = Data(body[0x4C..<(0x4C + nameLen)])
            let name = String(data: nameSlice, encoding: .utf8)
                ?? String(data: nameSlice, encoding: .isoLatin1)
                ?? ""

            result.append(ParsedRegion(
                name: name,
                oid: Int(chunk.oid),
                startTick: startTick,
                startBar: startBar,
                lengthTicks: lengthTicks,
                lengthBars: lengthBars,
                audioFileOid: Int(chunk.oid),
                trackOid: nil
            ))
        }

        return result
    }

    // MARK: - Track-to-Region Mapping

    /// Populate trackOid on regions and regions list on tracks using the AuRg body scanning
    /// heuristic described in reference/LOGIC_BINARY_SPEC.md and python_extractor_snippets.txt.
    ///
    /// Bug 1 Fix: Replace Song/USEl table scan with AuRg body offset heuristic.
    ///
    /// Algorithm:
    ///   1. Collect known track OIDs from MSeq chunks.
    ///   2. For each AuRg chunk body, group by body length.
    ///   3. For each length group, scan u32 values at candidate offsets
    ///      (0x00, 0x04, 0x08, 0x0C, 0x60, 0x64, 0x68) counting how many bodies
    ///      contain a known track OID at that offset.
    ///   4. Use the highest-scoring offset as the track reference for that length group.
    ///   5. Fallback: wide scan every 4 bytes from 0x00 to 0xC0 when no candidate offset wins.
    ///   6. Set trackOid on each ParsedRegion; leave nil if no match.
    private static func applyTrackRegionMapping(
        chunks: [ChunkInfo],
        data: Data,
        tracks: inout [ParsedTrack],
        regions: inout [ParsedRegion]
    ) {
        let trackOidSet = Set(tracks.map { UInt32($0.oid) })
        guard !trackOidSet.isEmpty, !regions.isEmpty else { return }

        // Candidate offsets per spec: 0x00, 0x04, 0x08, 0x0C, 0x60, 0x64, 0x68 (and more)
        // Include 0x00 — in AuRg bodies the first u32 can be a track OID reference.
        let candidateOffsets: [Int] = [0x00, 0x04, 0x08, 0x0C, 0x60, 0x64, 0x68,
                                       0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28,
                                       0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44,
                                       0x48, 0x4C, 0x50, 0x54, 0x58, 0x5C,
                                       0x6C, 0x70, 0x74, 0x78, 0x7C]

        // Collect all AuRg (body, regionIdx) pairs in chunk order
        var aurgBodies: [(body: Data, regionIdx: Int)] = []
        var regionIdx = 0
        for chunk in chunks where chunk.id == idAuRg {
            guard chunk.bodyLength > 0x4C else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            if regionIdx < regions.count {
                aurgBodies.append((body: body, regionIdx: regionIdx))
                regionIdx += 1
            }
        }

        // Group by body length
        var byLength: [Int: [(body: Data, regionIdx: Int)]] = [:]
        for entry in aurgBodies {
            byLength[entry.body.count, default: []].append(entry)
        }

        // Pass 1: for each length group, count track OID hits per candidate offset
        var bestOffsetByLength: [Int: Int] = [:]
        for (_, group) in byLength {
            let total = group.count
            guard total > 0 else { continue }

            var hitCounts: [Int: Int] = [:]
            for entry in group {
                let maxScan = min(entry.body.count, 0xC0)
                for off in candidateOffsets where off + 4 <= maxScan {
                    let val = readLE32(entry.body, at: off)
                    // Exclude OID=0 to avoid false hits (many fields default to 0)
                    if trackOidSet.contains(val) && val != 0 {
                        hitCounts[off, default: 0] += 1
                    }
                }
            }

            // Accept offset if ratio >= 0.15 or count >= 2 (lower threshold to catch sparse groups)
            let filtered = hitCounts.filter { $0.value * 20 >= total * 3 || $0.value >= 2 }
            if let best = filtered.max(by: { $0.value < $1.value }) {
                let len = group.first!.body.count
                bestOffsetByLength[len] = best.key
            }
        }

        // Pass 2: if still no good offset for a length group, do wider scan (every 4 bytes from 0x00)
        // Python: range(0, max_scan, 4) — includes offset 0
        for (len, group) in byLength {
            guard bestOffsetByLength[len] == nil else { continue }
            let total = group.count
            guard total >= 1 else { continue }

            var hitCounts: [Int: Int] = [:]
            for entry in group {
                let maxScan = min(entry.body.count, 0xC0)
                for off in stride(from: 0, to: maxScan - 3, by: 4) {
                    let val = readLE32(entry.body, at: off)
                    if trackOidSet.contains(val) && val != 0 {
                        hitCounts[off, default: 0] += 1
                    }
                }
            }

            // For wide scan, keep top offset with any hits (even 1 hit for single-region groups)
            if let best = hitCounts.max(by: { $0.value < $1.value }), best.value > 0 {
                bestOffsetByLength[len] = best.key
            }
        }

        // Assign track OIDs to regions
        for entry in aurgBodies {
            let len = entry.body.count
            guard let bestOff = bestOffsetByLength[len], bestOff + 4 <= len else { continue }
            let val = readLE32(entry.body, at: bestOff)
            guard trackOidSet.contains(val), val != 0 else { continue }
            regions[entry.regionIdx].trackOid = Int(val)
        }

        // Build track -> regions cross-reference
        var trackRegionMap: [Int: [ParsedRegion]] = [:]
        for region in regions {
            if let tOid = region.trackOid {
                trackRegionMap[tOid, default: []].append(region)
            }
        }
        for i in tracks.indices {
            if let regs = trackRegionMap[tracks[i].oid] {
                tracks[i].regions = regs
            }
        }
    }

    // MARK: - AuCO Mixer Data (Volume, Pan, Output Routing)

    /// Enrich tracks with volume, pan, and output routing from AuCO chunks.
    ///
    /// AuCO body layout:
    ///   0x3C  null-terminated ASCII  channel strip name
    ///   0x59  1B                     pan byte (0=hard left, 64=center, 127=hard right)
    ///   volume: 4-byte LE u32 at a known offset; unity = 1509949440
    ///
    /// Bug 2 Fix: Match AuCO to track by OID (exact match first, then nearest within +/- 8),
    /// because AuCO strip names are generic ("Audio 1") and don't match MSeq track names.
    private static func enrichTracksWithAuCO(
        chunks: [ChunkInfo],
        data: Data,
        tracks: inout [ParsedTrack]
    ) {
        // Build OID -> track index map for direct OID matching
        var trackByOid: [UInt32: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackByOid[UInt32(t.oid)] = i
        }
        let sortedTrackOids = tracks.map { UInt32($0.oid) }.sorted()

        for chunk in chunks where chunk.id == idAuCO {
            guard chunk.bodyLength > 0x5A else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // --- Pan byte at 0x59 ---
            let panByte = Int(body[0x59])
            let panNorm: Double = (Double(panByte) - 64.0) / 64.0  // -1.0 to +1.0

            // --- Volume ---
            let volumeDB = readVolumeDB(body: body)

            // --- Output routing ---
            let outputRouting = extractOutputRouting(body: body)

            // --- Bug 2 Fix: Match by OID (exact first, then nearest within +/- 8) ---
            let aucoOid = chunk.oid
            var trackIdx: Int? = nil

            // Exact OID match
            if let idx = trackByOid[aucoOid] {
                trackIdx = idx
            } else {
                // Nearest track OID within +/- 8
                var bestDist: UInt32 = 9
                for tOid in sortedTrackOids {
                    let dist = aucoOid > tOid ? aucoOid - tOid : tOid - aucoOid
                    if dist < bestDist {
                        bestDist = dist
                        trackIdx = trackByOid[tOid]
                    }
                }
            }

            if let idx = trackIdx {
                tracks[idx].volume = volumeDB
                tracks[idx].pan = panNorm.clamped(to: -1.0...1.0)
                if let routing = outputRouting {
                    tracks[idx].outputRouting = routing
                }
            }
        }
    }

    /// Read null-terminated ASCII string from body at given offset.
    private static func readNullTerminatedASCII(_ body: Data, at offset: Int, maxLen: Int) -> String {
        guard offset < body.count else { return "" }
        var end = offset
        let limit = min(body.count, offset + maxLen)
        while end < limit && body[end] != 0 {
            end += 1
        }
        guard end > offset else { return "" }
        return String(data: Data(body[offset..<end]), encoding: .ascii) ?? ""
    }

    /// Scan AuCO body for volume raw value. Returns dB, or nil if no plausible value found.
    ///
    /// Unity gain = 1509949440 (0x5A000080 LE).
    /// Formula: dB = 40 * log10(value / 1509949440)
    ///
    /// Bug 2 Fix: Broader offset scan so volume is found across all AuCO body lengths.
    /// We check known offsets first, then fall back to scanning every 4 bytes.
    private static func readVolumeDB(body: Data) -> Double? {
        // Per spec unity = 1509949440; check known offsets for all observed body lengths
        let searchOffsets = [0x74, 0x48, 0x4C, 0x50, 0x54, 0x58, 0x64, 0x68, 0x6C, 0x70,
                             0x78, 0x7C, 0x80, 0x84, 0x88, 0x8C, 0x90, 0x94, 0x40, 0x44]
        for off in searchOffsets {
            guard off + 4 <= body.count else { continue }
            let raw = readLE32(body, at: off)
            guard raw > 0 else { continue }
            let ratio = Double(raw) / unityGainRaw
            guard ratio > 0 else { continue }
            let db = 40.0 * log10(ratio)
            if db >= -144.0 && db <= 24.0 {
                return db
            }
        }
        // Fallback: scan every 4 bytes for a value that decodes to a plausible volume
        // Accept values within ±18 dB of unity as most likely volume faders
        var i = 0x40
        while i + 4 <= body.count && i <= 0xC0 {
            let raw = readLE32(body, at: i)
            if raw > 0 {
                let ratio = Double(raw) / unityGainRaw
                if ratio > 0 {
                    let db = 40.0 * log10(ratio)
                    if db >= -18.0 && db <= 6.0 {
                        return db
                    }
                }
            }
            i += 4
        }
        return nil
    }

    /// Scan an AuCO body for output routing label strings.
    private static func extractOutputRouting(body: Data) -> String? {
        // Build a null-byte-preserving ASCII representation
        let bytes = body

        let keywords = ["Stereo Out", "Output", "Bus"]
        for keyword in keywords {
            guard let kwBytes = keyword.data(using: .ascii) else { continue }
            // Find keyword in body
            var searchFrom = 0
            while searchFrom + kwBytes.count <= bytes.count {
                var found = true
                for (i, b) in kwBytes.enumerated() {
                    if bytes[searchFrom + i] != b { found = false; break }
                }
                if found {
                    // Extract null-terminated string starting at keyword position
                    var end = searchFrom
                    let limit = min(bytes.count, searchFrom + 64)
                    while end < limit && bytes[end] != 0 {
                        end += 1
                    }
                    let label = String(data: Data(bytes[searchFrom..<end]), encoding: .ascii)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    if !label.isEmpty { return label }
                }
                searchFrom += 1
            }
        }
        return nil
    }

    // MARK: - Plugin List

    /// Extract plugin names by scanning ALL chunk bodies for known plugin name strings,
    /// and scanning PluginData (null-ID) chunks for printable ASCII strings > 4 chars.
    ///
    /// Bug 4 Fix:
    ///   - reverseID() now maps non-printable IDs to "PluginData" so they are no longer skipped.
    ///   - PluginData chunks are scanned for all printable ASCII strings > 4 chars.
    ///   - We also scan ALL chunks (not just "PluginData") for known plugin name strings.
    ///   - Extended known plugin list per spec.
    private static func extractPlugins(chunks: [ChunkInfo], data: Data) -> [String] {
        var plugins = Set<String>()

        // Known plugin name keywords to search for (per spec + user requirement)
        let knownPlugins: [String] = [
            // Logic built-ins
            "Compressor", "Channel EQ", "Space Designer", "Alchemy", "Klopfgeist",
            "Delay Designer", "Retro Synth", "Gain", "Limiter", "Multipressor",
            // Third-party
            "Serum", "Kontakt", "Neural DSP", "FabFilter", "Valhalla", "Waves", "iZotope",
            "Slate", "Massive", "Diva", "Sylenth", "Omnisphere", "Nexus", "Spire",
            "Vital", "Pigments", "Saturn", "Vintage", "Native Instruments",
        ]

        for chunk in chunks {
            guard chunk.bodyLength > 4, chunk.bodyLength < 10_000_000 else { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Scan for known plugin name keywords in ALL chunks
            let ascii = body.map { b -> Character in
                let s = Unicode.Scalar(b)
                return s.value >= 32 && s.value < 127 ? Character(s) : Character("\0")
            }
            let bodyStr = String(ascii)

            for plugin in knownPlugins where bodyStr.contains(plugin) {
                plugins.insert(plugin)
            }

            // For PluginData (null-ID) chunks: also extract all printable ASCII runs > 4 chars
            // These may contain plugin names not in our known list.
            if chunk.id == "PluginData" {
                var run = ""
                for byte in body {
                    let scalar = Unicode.Scalar(byte)
                    if scalar.value >= 32 && scalar.value < 127 {
                        run.append(Character(scalar))
                    } else {
                        // End of printable run — keep if > 4 chars and looks like a plugin name
                        // (starts with uppercase, not a path/URL/generic string)
                        if run.count > 4
                            && run.count < 64
                            && run.first?.isUppercase == true
                            && !run.hasPrefix("/")
                            && !run.hasPrefix("http")
                            && !run.contains("=")
                            && !run.contains("\\")
                        {
                            plugins.insert(run)
                        }
                        run = ""
                    }
                }
                // Flush final run
                if run.count > 4
                    && run.count < 64
                    && run.first?.isUppercase == true
                    && !run.hasPrefix("/")
                    && !run.hasPrefix("http")
                    && !run.contains("=")
                    && !run.contains("\\")
                {
                    plugins.insert(run)
                }
            }
        }

        return Array(plugins).sorted()
    }

    /// Returns true if the chunk ID consists only of non-printable / null bytes.
    private static func isNullID(_ id: String) -> Bool {
        return id.unicodeScalars.allSatisfy { $0.value < 32 || $0.value == 0 }
    }

    // MARK: - Marker Assembly

    private static func buildMarkers(
        txSqMap: [UInt32: String],
        events: [MarkerEvent]
    ) -> [ParsedMarker] {
        // Build a map from events for quick lookup
        let eventMap: [UInt32: MarkerEvent] = Dictionary(
            events.map { ($0.oid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // First pass: build markers with tick/bar, sort by tick
        struct PartialMarker {
            let name: String
            let bar: Int
            let tick: Int
            let oid: Int
        }

        var partials: [PartialMarker] = []
        for (oid, name) in txSqMap {
            guard let event = eventMap[oid] else { continue }
            let tick = Int(event.startTick)
            let bar = tick / ticksPerBar + 1
            partials.append(PartialMarker(name: name, bar: bar, tick: tick, oid: Int(oid)))
        }

        // Sort by tick position (ascending)
        partials.sort { $0.tick < $1.tick }

        // Second pass: calculate duration from sequential markers (Fix 1)
        // For each marker except the last: duration = next_marker.tick - this_marker.tick
        // For the last marker: default 8 bars = 3840 * 8 = 30720 ticks
        let defaultLastDuration = ticksPerBar * 8

        var markers: [ParsedMarker] = []
        for (i, partial) in partials.enumerated() {
            let durationTicks: Int
            if i + 1 < partials.count {
                durationTicks = partials[i + 1].tick - partial.tick
            } else {
                durationTicks = defaultLastDuration
            }
            let durationBars = durationTicks > 0 ? max(1, durationTicks / ticksPerBar) : 0

            markers.append(ParsedMarker(
                name: partial.name,
                bar: partial.bar,
                tick: partial.tick,
                durationTicks: durationTicks,
                durationBars: durationBars,
                oid: partial.oid
            ))
        }

        return markers
    }

    // MARK: - Plist Parsing (Time Signature, Sample Rate, BPM)

    /// Build a list of candidate plist URLs to check within a .logicx bundle.
    /// The MetaData.plist is typically inside Alternatives/000/ (not at the root).
    private static func plistCandidateURLs(logicx: URL, name: String) -> [URL] {
        var candidates: [URL] = []
        // Root-level (some older versions place files here)
        candidates.append(logicx.appendingPathComponent(name))
        // Alternatives subdirectories (000, 001, etc.)
        let altRoot = logicx.appendingPathComponent("Alternatives")
        let fm = FileManager.default
        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let url = altRoot.appendingPathComponent(indexStr).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                candidates.insert(url, at: 0) // prefer found file
            } else {
                candidates.append(url)
            }
        }
        return candidates
    }

    /// Read time signature from MetaData.plist or ProjectInformation.plist.
    private static func readTimeSignature(logicx: URL) -> String? {
        let names = ["MetaData.plist", "ProjectInformation.plist"]
        for name in names {
            for url in plistCandidateURLs(logicx: logicx, name: name) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if let sig = searchPlistForTimeSignature(plist) { return sig }
            }
        }
        return nil
    }

    /// Read initial BPM from project plists.
    /// Checks MetaData.plist and ProjectInformation.plist for common BPM/Tempo keys.
    private static func readBPMFromPlist(logicx: URL) -> Double? {
        let names = ["MetaData.plist", "ProjectInformation.plist"]
        for name in names {
            for url in plistCandidateURLs(logicx: logicx, name: name) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if let bpm = searchPlistForBPM(plist) { return bpm }
            }
        }
        return nil
    }

    private static func searchPlistForBPM(_ plist: Any) -> Double? {
        let bpmKeys = ["BPM", "bpm", "Tempo", "tempo", "BeatsPerMinute", "beatsPerMinute",
                       "ProjectTempo", "projectTempo", "DefaultTempo", "defaultTempo"]
        if let dict = plist as? [String: Any] {
            for key in bpmKeys {
                if let v = dict[key] {
                    if let d = v as? Double, d > 10.0 && d < 1000.0 { return d }
                    if let i = v as? Int, i > 10 && i < 1000 { return Double(i) }
                    if let s = v as? String, let d = Double(s), d > 10.0 && d < 1000.0 { return d }
                }
            }
            for (_, value) in dict {
                if let found = searchPlistForBPM(value) { return found }
            }
        } else if let arr = plist as? [Any] {
            for item in arr {
                if let found = searchPlistForBPM(item) { return found }
            }
        }
        return nil
    }

    private static func searchPlistForTimeSignature(_ plist: Any) -> String? {
        if let dict = plist as? [String: Any] {
            // Look for TimeSignature key directly
            if let ts = dict["TimeSignature"] as? String { return ts }
            if let n = dict["numerator"] as? Int, let d = dict["denominator"] as? Int {
                return "\(n)/\(d)"
            }
            // Recurse into values
            for (_, value) in dict {
                if let found = searchPlistForTimeSignature(value) { return found }
            }
        } else if let arr = plist as? [Any] {
            for item in arr {
                if let found = searchPlistForTimeSignature(item) { return found }
            }
        }
        return nil
    }

    /// Read sample rate from project plists.
    private static func readSampleRate(logicx: URL) -> Int? {
        // Check standard project plists (MetaData.plist is inside Alternatives/000/)
        let names = ["MetaData.plist", "ProjectInformation.plist", "Info.plist"]
        for name in names {
            for url in plistCandidateURLs(logicx: logicx, name: name) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if let sr = searchPlistForSampleRate(plist) { return sr }
            }
        }
        return nil
    }

    private static func searchPlistForSampleRate(_ plist: Any) -> Int? {
        let srKeys = [
            "SampleRate", "sampleRate", "sample_rate",
            "Recording Sample Rate", "RecordingSampleRate",
            "Audio Sample Rate", "AudioSampleRate",
            "AudioFileSampleRate", "audioFileSampleRate",
        ]
        if let dict = plist as? [String: Any] {
            for key in srKeys {
                if let v = dict[key] {
                    if let i = v as? Int, i > 0 { return i }
                    if let d = v as? Double, d > 0 { return Int(d) }
                    if let s = v as? String, let i = Int(s), i > 0 { return i }
                    // Handle string-encoded floats (e.g. "44100.0")
                    if let s = v as? String, let d = Double(s), d > 0 { return Int(d) }
                }
            }
            for (_, value) in dict {
                if let found = searchPlistForSampleRate(value) { return found }
            }
        } else if let arr = plist as? [Any] {
            for item in arr {
                if let found = searchPlistForSampleRate(item) { return found }
            }
        }
        return nil
    }

    // MARK: - Low-level Readers

    /// Read a 4-byte little-endian UInt32 from a Data slice at a given offset within that slice.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Read a 2-byte little-endian UInt16 from a Data slice.
    private static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    /// Read an 8-byte little-endian UInt64 from a Data slice.
    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    /// Reverse the 4 ID bytes to get the human-readable chunk ID.
    /// e.g., on-disk bytes [0x71, 0x53, 0x78, 0x54] -> "TxSq"
    /// Bug 4 Fix: when all 4 bytes are zero or non-printable, return "PluginData"
    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        let chars = reversed.compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        // If all 4 bytes are non-printable/null, this is a PluginData-style chunk
        if chars.count < 4 {
            return "PluginData"
        }
        return String(chars)
    }
}

// MARK: - Comparable Clamping Helper

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - AppleScript Helper

/// Run AppleScript with a timeout using DispatchSemaphore.
/// Returns the string result, or nil on error or timeout.
func runAppleScript(_ source: String) -> String? {
    // Wrap result in a class so it can be mutated from the async closure
    // without triggering Swift 6 Sendable warnings.
    final class Box: @unchecked Sendable { var value: String? }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        let desc = script?.executeAndReturnError(&errorDict)
        if errorDict == nil {
            box.value = desc?.stringValue
        }
        semaphore.signal()
    }

    // Wait up to 3 seconds
    let timedOut = semaphore.wait(timeout: .now() + 3.0) == .timedOut
    return timedOut ? nil : box.value
}

/// Get the POSIX path of the front Logic Pro document via AppleScript.
/// If AppleScript fails or times out, falls back to finding the most recently
/// modified .logicx file in ~/Desktop, ~/Documents, and ~/Music (max depth 3).
func currentLogicProProjectPath() -> String? {
    let source = """
    tell application "Logic Pro" to get POSIX path of (file of front document)
    """
    if let path = runAppleScript(source), !path.isEmpty {
        return path
    }
    return findMostRecentLogicxFile()
}

/// Scan ~/Desktop, ~/Documents, ~/Music for the most recently modified .logicx bundle
/// (max directory depth 3). Returns the path with the latest modification date, or nil.
func findMostRecentLogicxFile() -> String? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let searchRoots = [
        home.appendingPathComponent("Desktop"),
        home.appendingPathComponent("Documents"),
        home.appendingPathComponent("Music"),
    ]

    var best: (path: String, date: Date)? = nil

    func scan(_ url: URL, depth: Int) {
        guard depth >= 0 else { return }

        if url.pathExtension == "logicx" {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date {
                if best == nil || modDate > best!.date {
                    best = (url.path, modDate)
                }
            }
            return  // Don't recurse into .logicx bundles
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in contents {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if child.pathExtension == "logicx" {
                if let attrs = try? fm.attributesOfItem(atPath: child.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    if best == nil || modDate > best!.date {
                        best = (child.path, modDate)
                    }
                }
            } else if isDir && depth > 0 {
                scan(child, depth: depth - 1)
            }
        }
    }

    for root in searchRoots {
        scan(root, depth: 3)
    }

    return best?.path
}
