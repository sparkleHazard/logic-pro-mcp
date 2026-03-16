# Logic Pro MCP Server

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000.svg?logo=apple)](https://developer.apple.com/macos/)
[![MCP SDK 0.10](https://img.shields.io/badge/MCP_SDK-0.10-blue.svg)](https://github.com/modelcontextprotocol/swift-sdk)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Bidirectional, stateful control of Logic Pro from AI assistants. Combines **5 native macOS control channels** (CoreMIDI, Accessibility, CGEvent, AppleScript, OSC) into a single MCP server with smart routing, fallback chains, and sub-millisecond transport latency.

**8 tools, 9 resources, ~3k context tokens.** Not 100+ individual tools.

Forked from [koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp) with significant enhancements — binary ProjectData parser, extended track hierarchy, function group inference, automated stem bounce planning, additional resources, and bug fixes for cycle range and track solo/select.

## How It Works

```
Claude ──── 8 dispatcher tools ──── logic_transport("play", {})
         │                           logic_tracks("mute", {track: 3})
         │  9 MCP resources ──────── logic://transport/state
         │  (zero tool cost)         logic://tracks
         ▼
   ┌─── LogicProMCP ──────────────────────────────┐
   │  Command Dispatcher → Channel Router          │
   │     │       │       │       │       │         │
   │  CoreMIDI   AX    CGEvent  AS     OSC        │
   │   <1ms    ~15ms    <2ms   ~200ms  <1ms       │
   └───────────────────────────────────────────────┘
```

Each command routes through the fastest available channel, with automatic fallback if the primary fails.

## Features

- **8 dispatcher tools** covering transport, tracks, mixer, MIDI, editing, navigation, project lifecycle, and system diagnostics
- **9 MCP resources** serving live state as JSON at zero context cost
- **5 native macOS channels**: CoreMIDI, Accessibility API, CGEvent keyboard injection, AppleScript, OSC
- **Binary ProjectData parser** reads `.logicx` packages directly — no Logic running required
- **Track hierarchy** with summing stack detection and nesting depth inference
- **Function group inference** classifies tracks into groups (Guitars, Vocals, Drums, Keys/Synths, etc.)
- **Automated stem bounce planning** — plans per-group stem bounces from marker boundaries
- **Smart channel routing** with ordered fallback chains per operation
- **Adaptive state cache** with configurable polling intervals (500ms active → 5s idle)

## Binary Parser Capabilities

The `project.analyze` and `logic_project("analyze")` commands parse `.logicx` packages directly from disk:

| Capability | Details |
|------------|---------|
| Arrangement markers | Names, bar positions, tick offsets, durations |
| Tempo map | Initial BPM and all tempo changes with bar positions |
| Track names | From MSeq chunks; all named and stack container tracks |
| Time signature | From project plist (`4/4`, `3/4`, etc.) |
| Sample rate | From project plist (44100, 48000, 96000, etc.) |
| Audio file paths | All referenced audio files (AuFl chunks) |
| Audio regions | Per-track regions with start bar, length, audio file OID (AuRg chunks) |
| Track-to-region mapping | Links each region to its parent track |
| Output routing | Per-track routing labels from AuCO chunks ("Bus 3", "Output 1-2") |
| Volume / pan | Per-track normalized values from AuCO chunks |
| Plugin detection | Plugin names from PluginData chunks |
| Environment labels | Sub-track grouping labels from Envi chunks |
| Function group inference | 12 groups inferred from track names and routing |
| Channel strips | Full AuCO enumeration (449 strips vs 13 MSeq tracks in typical projects) |
| Song lengths | Per-song lengths from reference track regions or marker boundaries |

## Tools Reference

| Tool | Commands | Description |
|------|----------|-------------|
| `logic_transport` | play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, toggle_count_in, set_tempo, goto_position, set_cycle_range | Transport control and position |
| `logic_tracks` | select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, set_color | Track state and creation |
| `logic_mixer` | set_volume, set_pan, set_send, set_output, set_input, set_master_volume, toggle_eq, reset_strip, insert_plugin, bypass_plugin | Mixer and plugin control |
| `logic_midi` | send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, create_virtual_port, mmc_play, mmc_stop, mmc_record, mmc_locate | MIDI and MMC |
| `logic_edit` | undo, redo, cut, copy, paste, delete, select_all, split, join, quantize, bounce_in_place, normalize, duplicate | Editing operations |
| `logic_navigate` | goto_bar, goto_marker, create_marker, delete_marker, rename_marker, list_markers, zoom_to_fit, set_zoom, toggle_view | Navigation and markers |
| `logic_project` | new, open, save, save_as, close, bounce, bounce_section, bounce_complete, tracks_hierarchy, bounce_stems, song_lengths, launch, quit, analyze | Project lifecycle and analysis |
| `logic_system` | health, permissions, refresh_cache, help | Diagnostics and help |

### Key Parameter Notes

```
logic_transport("set_tempo", {tempo: 140})
logic_transport("goto_position", {bar: 17})
logic_transport("set_cycle_range", {start: "5.1.1.1", end: "21.1.1.1"})

logic_tracks("select", {index: 0})
logic_tracks("solo", {index: 2, enabled: true})
logic_tracks("rename", {index: 0, name: "Lead Vox"})

logic_mixer("set_volume", {track: 0, value: 0.85})   // 0.0–1.0 normalized
logic_mixer("set_pan", {track: 0, value: -0.5})       // -1.0 left … +1.0 right

logic_midi("send_note", {note: 60, velocity: 100, channel: 1, duration_ms: 500})
logic_midi("send_chord", {notes: [60,64,67], velocity: 90, channel: 1, duration_ms: 1000})

logic_navigate("toggle_view", {view: "mixer"})
logic_navigate("create_marker", {name: "Verse 1"})

logic_project("analyze", {path: "/path/to/Song.logicx"})
logic_project("bounce_stems", {marker_name: "Verse 1", groups: ["Guitars","Vocals"]})
```

## Resources Reference

| URI | Description | Refresh |
|-----|-------------|---------|
| `logic://transport/state` | Playing/recording/tempo/position/cycle state | 500ms |
| `logic://tracks` | All tracks with mute/solo/arm/selected states | 2s |
| `logic://tracks/{index}` | Single track detail by index | 2s |
| `logic://tracks/live` | Full live track list with nesting depth | 2s |
| `logic://mixer` | All channel strips: volume, pan | 2s |
| `logic://project/info` | Project name, tempo, sample rate, time signature | 5s |
| `logic://markers` | Arrangement markers (binary parser first, AX fallback) | on-demand |
| `logic://midi/ports` | Available MIDI input/output ports | 10s |
| `logic://system/health` | Channel status, cache snapshot, permissions | on-demand |

## Dependencies

### Build Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| **Swift** | 6.0+ | Language and compiler |
| **macOS SDK** | 14+ (Sonoma) | Target platform |
| **MCP Swift SDK** | 0.10+ | Model Context Protocol server framework |
| **Xcode Command Line Tools** | Latest | Build toolchain (`swift build`) |

The MCP Swift SDK is the only external Swift package dependency (fetched automatically by Swift Package Manager). All other frameworks used are system-provided:

### System Frameworks (no install required)

| Framework | Purpose |
|-----------|---------|
| `ApplicationServices` | Accessibility API (AXUIElement) for UI automation |
| `CoreMIDI` | Virtual MIDI ports, MMC transport, note/CC sending |
| `CoreGraphics` | CGEvent keyboard injection (postToPid, HID tap) |
| `AppKit` | NSPasteboard (clipboard), NSRunningApplication, NSAppleScript |
| `Foundation` | Process spawning, file I/O, JSON, property lists |
| `Network` | UDP sockets for OSC client/server |

### Runtime Dependencies

| Dependency | Required | Purpose |
|-----------|----------|---------|
| **Logic Pro** | Yes (for real-time control) | Target application. Binary parser works without Logic running. |
| **macOS Accessibility permission** | Yes | System Settings → Privacy & Security → Accessibility → add terminal/node |
| **macOS Automation permission** | Yes | Granted on first AppleScript interaction with Logic Pro |
| **macOS Screen Recording** | Optional | Only needed for peekaboo screenshot capture |
| `/usr/bin/osascript` | Yes (system-provided) | Used for focus-dependent keystrokes (solo, mute, cycle toggle) via System Events |

### Custom Logic Pro Key Commands (for automated bouncing)

The bounce automation requires two custom key commands assigned in Logic Pro's Key Commands editor (Option+K):

| Command | Suggested Shortcut | Purpose |
|---------|-------------------|---------|
| Set Left Locator to Playhead Position | `Cmd+Ctrl+[` | Sets cycle start point |
| Set Right Locator to Playhead Position | `Cmd+Ctrl+]` | Sets cycle end point |

These are used by `bounce_stems execute` to set precise cycle ranges for per-song stem bouncing.

## Installation

### Build from Source

Requires Swift 6.0+ and macOS 14+.

```bash
git clone https://github.com/alan1/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
sudo cp .build/release/LogicProMCP /usr/local/bin/
```

### Register with Claude Code

```bash
claude mcp add --scope user logic-pro -- /usr/local/bin/LogicProMCP
```

### Register with OpenCode

Add to your OpenCode MCP config (`~/.config/opencode/config.json` or equivalent):

```json
{
  "mcp": {
    "servers": {
      "logic-pro": {
        "command": "/usr/local/bin/LogicProMCP",
        "args": []
      }
    }
  }
}
```

### Register with OpenClaw / Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "logic-pro": {
      "command": "/usr/local/bin/LogicProMCP",
      "args": []
    }
  }
}
```

## Permissions Required

The server requires two macOS permissions, and optionally a third:

1. **Accessibility** — System Settings > Privacy & Security > Accessibility > add your terminal app (or the AI client app)
2. **Automation (Logic Pro)** — System Settings > Privacy & Security > Automation > allow control of Logic Pro
3. **Screen Recording** *(optional)* — needed if using peekaboo-based screenshot inspection of the Logic Pro UI

Check permission status at any time:

```bash
LogicProMCP --check-permissions
# or via tool:
# logic_system("permissions", {})
```

## Architecture

### Channel Routing

Each operation is mapped to an ordered list of channels in `ChannelRouter.swift`. The router tries each channel in order and returns the first success. Channels are skipped when unhealthy (e.g. Logic Pro not running, AX not trusted).

| Channel | Latency | Used For |
|---------|---------|----------|
| **CoreMIDI** | <1ms | Transport (MMC), note/CC/sysex/program change |
| **CGEvent** | <2ms | Keyboard shortcuts (`postToPid` — no focus needed), track navigation |
| **Accessibility** | ~15ms | State reads, UI clicks (mute/solo/arm buttons, tempo field, locators) |
| **AppleScript** | ~200ms | App lifecycle (launch, quit, open/close project), cycle range fallback |
| **OSC** | <1ms | Mixer continuous control (requires Logic Pro OSC control surface setup) |

Example routing chains:

```
transport.play        → [CGEvent, CoreMIDI, AppleScript]
transport.set_tempo   → [OSC, Accessibility]
transport.set_cycle_range → [Accessibility, AppleScript]
track.select          → [Accessibility, CGEvent]   // AX click header; fallback: Cmd+Up + Down×N
track.set_solo        → [Accessibility, CGEvent]   // AX click button; fallback: select + S key
midi.send_note        → [CoreMIDI]
project.open          → [AppleScript]
```

### State Cache

Background Accessibility polling with adaptive intervals:

- **Active** (tool used <5s ago): 500ms transport, 2s tracks/mixer
- **Light** (5–30s idle): 2s all
- **Idle** (>30s): 5s all, near-zero CPU

Resources trigger a direct AX read for freshness before serving cached data.

### Binary Parser

`ProjectDataParser.swift` walks the chunked binary format inside `ProjectData` files in a `.logicx` package. It does not require Logic Pro to be running. Chunk types parsed:

- `MSeq` — track sequences (names, OIDs, hierarchy)
- `AuCO` — channel strips (volume, pan, routing, names)
- `AuRg` — audio regions (position, length, file OID)
- `AuFl` — audio file references (paths)
- `TxSq` — text sequences (marker names)
- `EvSq` — event sequences (marker positions, tempo events)
- `Trak` — arrangement track entries (OID linking)
- `Envi` — environment objects (stack grouping labels)

### Context Efficiency

| Approach | Tools | Resources | Context Cost |
|----------|-------|-----------|--------------|
| Typical MCP server | 100+ tools | 0 | ~40k tokens |
| **This server** | **8 tools** | **9 resources** | **~3k tokens** |

Same 100+ operations. ~90% less context.

## Differences from Upstream

This fork ([koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp)) adds:

| Feature | Status |
|---------|--------|
| Binary ProjectData parser (`ProjectDataParser.swift`) | Added |
| `project.analyze` command | Added |
| `project.tracks_hierarchy` command | Added |
| `project.bounce_stems` command with group planning | Added |
| `project.song_lengths` command | Added |
| `logic://tracks/live` resource with nesting depth | Added |
| `logic://markers` resource (binary-first) | Added |
| `logic://tracks/{index}` parameterized resource | Added |
| 9 resources (up from 7) | Added |
| Function group inference (12 groups) | Added |
| Channel strip enumeration (AuCO) | Added |
| Environment label parsing (Envi) | Added |
| Track-to-region mapping | Added |
| Sub-track hierarchy with stack detection | Added |
| `transport.set_cycle_range` — AX locator fields + AppleScript fallback | Fixed |
| `track.select` — CGEvent fallback (Cmd+Up + Down×N) | Fixed |
| `track.set_solo/mute/arm` — CGEvent fallback (select + S/M/R key) | Fixed |

