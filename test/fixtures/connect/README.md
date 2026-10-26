# Hype Connect protocol fixtures (copied, do not edit here)

These 56 files (plus 5 v1.3 video fixtures added here ahead of the backend copy: `state.player.video`, `hello.mobile.v13`, `rpc.video.from`, `rpc_result.video`, `rpc_result.video.none`; re-copy when the backend ships them) are verbatim copies of the normative example frames in the
backend repository:

    hypemuzik-management/backend/connect-protocol/fixtures/

copied on 2026-10-12 alongside the contract
`hypemuzik-management/backend/docs/hype-connect.md` (protocol v1, with the v1.1 additions: lyrics and viz).

They are the contract between the backend hub, the web controller, the desktop
player and this app. `test/connect/connect_protocol_test.dart` proves every one
of them parses into the typed models in `lib/services/connect/connect_protocol.dart`
and re-serialises to the same JSON — including leaving absent optional fields
absent.

When the protocol changes, the backend's doc and fixtures change first; then
re-copy the whole folder here. Editing a file in this folder instead would let
this app drift from the contract while its tests stay green.
