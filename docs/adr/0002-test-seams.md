# Test seams: sez-core traits and Tauri IPC commands only

Tests attach at exactly two boundaries: the public traits of `sez-core` (`Mic`, `Transcriber`, `Inserter`, `History`, `Clock`) and the Tauri IPC command surface. Mocking anything inside an adapter — including the frontend `invoke` — is implementation coupling and is rejected in review. Decided upfront because every implementing agent would otherwise pick its own seam, and Tauri apps naturally tempt agents to mock `invoke`.

## Consequences

Trait signatures are frozen at scaffold time; after Phase 1 only the orchestrator changes them, in a dedicated PR.
