import ApplicationServices
import Foundation

/// Extract typed values from AX elements.
/// These handle the various ways Logic Pro represents values in its AX tree.
enum AXValueExtractors {
    /// Extract a numeric value from a slider (volume fader, pan knob, etc.)
    /// Returns the AXValue as a Double, or nil if unavailable.
    static func extractSliderValue(_ element: AXUIElement) -> Double? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // AXSlider values can come as NSNumber or CFNumber
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        // Try string-based value and parse
        if let str = value as? String, let parsed = Double(str) {
            return parsed
        }
        return nil
    }

    /// Extract a text value from a static text or text field element.
    /// Used for tempo display, position readout, track names, etc.
    static func extractTextValue(_ element: AXUIElement) -> String? {
        // Try kAXValueAttribute first (text fields, static text)
        if let value = AXHelpers.getValue(element) as? String {
            return value
        }
        // Fallback to kAXTitleAttribute
        return AXHelpers.getTitle(element)
    }

    /// Extract a boolean state from a button or checkbox element.
    /// For toggle buttons (mute, solo, arm, cycle, metronome), the value
    /// indicates pressed/active state.
    static func extractButtonState(_ element: AXUIElement) -> Bool? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // Toggle buttons typically report 0/1 as NSNumber
        if let number = value as? NSNumber {
            return number.boolValue
        }
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract checkbox state (a variant of button state, but checks kAXValueAttribute specifically).
    static func extractCheckboxState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXValueAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        return nil
    }

    /// Extract the selected state of an element.
    static func extractSelectedState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXSelectedAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Extract slider range (min/max) for interpreting fader values.
    struct SliderRange {
        let min: Double
        let max: Double
    }

    static func extractSliderRange(_ element: AXUIElement) -> SliderRange? {
        guard let minVal: AnyObject = AXHelpers.getAttribute(element, kAXMinValueAttribute),
              let maxVal: AnyObject = AXHelpers.getAttribute(element, kAXMaxValueAttribute),
              let min = (minVal as? NSNumber)?.doubleValue,
              let max = (maxVal as? NSNumber)?.doubleValue else {
            return nil
        }
        return SliderRange(min: min, max: max)
    }

    /// Read a track header and extract its full state including type, mute/solo/arm, and output routing.
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractTrackButtonState(from: header, prefix: "Mute") ?? false
        let soloed = extractTrackButtonState(from: header, prefix: "Solo") ?? false
        let armed = extractTrackButtonState(from: header, prefix: "Record") ?? false
        let selected = extractSelectedState(header) ?? false
        let trackType = inferTrackType(from: header)
        let output = extractOutputRouting(from: header)

        return TrackState(
            id: index,
            name: name,
            type: trackType,
            isMuted: muted,
            isSoloed: soloed,
            isArmed: armed,
            isSelected: selected,
            volume: 0.0,
            pan: 0.0,
            color: extractTrackColor(from: header),
            outputRouting: output
        )
    }

    /// Read transport bar elements and build a TransportState.
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        // Find and read transport button states
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            let pressed = extractButtonState(button) ?? false
            let descLower = desc.lowercased()

            if descLower.contains("play") {
                state.isPlaying = pressed
            } else if descLower.contains("record") && !descLower.contains("arm") {
                state.isRecording = pressed
            } else if descLower.contains("cycle") || descLower.contains("loop") {
                state.isCycleEnabled = pressed
            } else if descLower.contains("metronome") || descLower.contains("click") {
                state.isMetronomeEnabled = pressed
            }
        }

        // Find text fields for tempo, position
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if descLower.contains("position") || value.contains(".") && value.contains(":") == false {
                // Bar.Beat.Division.Tick format
                if value.filter({ $0 == "." }).count >= 2 {
                    state.position = value
                }
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Marker extraction

    /// Extract arrangement markers from the Logic Pro AX tree.
    ///
    /// Logic Pro exposes markers in several locations depending on version:
    ///   1. A dedicated "Marker Track" / "Marker List" in the arrangement
    ///   2. Within the arrangement ruler area
    ///   3. Via a pop-up marker list accessible from the marker track header
    ///
    /// This method attempts each strategy in order and returns whatever it finds.
    static func extractMarkers() -> [MarkerState] {
        var markers: [MarkerState] = []

        guard let window = AXLogicProElements.mainWindow() else { return markers }

        // Strategy 1: Look for elements with "marker" in identifier or description
        let markerCandidates = findMarkerElements(in: window)
        if !markerCandidates.isEmpty {
            for (index, element) in markerCandidates.enumerated() {
                if let marker = markerFromElement(element, index: index) {
                    markers.append(marker)
                }
            }
            if !markers.isEmpty { return markers }
        }

        // Strategy 2: Scan the arrangement area for marker-like rows
        if let arrangement = AXLogicProElements.getArrangementArea() {
            let rows = AXHelpers.findAllDescendants(of: arrangement, role: kAXRowRole, maxDepth: 4)
            for (index, row) in rows.enumerated() {
                let desc = AXHelpers.getDescription(row)?.lowercased() ?? ""
                let title = AXHelpers.getTitle(row)?.lowercased() ?? ""
                if desc.contains("marker") || title.contains("marker") {
                    if let marker = markerFromElement(row, index: index) {
                        markers.append(marker)
                    }
                }
            }
        }

        return markers
    }

    private static func findMarkerElements(in root: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        // Search for groups or rows whose description contains "marker"
        let groups = AXHelpers.findAllDescendants(of: root, role: kAXGroupRole, maxDepth: 8)
        for group in groups {
            let desc = AXHelpers.getDescription(group)?.lowercased() ?? ""
            let id = AXHelpers.getIdentifier(group)?.lowercased() ?? ""
            if desc.contains("marker") || id.contains("marker") {
                let children = AXHelpers.getChildren(group)
                if children.isEmpty {
                    results.append(group)
                } else {
                    results.append(contentsOf: children)
                }
            }
        }
        return results
    }

    private static func markerFromElement(_ element: AXUIElement, index: Int) -> MarkerState? {
        // Try to get the marker name and position
        let name = AXHelpers.getTitle(element)
            ?? AXHelpers.getDescription(element)
            ?? extractTextValue(element)
            ?? "Marker \(index + 1)"

        // Skip empty or obviously non-marker elements
        let nameLower = name.lowercased()
        if nameLower.isEmpty || nameLower == "marker track" { return nil }

        // Try to find a position value in child text elements
        var positionStr = "1.1.1.1"
        var barNumber: Int? = nil
        let texts = AXHelpers.findAllDescendants(of: element, role: kAXStaticTextRole, maxDepth: 3)
        for text in texts {
            if let val = extractTextValue(text) {
                // Bar.Beat.Division.Tick format: digits separated by dots
                if val.filter({ $0 == "." }).count >= 2, let firstComponent = val.components(separatedBy: ".").first, let bar = Int(firstComponent) {
                    positionStr = val
                    barNumber = bar
                    break
                }
                // Pure bar number
                if let bar = Int(val.trimmingCharacters(in: .whitespaces)) {
                    positionStr = "\(bar).1.1.1"
                    barNumber = bar
                    break
                }
            }
        }

        return MarkerState(id: index, name: name, position: positionStr, bar: barNumber)
    }

    // MARK: - Private helpers

    private static func extractTrackName(from header: AXUIElement) -> String {
        // Try static text first
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3),
           let name = extractTextValue(text), !name.isEmpty {
            return name
        }
        // Try text field
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3),
           let name = extractTextValue(field), !name.isEmpty {
            return name
        }
        return AXHelpers.getTitle(header) ?? "Untitled"
    }

    private static func extractTrackButtonState(from header: AXUIElement, prefix: String) -> Bool? {
        let buttons = AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            if desc.hasPrefix(prefix) || desc.lowercased().contains(prefix.lowercased()) {
                return extractButtonState(button)
            }
        }
        return nil
    }

    private static func inferTrackType(from header: AXUIElement) -> TrackType {
        // Attempt to infer type from icon description or element identifiers
        let desc = AXHelpers.getDescription(header)?.lowercased() ?? ""
        let title = AXHelpers.getTitle(header)?.lowercased() ?? ""
        // Also check child elements for type indicators (e.g. instrument icon labels)
        let childDescriptions = AXHelpers.getChildren(header).compactMap {
            AXHelpers.getDescription($0)?.lowercased()
        }.joined(separator: " ")
        let combined = desc + " " + title + " " + childDescriptions

        if combined.contains("audio") { return .audio }
        if combined.contains("instrument") || combined.contains("software") { return .softwareInstrument }
        if combined.contains("drummer") { return .drummer }
        if combined.contains("external") || combined.contains("midi") { return .externalMIDI }
        if combined.contains("aux") { return .aux }
        if combined.contains("bus") { return .bus }
        if combined.contains("master") || combined.contains("stereo out") { return .master }
        return .unknown
    }

    /// Extract output routing label from a track header.
    /// Logic Pro may expose the output assignment as a popup button or static text
    /// labeled "Output", "Stereo Out", "Bus N", etc.
    private static func extractOutputRouting(from header: AXUIElement) -> String? {
        // Look for popup buttons (output selectors are typically AXPopUpButton)
        let popups = AXHelpers.findAllDescendants(of: header, role: kAXPopUpButtonRole, maxDepth: 4)
        for popup in popups {
            let desc = AXHelpers.getDescription(popup)?.lowercased() ?? ""
            let title = AXHelpers.getTitle(popup) ?? ""
            if desc.contains("output") || desc.contains("out") {
                return title.isEmpty ? nil : title
            }
        }
        // Fallback: static text that looks like an output label
        let statics = AXHelpers.findAllDescendants(of: header, role: kAXStaticTextRole, maxDepth: 4)
        for text in statics {
            if let val = extractTextValue(text) {
                let lower = val.lowercased()
                if lower.contains("stereo out") || lower.contains("bus ") || lower.contains("output") {
                    return val
                }
            }
        }
        return nil
    }

    private static func extractTrackColor(from header: AXUIElement) -> String? {
        // Logic Pro may expose color via a custom attribute or the element's description
        let desc = AXHelpers.getDescription(header) ?? ""
        if desc.lowercased().contains("color") {
            return desc
        }
        return nil
    }
}
