import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot() -> AXUIElement? {
        guard let pid = ProcessUtils.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid)
    }

    /// Get the main window element.
    static func mainWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMainWindowAttribute)
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro's transport is typically an AXToolbar or AXGroup near the top
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole) {
            return toolbar
        }
        // Fallback: search for a group containing transport-like buttons
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport")
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String) -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: name) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            if AXHelpers.getDescription(button) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the track header area containing individual track rows.
    static func getTrackHeaders() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Track headers are typically in a scrollable list/table area
        if let area = AXHelpers.findDescendant(of: window, role: kAXListRole, identifier: "Track Headers") {
            return area
        }
        // Fallback: look for an AXScrollArea containing AXRow or AXGroup children
        if let area = AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Tracks") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXOutlineRole, maxDepth: 5)
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int) -> AXUIElement? {
        guard let headers = getTrackHeaders() else { return nil }
        let rows = AXHelpers.getChildren(headers)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders() -> [AXUIElement] {
        guard let headers = getTrackHeaders() else { return [] }
        return AXHelpers.getChildren(headers)
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // The mixer typically appears as a distinct group/scroll area
        if let mixer = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Mixer") {
            return mixer
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Mixer")
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Fader is an AXSlider within the channel strip
        return AXHelpers.findDescendant(of: strip, role: kAXSliderRole, maxDepth: 4)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Pan is typically the second slider or a knob-type element
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        // Convention: first slider = volume, second = pan (if present)
        return sliders.count > 1 ? sliders[1] : nil
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String]) -> AXUIElement? {
        guard var current = getMenuBar() else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    /// Click a menu item by navigating the full path, opening each level in sequence.
    ///
    /// Example: `clickMenuItem(path: ["Navigate", "Set Locators by Selection and Enable Cycle"])`
    ///
    /// The menu bar must be accessed from the app root. Each path segment:
    ///   1. Finds the matching child element.
    ///   2. Presses it (AXPress) to open the submenu.
    ///   3. Pauses briefly to allow the menu to render.
    ///   4. Moves into the opened menu before looking for the next title.
    ///
    /// Returns true if the final item was successfully pressed.
    @discardableResult
    static func clickMenuItem(path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        guard let menuBar = getMenuBar() else {
            Log.warn("clickMenuItem: could not access menu bar", subsystem: "ax")
            return false
        }

        // Step 1: Find and open the top-level menu bar item (e.g. "Navigate")
        let topTitle = path[0]
        let barItems = AXHelpers.getChildren(menuBar)
        guard let barItem = barItems.first(where: { AXHelpers.getTitle($0) == topTitle }) else {
            Log.warn("clickMenuItem: top-level menu '\(topTitle)' not found", subsystem: "ax")
            return false
        }

        // Press the menu bar item to open the pull-down menu
        guard AXHelpers.performAction(barItem, kAXPressAction) else {
            Log.warn("clickMenuItem: failed to open menu '\(topTitle)'", subsystem: "ax")
            return false
        }
        Thread.sleep(forTimeInterval: 0.15)

        // Step 2: Navigate remaining path segments through opened menus
        // After pressing a menu bar item, AX exposes the menu via kAXMenuAttribute or as a child.
        var currentMenu: AXUIElement = barItem
        let remainingPath = Array(path.dropFirst())

        for (segIdx, segTitle) in remainingPath.enumerated() {
            // Resolve the open menu: try kAXMenuAttribute first, then children
            let openMenu: AXUIElement
            if let menu: AXUIElement = AXHelpers.getAttribute(currentMenu, "AXMenu") {
                openMenu = menu
            } else {
                // The bar item's children include the menu element
                let kids = AXHelpers.getChildren(currentMenu)
                guard let m = kids.first(where: { AXHelpers.getRole($0) == kAXMenuRole }) else {
                    // Try pressing — current may already be an open menu
                    openMenu = currentMenu
                    _ = openMenu  // suppress warning
                    // Fall through and search children directly
                    let menuItems = AXHelpers.getChildren(currentMenu)
                    guard let item = menuItemMatching(segTitle, in: menuItems) else {
                        Log.warn("clickMenuItem: item '\(segTitle)' not found in menu", subsystem: "ax")
                        return false
                    }
                    let isLast = segIdx == remainingPath.count - 1
                    guard AXHelpers.performAction(item, kAXPressAction) else {
                        Log.warn("clickMenuItem: failed to press '\(segTitle)'", subsystem: "ax")
                        return false
                    }
                    if !isLast { Thread.sleep(forTimeInterval: 0.15) }
                    currentMenu = item
                    continue
                }
                openMenu = m
            }

            let menuItems = AXHelpers.getChildren(openMenu)
            guard let item = menuItemMatching(segTitle, in: menuItems) else {
                Log.warn("clickMenuItem: item '\(segTitle)' not found under '\(path[segIdx])'", subsystem: "ax")
                return false
            }

            let isLast = segIdx == remainingPath.count - 1
            guard AXHelpers.performAction(item, kAXPressAction) else {
                Log.warn("clickMenuItem: failed to press '\(segTitle)'", subsystem: "ax")
                return false
            }
            if !isLast { Thread.sleep(forTimeInterval: 0.15) }
            currentMenu = item
        }

        return true
    }

    /// Find a menu item within a list of AX elements whose title matches (exact, then prefix).
    private static func menuItemMatching(_ title: String, in items: [AXUIElement]) -> AXUIElement? {
        // Exact match first
        if let exact = items.first(where: { AXHelpers.getTitle($0) == title }) {
            return exact
        }
        // Case-insensitive contains fallback
        return items.first(where: {
            AXHelpers.getTitle($0)?.localizedCaseInsensitiveContains(title) == true
        })
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Arrangement") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Arrangement")
    }

    // MARK: - Track Controls

    /// Find the mute button on a track header.
    static func findTrackMuteButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Mute")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "M")
    }

    /// Find the solo button on a track header.
    static func findTrackSoloButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Solo")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "S")
    }

    /// Find the record-arm button on a track header.
    static func findTrackArmButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Record")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "R")
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4)
            ?? AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4)
    }

    // MARK: - Helpers

    private static func findButtonByDescriptionPrefix(
        in element: AXUIElement, prefix: String
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button) else { return false }
            return desc.hasPrefix(prefix)
        }
    }
}
