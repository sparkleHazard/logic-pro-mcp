import Foundation

// MARK: - ProjectDataParser

/// Parses Logic Pro binary ProjectData files to extract arrangement markers,
/// tempo maps, track names, and time signatures — without using the Accessibility API.
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

    // Arrangement marker OIDs per RE findings: 4, 8, 12, 16, 20, 24, 28, 32, 36
    private static let markerOIDs: Set<UInt32> = [4, 8, 12, 16, 20, 24, 28, 32, 36]

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
        let tempoMap = extractTempoMap(chunks: chunks, data: data)
        let parsedTracks = extractTracks(chunks: chunks, data: data)

        // Join marker names with positions
        let markers = buildMarkers(txSqMap: txSqMap, events: evSqMarkerEvents)

        // Time signature from plists
        let timeSignature = logicxURL.flatMap { readTimeSignature(logicx: $0) } ?? "4/4"
        let sampleRate = logicxURL.flatMap { readSampleRate(logicx: $0) } ?? 0

        var info = ProjectDataInfo()
        info.markers = markers
        info.tempoMap = tempoMap
        info.tracks = parsedTracks
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

    /// Extract RTF text from TxSq chunks for arrangement marker OIDs.
    /// Returns a map of OID -> cleaned name.
    private static func extractTxSqNames(chunks: [ChunkInfo], data: Data) -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        for chunk in chunks where chunk.id == idTxSq {
            guard markerOIDs.contains(chunk.oid) else { continue }
            guard chunk.bodyLength > 0 else { continue }
            let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]
            if let name = extractRTFText(body) {
                result[chunk.oid] = name
            }
        }
        return result
    }

    /// Extract plain text from an RTF body.
    /// RTF starts with `{\rtf1`. We strip all `\cmdN` tags and braces.
    private static func extractRTFText(_ body: Data) -> String? {
        guard let raw = String(data: body, encoding: .utf8)
                ?? String(data: body, encoding: .isoLatin1)
        else { return nil }

        // Must be RTF
        guard raw.contains("{\\rtf") else {
            // Try treating it as a direct pascal-style or length-prefixed string
            return extractDirectString(body)
        }

        // Find content after \fs<N> tag (font size, precedes actual text)
        // Strategy: strip everything inside { } control blocks, then trim
        let text = raw

        // Remove all RTF control words (\word or \word<N>) and special chars
        // We use a simple state-machine approach:
        var result = ""
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" || ch == "}" {
                i = text.index(after: i)
                continue
            }
            if ch == "\\" {
                // Skip control word or symbol
                let next = text.index(after: i)
                if next < text.endIndex {
                    let nc = text[next]
                    if nc == "\\" || nc == "{" || nc == "}" || nc == ";" || nc == "\n" || nc == "\r" {
                        // Escaped char
                        if nc == "\\" || nc == "{" || nc == "}" {
                            result.append(nc)
                        }
                        i = text.index(after: next)
                        continue
                    }
                    if nc == "'" {
                        // Hex escape \'XX
                        let h1 = text.index(next, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                        let h2 = text.index(next, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                        let h3 = text.index(next, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                        if h1 < text.endIndex && h2 < text.endIndex {
                            let hexStr = String(text[h1..<h2])
                            if let code = UInt32(hexStr, radix: 16),
                               let scalar = Unicode.Scalar(code) {
                                result.append(Character(scalar))
                            }
                            i = h3 < text.endIndex ? h3 : text.endIndex
                        } else {
                            i = text.index(after: next)
                        }
                        continue
                    }
                    if nc.isLetter || nc == "-" {
                        // Control word: skip until non-alphanumeric (and skip optional numeric param + optional space)
                        var j = next
                        while j < text.endIndex && (text[j].isLetter || text[j] == "-") {
                            j = text.index(after: j)
                        }
                        // skip optional numeric parameter
                        if j < text.endIndex && (text[j].isNumber || text[j] == "-") {
                            while j < text.endIndex && (text[j].isNumber || text[j] == "-") {
                                j = text.index(after: j)
                            }
                        }
                        // skip single trailing space
                        if j < text.endIndex && text[j] == " " {
                            j = text.index(after: j)
                        }
                        i = j
                        continue
                    }
                }
                i = text.index(after: i)
                continue
            }
            if ch == "\n" || ch == "\r" {
                i = text.index(after: i)
                continue
            }
            result.append(ch)
            i = text.index(after: i)
        }

        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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
            let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]
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
                && markerOIDs.contains(m0)
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

    /// Extract tempo events from EvSq chunks.
    ///
    /// Tempo events follow the pattern:
    ///   7F 00 00 01  [MM MM MM MM] [00 00 00 00] [PP PP PP PP PP PP PP PP]
    /// where MM = millitempo (LE u32), PP = tick position (LE u64, but we read u32 for simplicity).
    private static func extractTempoMap(chunks: [ChunkInfo], data: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []

        for chunk in chunks where chunk.id == idEvSq {
            guard chunk.bodyLength >= 20 else { continue }
            let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]
            let tempos = parseTempoEvents(body: body)
            entries.append(contentsOf: tempos)
        }

        // Sort by tick and deduplicate
        entries.sort { $0.tick < $1.tick }
        var seen = Set<Int>()
        return entries.filter { seen.insert($0.tick).inserted }
    }

    private static func parseTempoEvents(body: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []
        let bytes = body
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
            let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]

            guard body.count > 0x12 else { continue }
            let nameLen = Int(readLE16(body, at: 0x10))
            guard nameLen > 0, 0x12 + nameLen <= body.count else { continue }

            guard let name = String(data: body[0x12..<(0x12 + nameLen)], encoding: .utf8)
                    ?? String(data: body[0x12..<(0x12 + nameLen)], encoding: .isoLatin1)
            else { continue }

            let cleaned = name.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            guard !cleaned.isEmpty else { continue }

            if seen.insert(chunk.oid).inserted {
                result.append(ParsedTrack(name: cleaned, oid: Int(chunk.oid)))
            }
        }
        return result
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

        var markers: [ParsedMarker] = []

        for (oid, name) in txSqMap {
            guard let event = eventMap[oid] else { continue }
            let tick = Int(event.startTick)
            let bar = tick / ticksPerBar + 1
            let durationTicks = Int(event.durationTicks)
            let durationBars = durationTicks > 0 ? max(1, durationTicks / ticksPerBar) : 0

            markers.append(ParsedMarker(
                name: name,
                bar: bar,
                tick: tick,
                durationTicks: durationTicks,
                durationBars: durationBars,
                oid: Int(oid)
            ))
        }

        // Sort by bar position
        markers.sort { $0.bar < $1.bar }
        return markers
    }

    // MARK: - Plist Parsing (Time Signature, Sample Rate)

    /// Read time signature from MetaData.plist or ProjectInformation.plist.
    private static func readTimeSignature(logicx: URL) -> String? {
        let candidates = [
            logicx.appendingPathComponent("MetaData.plist"),
            logicx.appendingPathComponent("ProjectInformation.plist"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            if let sig = searchPlistForTimeSignature(plist) { return sig }
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
        let candidates = [
            logicx.appendingPathComponent("MetaData.plist"),
            logicx.appendingPathComponent("ProjectInformation.plist"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            if let sr = searchPlistForSampleRate(plist) { return sr }
        }
        return nil
    }

    private static func searchPlistForSampleRate(_ plist: Any) -> Int? {
        if let dict = plist as? [String: Any] {
            for key in ["SampleRate", "sampleRate", "sample_rate"] {
                if let v = dict[key] {
                    if let i = v as? Int { return i }
                    if let d = v as? Double { return Int(d) }
                    if let s = v as? String, let i = Int(s) { return i }
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

// MARK: - AppleScript Helper

/// Run AppleScript synchronously and return the string result, or nil on error.
/// Used to get the current Logic Pro project path.
func runAppleScript(_ source: String) -> String? {
    var errorDict: NSDictionary?
    let script = NSAppleScript(source: source)
    let result = script?.executeAndReturnError(&errorDict)
    if errorDict != nil { return nil }
    return result?.stringValue
}

/// Get the POSIX path of the front Logic Pro document via AppleScript.
func currentLogicProProjectPath() -> String? {
    let source = """
    tell application "Logic Pro" to get POSIX path of (file of front document)
    """
    return runAppleScript(source)
}
