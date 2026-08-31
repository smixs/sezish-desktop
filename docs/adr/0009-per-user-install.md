# Per-user NSIS install (no UAC)

The installer targets %LOCALAPPDATA%\Programs (perMachine=false), not Program Files: no UAC prompt on an unsigned installer (softens the SmartScreen flow, ADR-0004) and the updater can replace binaries without elevation. App data: %APPDATA%\sezish (DictationHistory, .models).
