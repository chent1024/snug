# mobile-workspace Specification

## Purpose
Define the personal fork’s two device base sizes, reversible application zoom, and a session-wide phone workspace with strong-identity, verified window restoration.
## Requirements
### Requirement: Upstream-aligned personal fork
The candidate SHALL descend from the latest confirmed upstream main and retain upstream 2.3 functionality, while keeping only the two user device base-size choices. Source changes SHALL be delivered to chent1024/snug on codex/mobile-workspace without overwriting upstream main.

#### Scenario: Device base sizes
- **WHEN** the user selects Redmi or iPhone 13
- **THEN** the next phone display starts at 488×1084 or 585×1266 standard pixels and adaptive wider modes retain that profile's aspect ratio

### Requirement: Application-specific reversible font scaling
The current com.openai.codex target SHALL be recognized as zoomable and its increase shortcut SHALL use Command-Plus semantics; decrease SHALL use Command-Minus. Only actual session increments SHALL be reversed, without resetting the user's pre-existing font size.

#### Scenario: Supported target and unsupported app
- **WHEN** a supported target is selected
- **THEN** its shortcut policy is used, while unknown apps receive no synthetic zoom shortcut

### Requirement: Session-wide ordinary-window collection
The application SHALL preserve a complete pre-topology layout with strong process/window identities, collect eligible current-desktop ordinary windows when the phone workspace is entered, retain them when switching selected windows, and restore originals after remote-session end.

#### Scenario: Switch selected app
- **WHEN** the user selects another window after collection
- **THEN** the previous ordinary work window remains in the phone workspace and its temporary font change is reverted

#### Scenario: Protected window states
- **WHEN** automatic collection sees minimized, fullscreen or other-desktop windows
- **THEN** it does not expand, exit fullscreen, change Spaces or move those windows

#### Scenario: Identity, lock or metadata loss
- **WHEN** a process identity changed, the screen locks, or window metadata is unavailable
- **THEN** identity changes are treated as a closed original, lock pauses without losing the baseline, and temporary metadata loss is not treated as a closed window

#### Scenario: Restore failure
- **WHEN** any original position, size or desktop ownership cannot be verified
- **THEN** recovery remains pending and its record is not discarded or replaced by a new session
