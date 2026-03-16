# Reverse Engineering Findings Log

This log captures concrete findings from `ProjectData` analysis, including discoveries that may help decode data beyond arrangement markers.

## 2026-02-09 (Current Pass)

- `USEl` payloads contain embedded 80-byte event rows that decode like `EvSq` rows.
- The best 80-byte alignment offset in `USEl` varies by chunk (examples observed: `11`, `12`, `57`, `63`), but decoded event content is stable.
- Decoding `USEl` 80-byte rows reproduces the same marker-linked type-36 event set seen in `EvSq(oid=4)`, including the same tick/OID pairs.
- Marker-linked type-36 events are stable across many project snapshots:
  - marker OIDs: `4, 8, 12, 16, 20, 24, 28, 32, 36`
  - consistent 27-event set with ticks in range `521280..3536339`.
- A separate explicit marker sequence table exists in `EvSq(oid=0, len=448)` using 16-byte triplets:
  - head `[18, start_tick, 0, ...]`
  - marker row `[marker_oid, 0x88000000, marker_type, duration_ticks]`
  - tail `[0, 0x88000000, 0, 0]`
- This type-18 table encodes marker order exactly as the arrangement lane sequence observed in the screenshot:
  - `28 -> 20 -> 16 -> 4 -> 8 -> 32 -> 24 -> 12 -> 36`
- In that table, `duration_ticks` on each marker row equals `next_start_tick - start_tick` for all non-terminal rows, indicating explicit section span encoding.
- A dedicated tempo-bridge table exists in small `EvSq` chunks (`len=432`, seen at `oid=0` and `oid=64`) with repeated 16-byte pairs:
  - row A `[96, sequence_tick, 0, 0x0100007F|0x8100007F]`
  - row B `[tempo_raw, 0x88400000, tempo_tick_abs, 0]`
  - `tempo_raw` decodes as `BPM * 10000` and `tempo_tick_abs` matches the absolute pre-offset tempo timeline.
- A separate small `EvSq(oid=0, len=192)` triplet structure contains explicit bar-like anchors:
  - head `[48, tick, 0x02000000, ...]`
  - row `[48, 0x88000000, bar_raw, tick]`
  - tail `[0, 0x88000000, 0, 0]`
  - observed decoded rows include `(tick=1651200, bar_raw=420)` and `(tick=1654080, bar_raw=421)` plus a pre-roll style value `bar_raw=65526` (signed-16 interpretation `-10`).
- `SngO`/`GenM` `NSKeyedArchiver` data includes `Shared.arrangementMarkerTitleList`, but observed content is type metadata (`slot -> { type }`) only; no marker titles or position ticks were found there.
- `TxSq` contains arrangement marker titles (`oid` `4..36` and notes at `oid=40`), while nearby `TxSt` entries with overlapping OIDs are unrelated score/text style labels (e.g., `Page Numbers`, `Bar Numbers`, etc.).
- Multiple chunk families embed the same small arrangement-marker plist (`arrangementMarkerTitleList`), including large `PluginData` and non-ASCII chunk families; this appears to be replicated metadata, not timeline position data.
- OIDs are not globally unique across chunk families. The same OID can refer to unrelated records in different chunk types (`TxSt`, `AuFl`, `AuRg`, `GenM`, `Envi`, `MSeq`, `EvSq`, etc.), so joins must remain chunk-type scoped.
- Several non-marker object IDs from type-36 rows (e.g., `40`, `44`, `48`, `52`, `56`, `60`, `64`, `68`, `120`, `124`, `128`, `144`, `152`, `168`, `172`, `232`, `236`, `240`, `244`, `248`, `264`, `268`) appear to map to loop/section-related entities and may be useful for broader timeline decoding.
- Embedded 80-byte rows inside the large `PluginData` body include `type=32` records with timeline ticks and a field that flips between `1024`/`1025` near `tick=3,811,619`; this likely represents timeline/ruler state metadata and is a candidate source for future bar-number decoding.
- In the largest `PluginData` chunk (`len=4,856,566`), 80-byte row decoding is strongly alignment-sensitive; the strongest stable decode is at alignment `1` (99 rows with sentinel signature `u32[7]=0x3FFFFFFF` and `u32[9]=0x88000000`).
- That aligned `PluginData` type-32 table is heavily repeated with near-identical row templates across the file, indicating replicated state snapshots rather than a single canonical timeline table.
- In those type-32 rows:
  - `u32[1]` behaves like a timeline tick and repeatedly lands near known section boundaries (`~1,144,320`, `~1,582,080`, `~2,096,640`, `~2,875,859`, `~3,807,779`, `~4,462,499`, `~4,557,059`).
  - `u32[4]` and `u32[8]` behave like object/lane references (small ID domains), not direct bar counters.
  - `u32[3]` toggles between small state values (`1`, `1024`, `1025`) and appears to be a mode/state flag.