## Limitations

Logic Pro does not expose a programmatic API. This server operates within macOS platform constraints:

- UI element paths may change between Logic Pro versions
- Some deep state (automation curves, MIDI region data) is not accessible via Accessibility
- AX element labels may be localized on non-English macOS
- Plugin parameter control is limited to what is visible in the UI
- OSC channel requires manual Logic Pro Control Surface configuration
- `set_cycle_range` requires Cycle mode to be enabled for AX locator fields to appear

## Development

```bash
# Build debug
swift build

# Build release
swift build -c release
# Binary at .build/release/LogicProMCP

# Run tests
swift test

# Check permissions
.build/debug/LogicProMCP --check-permissions
```

### Project Structure

```
Sources/LogicProMCP/
  main.swift                 # Entry point
  Server/                    # MCP server + config
  Dispatchers/               # 8 MCP tool dispatchers
  Resources/                 # 9 MCP resource handlers
  Channels/                  # 5 communication channels + router
  Accessibility/             # AX API wrappers + Logic element finders
  Binary/                    # ProjectData binary parser + models
  MIDI/                      # CoreMIDI engine + MMC
  OSC/                       # UDP client/server
  State/                     # Cache + adaptive poller + state models
  Utilities/                 # Logging, permissions, process utils
```

## License

MIT
