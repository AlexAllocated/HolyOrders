# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) /
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Sync protocol
bumps are called out — mismatched clients ignore each other's messages.

## [0.38.0] - 2026-09-26

### Added
- Support for WoW Forever (1.60.1).
- A paladin's first learned blessing is assigned to themselves automatically,
  together with their first aura, so the cast bar shows up right away.

### Fixed
- The cast bar now shows when an aura is known but none is assigned.
- Long timers such as "59m" now fit inside the cast bar icons.
- Sync messages held back by the client are sent later instead of lost.

## [0.37.2] - 2026-08-20

### Fixed
- `/ho opt` opens the options again on 2.5.6. The patch replaced the legacy
  Interface Options frame with the Settings panel, so the old
  `InterfaceOptionsFrame_OpenToCategory` call led nowhere.
- Skin font swaps no longer risk an error on 2.5.6, which validates the
  `SetFont` flag argument strictly and rejects the `nil` that `GetFont()`
  returns for a font object without flags.

## [0.37.1] - 2026-08-05

### Fixed
- The cast bar was invisible for protection paladins on 0.37.0.

## [0.37.0] - 2026-08-05

### Added
- Protection paladins get a Righteous Fury slot on the cast bar: green while
  it is up, red while it is missing, click to cast.

## [0.36.0] - 2026-08-05

### Changed
- No-Salvation substitutes follow the member's requests and remembered
  likings (Salvation itself skipped) instead of a generic class default.

### Fixed
- A per-member Salvation assignment is now substituted instead of dropped —
  that member used to end up with no blessing for the encounter.
- A class joining during No-Salvation mode can no longer be assigned
  Salvation.

## [0.35.0] - 2026-08-02

### Added
- Classes that join later are assigned automatically — every paladin row
  extends its existing coverage, no manual Auto needed. Also fills the gaps
  when you join a running group.

### Fixed
- Tanks get Light when the paladin has no Blessing of Kings.

## [0.34.0] - 2026-07-31

### Added
- `/ho peers` lists legacy blessing-addon clients and their free-assignment
  state.

### Fixed
- A request already covered by someone's plan no longer shows as outstanding.
- Solo-paladin auto blesses yourself talent-aware instead of self-Salvation.

## [0.33.0] - 2026-07-31

### Added
- `/ho pets`: shows who buffs which pet, with everyone's addon version.

### Fixed
- The request window remembers its position.

## [0.32.0] - 2026-07-30

### Added
- ElvUI skin: uses your ElvUI profile's colors and font (requires ElvUI).
- Skins can change the font — third-party skins too.

## [0.31.0] - 2026-07-30

### Added
- Pre-planning: assign paladins before they join — **+** button or
  `/ho expect <name>`, with name autocompletion; applies on arrival.
- Lane swap: click two paladin names to swap their assignments.
- Sync indicator: the window locks with a spinner while a sync runs.
- Aura sync to legacy blessing-addon clients.

### Fixed
- Might and Kings were swapped on the legacy wire.
- Pushed assignments no longer get overwritten by a legacy client's own row.
- Auras no longer flip after group joins.

## [0.30.0] - 2026-07-29

### Changed
- Clearer no-Salvation button labels (EN: mode state, DE: action).

## [0.29.2] - 2026-07-27

### Fixed
- No-Salvation mode reverts reliably, even after a lead change.
- Auto is refused while no-Salvation mode is active.
- No-Salvation mode ends when leaving the group.

### Changed
- The update hint links to the download site.

## [0.29.1] - 2026-07-25

### Fixed
- Legacy clients no longer flicker: broadcasts only go out on real changes.
- Pets no longer vanish from the lists when their owner is far away.

## [0.29.0] - 2026-07-25

Relaxed party permissions apply fully once every client runs 0.29+.

### Added
- Explicit "not a tank" mark — overrides role-icon and spec detection.

### Changed
- In parties everyone may edit assignments and tank flags (raids stay strict).
- Paladins without the addon are freely plannable.
- Switching a cell's blessing keeps its cast mode.

## [0.28.0] - 2026-07-25

### Added
- The legacy bridge pushes assignments to other paladins' legacy clients
  (accepted with lead/assist or their free-assignment option).

## [0.27.0] - 2026-07-24

### Added
- "biker" skin with a spinning wheel handle.
- Pets get multiple blessings with several paladins: Kings + Might, and
  Wisdom on mana pets (needs everyone on 0.27+).
- `/ho peers` lists incompatible clients and who must update.

### Changed
- Buffs count as expiring under 5 minutes (was 2).
- No-Salvation swaps prefer the class chain and Kings; Light is last resort.

### Fixed
- The peer list rebuilds after a mid-group `/reload`.
- Messages during raid formation are no longer lost.
- Buff requests reach freshly reloaded clients.
- Simultaneous plan broadcasts no longer discard each other.
- Stale queued edits are cancelled when a plan broadcast goes out.
- Realm-less sender names are handled correctly.

## [0.26.0] - 2026-07-23

### Added
- Reworked options in Blizzard's Interface Options, with a tooltip on every
  setting; fully localized.

### Changed
- Plain-language window legend (German reworked).

## [0.25.0] - 2026-07-22

### Added
- Selectable skins: `default`, `legacy`, `forga` — pluggable, other addons can
  register skins via `HO.Skin.Register`.

### Changed
- Options use real dropdowns; the fly-out closes faster.

## [0.24.0] - 2026-07-22

### Added
- Configurable fly-out direction.
- Sanctuary is assignable to protection-tagged paladins without the addon.