- Type-36 rows in the same binary neighborhood share the same sentinel pattern and carry per-lane/event references; these rows remain event-layer metadata and still do not expose a direct absolute bar-number field.
- `Trns(oid=0,len=468)` contains compact global timeline constants including a literal `3840`, `4096`, and pre-roll-like signed values (`0xFFFF`-style), suggesting transport/grid configuration storage separate from arrangement section events.
- Re-evaluated `PluginData` pattern `[144, tick, ..., 64, 0x89000000, 0, 240]` is MIDI-style event data (`type 144` + companion `type 64`) with beat-like `960` tick spacing, not a standalone bar-axis table.
- Across `EvSq`, the only observed `0x7F0000xx` bridge signatures are `0x0100007F` (and a single `0x8100007F` variant), both tied to tempo bridge rows; no additional sibling signatures were observed that would directly encode time-signature/bar transforms.
- `Song` bodies contain structured 24-byte (`u32x6`) node tables with stable type domains:
  - type-14 nodes carry marker-domain values (`0,4,8,...,36`) and linked-list style edges (`14 -> 14` in fields `u32[4:6]`).
  - type-20 nodes carry dense bar-domain values (mostly `+4` steps) and linked-list style edges (`20 -> 20` in fields `u32[4:6]`).
- In the strongest `Song` decode candidate (`len=55796`, alignment `20`), the arrangement marker OID set `{4,8,12,16,20,24,28,32,36}` is present explicitly inside type-14 nodes, confirming the marker domain exists in this table family even though marker->bar joins are not yet decoded.
- The type-20 bar node chains are deterministic and monotonic within snapshots (examples observed up through `bar ~848` in `len=12876` snapshots), but a direct, decoded join from these bar nodes to arrangement marker sequence ticks remains unresolved.
- In larger `Song` snapshots, node records frequently carry non-typed/hash-like link payloads in `u32[2:6]`, while smaller snapshots retain clearer typed edge chains (`14 -> 14`, `20 -> 20`), suggesting these tables are snapshot/state variants of the same graph structure.

## Working Hypotheses

- `USEl` may preserve active edit-state snapshots with embedded event tables; extracting stable timeline layers may require selecting the right logical snapshot, not just latest chunk by file order.
- Type-18 sequence tables likely represent arrangement-lane sections, while marker-linked type-36 rows likely represent a different timeline lane/use-case.

## Song Node Graph / Marker-Bar Join (Decoded)

- **Song Node Graph Identified**: The `Song` chunk body (specifically the largest one, alignment often near 20 or 9500) contains a graph of 24-byte nodes (`u32x6`).
- **Node Types**:
  - **Type 14**: "Marker Domain" nodes. Records often (but not always) correspond to Marker OIDs.
  - **Type 20**: "Bar Domain" nodes. Records appear densely (step 4 instructions in ID space).
- **Common ID Space (Join Key)**: The second field `rec[1]` acts as a unified ID space shared between Type 14 and Type 20.
  - When a Type 14 node and a Type 20 node share the same `rec[1]`, they represent the same logical point (the Join).
  - The ID space seems to step regularly (e.g., 68, 72, 76, 80...).
- **Graph Structure**:
  - `rec[4]` and `rec[5]` act as **Typed Links**: `(TargetType, TargetID)`.
  - Type 14 nodes often form linked lists (e.g. `(14, 72) -> (14, 76)`).
  - Type 20 nodes often form linked lists (e.g. `(20, 68) -> (20, 72)`).
  - Cross-type links are implicit via `rec[1]` identity (structural intersection).
  - **Node Roles**: A single ID (e.g., OID 20) can map to multiple Type-20 nodes:
    - **Data Node**: Carries payload in `rec[2], rec[3]` (High word often `0xF016...`). Link fields often zero or garbage.
    - **Link Node**: Carries structural links in `rec[4], rec[5]`. Payload fields often zero.
- **Payloads**:
  - `rec[2]` and `rec[3]` contain payload data (Bar/Tick info).
  - Payload existence is distributed: Sometimes a Type 14 node carries data while the corresponding Type 20 node is just a placeholder link, or (more commonly for bars) vice versa.
  - Common payload constant `rec[3] = 0xF016884F` (`4027672655`) is observed in both types when data is present.
- **Extractor Implementation**: `logic_extractor.py` now extracts this graph into `summary.song_node_graph`, providing:
  - `marker_map`: Map of `rec[1] -> { type14: [nodes], type20: [nodes] }`.
  - `sequence`: Sorted list of keys useful for timeline reconstruction.
  - **Correlation**: The extractor now injects `graph_payload_u32` (from Data Nodes) and `graph_links_20` (from Link Nodes) directly into `arrangement_markers`, allowing correlation of Markers with Song Graph data.
    - **Payload Analysis (2026-02-09 - Conclusion)**:
      - Extensive analysis of `rec[2]` (Payload) and `rec[4]/rec[5]` (Data Node "Links") yields no standard numeric decoding.
      - Values are non-monotonic with respect to time.
      - Values do not map to file offsets or `PluginData` indices.
      - **Conclusion**: The fields likely contain a hash or opaque Object ID that references an internal runtime object not serialized in a simple table.
      - **Recommendation**: Rely on `EvSq` for absolute timing. Use Song Graph only for topological sequencing (A -> B).
