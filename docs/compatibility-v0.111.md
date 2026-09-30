# STS2 v0.111.0 compatibility

This fork targets the Windows game assembly from STS2 `v0.111.0`, game commit
`41cef1ea`. No game assemblies or assets are distributed in the repository.

## Changes

- Read start-lobby capacity from the game's `_maxPlayers` field after removal
  of the public `MaxPlayers` property. Return an unknown value if that field is
  unavailable rather than assuming a lobby size.
- Use a snapshot of load-lobby `PlayerIds` after removal of `ConnectedPlayerIds`.
  Use the same snapshot for the count, readiness, and per-player connection data.
- Check the per-frame request limit before dequeuing. Previously, request 11
  could be discarded without completing its task.
- Reject browser `Origin` requests before dispatch and remove permissive CORS
  headers. Local MCP HTTP clients without `Origin` keep working.
- Package the Python server so the declared `sts2-mcp` entry point is installed.
  Dependency versions are unchanged.

## Validation

- Release build against the installed game: zero errors and zero warnings.
- `pwsh -NoProfile -File tests/Test-BridgeGuards.ps1`: exercises the actual
  production queue and HTTP dispatch methods with a local test listener.
- MCP entry-point and stdio protocol tests: see `mcp/tests/` and `mcp/README.md`.
- In-game state/action validation: pending first load of the mod. These build
  and bridge checks do not establish complete gameplay or multiplayer coverage.

The mod and manifest identify this fork build as `0.4.1`.

## First use

Install the DLL and matching manifest as described in the main README. Restart
the game and enable the mod through the game's own mod prompt/settings. The
first runtime check should be reading `/api/v1/singleplayer?format=json` or calling
`get_game_state(format="json")` before issuing gameplay actions.

Use the current state for hand indices. `play_card` acknowledges enqueueing an
action, so read the resulting state after it resolves before issuing another
index-based action. Automatic batching is not implemented by these changes.