### Changed
- Requests no longer color the cast bar; the fly-out badge turns green once
  the wish is fulfilled.

### Fixed
- The request window no longer overflows with long blessing names.

## [0.23.0] - 2026-07-22

### Added
- Right-click on a class button casts the Greater blessing (single fallback).
- Party role tank icons count as tanks.
- Ungrouped auto proposes a talent-aware self blessing.

### Changed
- New handle controls: left = window, right = force rebuff, Ctrl-drag = move,
  shift-right = options.

## [0.22.0] - 2026-07-22

### Added
- Fly-out and class-button rebuffing work in combat, with member buff timers.
- Solo-paladin Salvation coverage in parties.
- `/ho bar debug`; durable "other" spec tag.

### Changed
- Force-rebuff progress shows per class; status visuals keep updating in combat.

### Fixed
- Spec inference no longer creates false tank flags from partial inspects.

## [0.21.1] - 2026-07-20

### Fixed
- Minimap button position on resized and square minimaps.

## [0.21.0] - 2026-07-20

### Added
- Ranked buff requests: a prioritized wish list, shown in the window and
  honored by auto.
- Opt-in sharing with legacy blessing addons (emit-only).

### Fixed
- Label overflow; error cascade from a half-built window.

## [0.20.0] - 2026-07-20

### Added
- Aura assignment per paladin, synced; aura button on the bar.
- Per-class fly-out on the cast bar.
- Buff requests for non-paladins.
- Window scale options; the window remembers its position.

### Changed
- Visual redesign of bar and windows; clearer cast-mode tags; quieter chat.

## [0.19.0] - 2026-07-19

### Added
- Persistent per-member blessing likings, synced.
- Explicit "none" state on the bar; window scrolling; keep-above option.

### Changed
- Options moved to Blizzard's panel; bare `/ho` opens the window.

### Fixed
- Auto without top-preference talents; stale overrides; oversized messages
  now fragment; leaver cleanup; greater casts before singles.

## [0.18.0] - 2026-07-19

### Added
- Version-guard messages naming who is outdated.

## [0.17.0] - 2026-07-19

Sync protocol v4 — breaking: all paladins must update together.

### Fixed
- Loading a stored plan no longer breaks sync for that client.
- Plan broadcasts apply atomically; tank lists travel in own messages.
- Outsiders can no longer edit plans by whisper; bursts are rate-limited.
- Protection tags sync; party planning is deterministic; greater decisions
  count only reachable members; only hunter/warlock pets are buffed.
- Many interface fixes (combat move error, cell offsets, umlaut headers).

## [0.16.0] - 2026-07-19

### Fixed
- Planner errors no longer disable sync; pet buffing works for common comps;
  overrides spread across paladins; unsaved edits survive roster changes.

### Changed
- Settings and plans are stored per character (no migration).

## [0.15.1] - 2026-07-19

### Fixed
- Incompatible protocol versions are announced instead of silently ignored.

## [0.15.0] - 2026-07-19

### Added
- Member rows show the blessing inherited from the class assignment.

### Fixed
- Wheel-cycling on the bar updates immediately.

## [0.14.0] - 2026-07-19

### Changed
- Auto scores full buff strength: talents, rank, greater knowledge
  (protocol v3 — everyone must update).

## [0.13.1] - 2026-07-19

### Fixed
- Cast bar position restores correctly after a reload.

## [0.13.0] - 2026-07-19

### Added
- German localization (deDE).
- Mouse wheel on a bar button cycles your class assignment.

## [0.12.0] - 2026-07-19

### Added
- Pets in the assignment window, with per-pet overrides.

### Fixed
- The options close button was blocked by the drag header.

## [0.11.0] - 2026-07-19

### Added
- `/ho plan clear` (with confirm).

## [0.10.0] - 2026-07-19

### Added
- Option to prefer greater blessings even for single members.

## [0.9.1] - 2026-07-19

### Fixed
- Tanks could still receive Salvation; protection tags count as tanks
  everywhere.

## [0.9.0] - 2026-07-19

### Added
- Cast bar growth direction: right, left, down or up.

## [0.8.0] - 2026-07-19

### Added
- Range-aware rotation: out-of-range members are skipped, not blocking.

## [0.7.0] - 2026-07-19

### Added
- No-Salvation mode state is synced; any lead can revert.

## [0.6.1] - 2026-07-19

### Fixed
- Redundant overrides no longer block greater casts.

## [0.6.0] - 2026-07-19

### Added
- Minimap button; options panel; inspect-based spec inference; `/ho report`.

### Changed
- Pets are buffed by the paladin covering their owner's class.

## [0.5.0] - 2026-07-19

### Added
- Salvation in parties; multi-paladin party planning.

### Changed
- Bar buttons: left-click planned blessing, right-click 10-minute single.

## [0.4.0] - 2026-07-19

### Changed
- Sync protocol v2: compact encoding under the message size cap
  (everyone must update).

## [0.3.0] - 2026-07-19

### Added
- `/ho trace` message logging; `/ho getlog <player>` remote log pull.

## [0.2.0] - 2026-07-19

### Added
- No-Salvation encounter mode with exact plan restore.

## [0.1.0] - 2026-07-19

First shareable pre-release for WoW Classic TBC Anniversary (2.5.6).

### Added
- Blessing plans with per-roster persistence and auto re-apply.
- Deterministic auto-planner with talent scoring and solo-Salvation mode.
- Multi-paladin sync with revisions and edit permissions.
- Secure cast bar with force rebuff; assignment window; debug commands.
