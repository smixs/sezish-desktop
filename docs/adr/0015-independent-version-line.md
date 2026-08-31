# Windows versions independent from macOS; separate update feed

The Windows app starts at 0.1.0 and bumps only the patch digit per release (minor bumps only on Serge's explicit call). Update feed lives at dl.sezi.sh/win/latest.json (tauri-plugin-updater format) — fully separate from the macOS Sparkle appcast.xml. The two apps release on their own cadence; nothing couples their versions.
