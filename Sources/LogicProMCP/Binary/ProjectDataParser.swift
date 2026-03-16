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
    /// AuRg body layout (bar-field mode, primary):
    ///   0x10  4B  start_bar_int (LE u32)
    ///   0x14  4B  start_bar_frac_hi (LE u32) — fractional bars: frac = (value >> 16) / 65536
    ///   0x18  4B  length_bar_int (LE u32)
    ///   0x1C  4B  length_bar_frac_hi (LE u32)
    ///   0x30  8B  legacy start tick (LE u64) — fallback
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

            // Bar-field mode (primary): offsets 0x10..0x1F
            let startBarInt = readLE32(body, at: 0x10)
            let startBarFracRaw = readLE32(body, at: 0x14)
            let lengthBarInt = readLE32(body, at: 0x18)
            let lengthBarFracRaw = readLE32(body, at: 0x1C)

            let startBarFrac = Double(startBarFracRaw >> 16) / 65536.0
            let lengthBarFrac = Double(lengthBarFracRaw >> 16) / 65536.0

            if startBarInt > 0 || startBarFrac > 0 {
                // Bar-field mode valid
                startBar = Double(startBarInt) + startBarFrac
                lengthBars = Double(lengthBarInt) + lengthBarFrac
                startTick = Int(startBar * Double(ticksPerBar))
                lengthTicks = Int(lengthBars * Double(ticksPerBar))
            } else {
                // Legacy mode fallback: 8-byte LE tick at body offset 0x30
                if body.count > 0x38 {
                    let tickLow = readLE32(body, at: 0x30)
                    let tickHigh = readLE32(body, at: 0x34)
                    startTick = Int(tickLow) | (Int(tickHigh) << 32)
                    startBar = Double(startTick) / Double(ticksPerBar)
                    // Length: try 0x38
                    let lenLow = readLE32(body, at: 0x38)
                    let lenHigh = body.count > 0x40 ? readLE32(body, at: 0x3C) : 0
                    lengthTicks = Int(lenLow) | (Int(lenHigh) << 32)
                    lengthBars = Double(lengthTicks) / Double(ticksPerBar)
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

    /// Populate trackOid on regions and regions list on tracks using:
    ///   1. Song / USEl explicit [TrackOID, Count, RegionOID...] tables
    ///   2. AuRg body heuristic (scan for track OID patterns)
    private static func applyTrackRegionMapping(
        chunks: [ChunkInfo],
        data: Data,
        tracks: inout [ParsedTrack],
        regions: inout [ParsedRegion]
    ) {
        let trackOidSet = Set(tracks.map { UInt32($0.oid) })
        guard !trackOidSet.isEmpty, !regions.isEmpty else { return }

        // Build region lookup by OID (regions may share OID, use index as key too)
        // Map regionOID -> [indices into regions array]
        var regionsByOid: [UInt32: [Int]] = [:]
        for (i, r) in regions.enumerated() {
            regionsByOid[UInt32(r.oid), default: []].append(i)
        }

        // Mapping: region index -> track oid
        var regionTrackMap: [Int: UInt32] = [:]

        // Strategy 1: scan Song and USEl chunk bodies for explicit tables
        for chunk in chunks where (chunk.id == "Song" || chunk.id == "USEl") {
            guard chunk.bodyLength >= 12 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            scanExplicitMappingTable(
                body: body,
                trackOidSet: trackOidSet,
                regionsByOid: regionsByOid,
                regionTrackMap: &regionTrackMap
            )
        }

        // Strategy 2: AuRg body heuristic for unmapped regions
        // (skipped — heuristic-only; Song/USEl tables are preferred)

        // Apply the mapping back
        for (regionIdx, trackOid) in regionTrackMap {
            regions[regionIdx].trackOid = Int(trackOid)
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

    /// Scan a chunk body for u32 sequences of the form:
    ///   [track_oid, count, region_oid_1, region_oid_2, ...]
    /// where track_oid is a known MSeq OID and count is reasonable (1–100).
    private static func scanExplicitMappingTable(
        body: Data,
        trackOidSet: Set<UInt32>,
        regionsByOid: [UInt32: [Int]],
        regionTrackMap: inout [Int: UInt32]
    ) {
        guard body.count >= 12 else { return }
        let count = body.count / 4
        var i = 0
        while i < count - 1 {
            let val = readLE32(body, at: i * 4)
            guard trackOidSet.contains(val) else { i += 1; continue }

            let regionCount = Int(readLE32(body, at: (i + 1) * 4))
            guard regionCount >= 1, regionCount <= 100 else { i += 1; continue }
            guard i + 1 + regionCount < count else { i += 1; continue }

            // Check that the following regionCount u32s are known region OIDs
            var matched = 0
            for j in 0..<regionCount {
                let candidate = readLE32(body, at: (i + 2 + j) * 4)
                if regionsByOid[candidate] != nil { matched += 1 }
            }

            // Require majority match (≥50% of claimed regions are known OIDs)
            if matched * 2 >= regionCount {
                let trackOid = val
                for j in 0..<regionCount {
                    let regionOid = readLE32(body, at: (i + 2 + j) * 4)
                    if let indices = regionsByOid[regionOid] {
                        for idx in indices where regionTrackMap[idx] == nil {
                            regionTrackMap[idx] = trackOid
                        }
                    }
                }
                i += 2 + regionCount
                continue
            }
            i += 1
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
    /// Matching strategy: match AuCO channel strip name to MSeq track name (case-insensitive).
    /// Fallback: scan for routing strings (Output/Bus/Stereo Out) even when name doesn't match.
    private static func enrichTracksWithAuCO(
        chunks: [ChunkInfo],
        data: Data,
        tracks: inout [ParsedTrack]
    ) {
        // Build a name -> track index map for quick lookup
        var trackByName: [String: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackByName[t.name.lowercased()] = i
        }

        for chunk in chunks where chunk.id == idAuCO {
            guard chunk.bodyLength > 0x5A else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // --- Channel strip name at 0x3C ---
            let stripName = readNullTerminatedASCII(body, at: 0x3C, maxLen: 64)

            // --- Pan byte at 0x59 ---
            let panByte = Int(body[0x59])
            let panNorm: Double = (Double(panByte) - 64.0) / 64.0  // -1.0 to +1.0

            // --- Volume: scan for u32 values near the channel name area ---
            // Per spec: volume is a 32-bit integer at a known offset.
            // We scan a window around 0x50-0x58 for plausible volume values.
            let volumeDB = readVolumeDB(body: body)

            // --- Output routing: scan for "Output", "Bus", "Stereo Out" strings ---
            let outputRouting = extractOutputRouting(body: body)

            // --- Match to track by name ---
            if let idx = trackByName[stripName.lowercased()], !stripName.isEmpty {
                tracks[idx].volume = volumeDB
                tracks[idx].pan = panNorm.clamped(to: -1.0...1.0)
                if let routing = outputRouting {
                    tracks[idx].outputRouting = routing
                }
            } else if let routing = outputRouting {
                // Even without a name match, try to assign routing to an unassigned track
                // by looking for a track with a matching name prefix in the routing string
                for i in tracks.indices where tracks[i].outputRouting == nil {
                    let tname = tracks[i].name.lowercased()
                    if routing.lowercased().contains(tname) || tname.contains(stripName.lowercased()) {
                        tracks[i].outputRouting = routing
                        tracks[i].volume = volumeDB
                        tracks[i].pan = panNorm.clamped(to: -1.0...1.0)
                        break
                    }
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
    /// We scan offsets 0x48..0x58 for a 4-byte value that decodes to a reasonable dB range (-144..+6).
    private static func readVolumeDB(body: Data) -> Double? {
        // Per spec unity = 1509949440; try the standard volume offset range
        let searchOffsets = [0x48, 0x4C, 0x50, 0x54, 0x58]
        for off in searchOffsets {
            guard off + 4 <= body.count else { continue }
            let raw = readLE32(body, at: off)
            guard raw > 0 else { continue }
            let ratio = Double(raw) / unityGainRaw
            guard ratio > 0 else { continue }
            let db = 40.0 * log10(ratio)
            if db >= -144.0 && db <= 12.0 {
                return db
            }
        }
        return nil
    }

    /// Scan an AuCO body for output routing label strings.
    private static func extractOutputRouting(body: Data) -> String? {
        // Scan body as ASCII for strings containing Output/Bus/Stereo Out
        let ascii = String(body.map { b -> Character in
            let s = Unicode.Scalar(b)
            return s.value >= 32 && s.value < 127 ? Character(s) : Character(" ")
        })

        let keywords = ["Stereo Out", "Output", "Bus"]
        for keyword in keywords {
            if let range = ascii.range(of: keyword) {
                // Extract surrounding word (up to 32 chars)
                let start = ascii.index(range.lowerBound, offsetBy: -min(0, ascii.distance(from: ascii.startIndex, to: range.lowerBound)))
                var end = range.upperBound
                var count = 0
                while end < ascii.endIndex && count < 20 {
                    let c = ascii[end]
                    if c == "\0" || c.asciiValue.map({ $0 < 32 }) ?? false { break }
                    end = ascii.index(after: end)
                    count += 1
                }
                let label = String(ascii[start..<end]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { return label }
            }
        }
        return nil
    }

    // MARK: - Plugin List

    /// Extract plugin names from null-ID (00 00 00 00) chunks.
    ///
    /// Per spec, these chunks have id "####" or all-zero bytes.
    /// The body contains ASCII plugin name signatures.
    private static func extractPlugins(chunks: [ChunkInfo], data: Data) -> [String] {
        var plugins = Set<String>()

        // Known plugin name keywords to search for
        let knownPlugins = [
            "Serum", "Valhalla", "Compressor", "Kontakt", "Massive", "Diva",
            "Sylenth", "Omnisphere", "Nexus", "Spire", "Vital", "Pigments",
            "Reverb", "Delay", "Limiter", "EQ", "Transient", "Saturn",
            "Vintage", "FabFilter", "iZotope", "Waves", "Native Instruments",
        ]

        for chunk in chunks {
            // Null-ID chunks: all 4 ID bytes are non-ASCII (or the reversed ID is "####")
            // The id field will be empty or contain non-printable chars when OID=0 and ID=0x00000000
            guard chunk.id.isEmpty || chunk.id == "\0\0\0\0" || isNullID(chunk.id) else { continue }
            guard chunk.bodyLength > 4, chunk.bodyLength < 10_000_000 else { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            let ascii = body.map { b -> Character in
                let s = Unicode.Scalar(b)
                return s.value >= 32 && s.value < 127 ? Character(s) : Character("\0")
            }
            let bodyStr = String(ascii)

            for plugin in knownPlugins where bodyStr.contains(plugin) {
                plugins.insert(plugin)
            }

            // Also extract any ASCII strings > 4 chars that look like plugin names
            // (contiguous printable chars, starts with uppercase, no spaces or common delimiters)
            var i = bodyStr.startIndex
            while i < bodyStr.endIndex {
                let c = bodyStr[i]
                guard c.isUppercase else { i = bodyStr.index(after: i); continue }

                var j = bodyStr.index(after: i)
                while j < bodyStr.endIndex {
                    let cc = bodyStr[j]
                    if !cc.isLetter && !cc.isNumber && cc != " " && cc != "-" && cc != "_" { break }
                    j = bodyStr.index(after: j)
                }

                let word = String(bodyStr[i..<j])
                if word.count >= 4 && word.count <= 40
                    && word.first?.isUppercase == true
                    && !word.allSatisfy({ $0.isUppercase }) // avoid all-caps constants
                {
                    // Heuristic: if it looks like a product name (mixed case), keep it
                    let hasLower = word.contains(where: { $0.isLowercase })
                    if hasLower { plugins.insert(word) }
                }
                i = j
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
    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        return String(reversed.compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII ? ch : nil
        })
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
