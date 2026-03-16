import ApplicationServices
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return getTransportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome")
        case "transport.toggle_count_in":
            return toggleTransportButton(named: "Count In")
        case "transport.set_tempo":
            return setTempo(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return selectTrack(params: params)
        case "track.set_mute":
            return setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return renameTrack(params: params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Mixer reads
        case "mixer.get_state":
            return getMixerState()
        case "mixer.get_channel_strip":
            return getChannelStrip(params: params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return setMixerValue(params: params, target: .volume)
        case "mixer.set_pan":
            return setMixerValue(params: params, target: .pan)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - Navigation
        case "nav.get_markers":
            return getMarkers()
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return getProjectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard AXIsProcessTrusted() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard AXLogicProElements.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Direct synchronous AX reads (for ResourceHandlers one-shot queries)

    /// Directly read transport state from AX (bypasses cache).
    func readTransportStateDirect() -> TransportState? {
        guard AXIsProcessTrusted(), ProcessUtils.isLogicProRunning else { return nil }
        guard let transport = AXLogicProElements.getTransportBar() else { return nil }
        return AXValueExtractors.extractTransportState(from: transport)
    }

    /// Directly read all tracks from AX (bypasses cache).
    func readTracksDirect() -> [TrackState]? {
        guard AXIsProcessTrusted(), ProcessUtils.isLogicProRunning else { return nil }
        let headers = AXLogicProElements.allTrackHeaders()
        guard !headers.isEmpty else { return nil }
        return headers.enumerated().map { (index, header) in
            AXValueExtractors.extractTrackState(from: header, index: index)
        }
    }

    /// Directly read all channel strips from AX (bypasses cache).
    func readMixerDirect() -> [ChannelStripState]? {
        guard AXIsProcessTrusted(), ProcessUtils.isLogicProRunning else { return nil }
        guard let mixer = AXLogicProElements.getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard !strips.isEmpty else { return nil }
        return strips.enumerated().map { (index, strip) in
            let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
            let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
            let pan = sliders.count > 1
                ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
                : 0.0
            return ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        }
    }

    /// Directly read project info from AX (bypasses cache).
    func readProjectInfoDirect() -> ProjectInfo? {
        guard AXIsProcessTrusted(), ProcessUtils.isLogicProRunning else { return nil }
        guard let window = AXLogicProElements.mainWindow() else { return nil }
        let rawTitle = AXHelpers.getTitle(window) ?? ""
        var info = ProjectInfo()
        // Window title is typically "<project name> - Logic Pro"
        if let dashRange = rawTitle.range(of: " - Logic Pro") {
            info.name = String(rawTitle[rawTitle.startIndex..<dashRange.lowerBound])
        } else if rawTitle.contains("Logic Pro") {
            info.name = "Untitled"
        } else {
            info.name = rawTitle.isEmpty ? "Untitled" : rawTitle
        }
        // Attempt to read tempo + time signature from transport bar
        if let transport = AXLogicProElements.getTransportBar() {
            let state = AXValueExtractors.extractTransportState(from: transport)
            info.tempo = state.tempo
            info.sampleRate = state.sampleRate
        }
        info.lastUpdated = Date()
        return info
    }

    /// Directly read all arrangement markers from AX (bypasses cache).
    func readMarkersDirect() -> [MarkerState]? {
        guard AXIsProcessTrusted(), ProcessUtils.isLogicProRunning else { return nil }
        return AXValueExtractors.extractMarkers()
    }

    // MARK: - Transport

    private func getTransportState() -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport)
        return encodeResult(state)
    }

    private func toggleTransportButton(named name: String) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    private func setTempo(params: [String: String]) -> ChannelResult {
        guard let tempoStr = params["tempo"] ?? params["bpm"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        // Find the tempo text field and set its value
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXTextFieldRole, maxDepth: 4)
        for field in texts {
            let desc = AXHelpers.getDescription(field)?.lowercased() ?? ""
            if desc.contains("tempo") || desc.contains("bpm") {
                AXHelpers.setAttribute(field, kAXValueAttribute, tempoStr as CFTypeRef)
                AXHelpers.performAction(field, kAXConfirmAction)
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }
        return .error("Cannot locate tempo field")
    }

    private func setCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private func getTracks() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private func getSelectedTrack() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header) == true {
                let track = AXValueExtractors.extractTrackState(from: header, index: index)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    private func selectTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction) else {
            return .error("Failed to select track \(index)")
        }
        return .success("{\"selected\":\(index)}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to click \(buttonName) on track \(index)")
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(buttonName)\"}")
    }

    private func renameTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
            return .error("Cannot find name field for track \(index)")
        }
        // Double-click to enter edit mode, then set value
        AXHelpers.performAction(field, kAXPressAction)
        AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef)
        AXHelpers.performAction(field, kAXConfirmAction)
        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    // MARK: - Mixer

    private enum MixerTarget {
        case volume
        case pan
    }

    private func getMixerState() -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
            let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
            let pan = sliders.count > 1
                ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
                : 0.0

            channelStrips.append(ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            ))
        }
        return encodeResult(channelStrips)
    }

    private func getChannelStrip(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
        let pan = sliders.count > 1
            ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
            : 0.0

        let state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        return encodeResult(state)
    }

    private func setMixerValue(params: [String: String], target: MixerTarget) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'index' or 'value' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value))
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
    }

    // MARK: - Markers

    private func getMarkers() -> ChannelResult {
        let markers = AXValueExtractors.extractMarkers()
        if markers.isEmpty {
            return .error("No markers found — is a project with markers open?")
        }
        return encodeResult(markers)
    }

    // MARK: - Project

    private func getProjectInfo() -> ChannelResult {
        if let info = readProjectInfoDirect() {
            return encodeResult(info)
        }
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - JSON encoding

    private func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        do {
            let data = try JSONEncoder().encode(value)
            let str = String(data: data, encoding: .utf8) ?? "{}"
            return .success(str)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Bounce Dialog Automation

    /// Best-effort automation of the Logic Pro bounce dialog.
    ///
    /// NOTE: This is version-sensitive and may break between Logic updates.
    ///
    /// Steps attempted:
    ///   1. Find a window whose title contains "Bounce" in the Logic Pro AX tree.
    ///   2. If `destination` is provided, locate a text field and set its value.
    ///   3. If `clickBounce` is true, find and press the "Bounce" button.
    ///
    /// Returns a ChannelResult describing what was done (or why it failed).
    func completeBounceDialog(destination: String?, clickBounce: Bool) -> ChannelResult {
        guard AXIsProcessTrusted() else {
            return .error("Accessibility not trusted — cannot automate bounce dialog")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        // Find the bounce dialog window
        guard let appRoot = AXLogicProElements.appRoot() else {
            return .error("Cannot access Logic Pro AX element")
        }

        // Walk windows looking for one whose title contains "Bounce"
        let windows: [AXUIElement] = AXHelpers.getAttribute(appRoot, kAXWindowsAttribute) ?? []
        var bounceWindow: AXUIElement? = nil
        for window in windows {
            let title = AXHelpers.getTitle(window) ?? ""
            if title.lowercased().contains("bounce") {
                bounceWindow = window
                break
            }
        }

        // Also try sheets / dialogs attached to the main window
        if bounceWindow == nil {
            if let mainWin = AXLogicProElements.mainWindow() {
                let sheet = AXHelpers.findDescendant(of: mainWin, role: "AXSheet", maxDepth: 3)
                    ?? AXHelpers.findDescendant(of: mainWin, role: kAXWindowRole, maxDepth: 3)
                if let s = sheet {
                    let title = AXHelpers.getTitle(s) ?? ""
                    if title.lowercased().contains("bounce") || title.isEmpty {
                        bounceWindow = s
                    }
                }
            }
        }

        guard let dialog = bounceWindow else {
            return .error(
                "Bounce dialog not found. Use bounce_section first to open it, " +
                "then call bounce_complete. If the dialog is open but this fails, " +
                "complete the bounce manually — AX dialog detection may differ in this Logic version."
            )
        }

        var steps: [String] = []

        // Set destination path if provided
        if let dest = destination, !dest.isEmpty {
            // Look for a text field — typical label is "Destination" or similar
            let textFields = AXHelpers.findAllDescendants(of: dialog, role: kAXTextFieldRole, maxDepth: 6)
            if let field = textFields.first {
                AXHelpers.setAttribute(field, kAXValueAttribute, dest as CFTypeRef)
                AXHelpers.performAction(field, kAXConfirmAction)
                steps.append("set destination to '\(dest)'")
            } else {
                steps.append("WARNING: could not find destination text field")
            }
        }

        // Click the Bounce button
        if clickBounce {
            // Search for a button titled "Bounce" or "OK" inside the dialog
            let buttons = AXHelpers.findAllDescendants(of: dialog, role: kAXButtonRole, maxDepth: 6)
            let bounceBtn = buttons.first(where: {
                let t = AXHelpers.getTitle($0)?.lowercased() ?? ""
                return t == "bounce" || t == "ok" || t == "export"
            })
            if let btn = bounceBtn {
                let btnTitle = AXHelpers.getTitle(btn) ?? "?"
                AXHelpers.performAction(btn, kAXPressAction)
                steps.append("clicked '\(btnTitle)' button")
            } else {
                steps.append("WARNING: could not find Bounce/OK button — complete manually")
            }
        }

        let summary = steps.isEmpty ? "Bounce dialog found but no actions taken" : steps.joined(separator: "; ")
        return .success("bounce_complete: \(summary)")
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
