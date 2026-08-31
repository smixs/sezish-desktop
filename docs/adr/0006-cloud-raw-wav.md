# Windows client sends raw WAV to the cloud, not AAC

The macOS client encodes ADTS AAC-LC 32 kbps before upload; the server also accepts raw RIFF/WAV as-is (cloud/server.py). The Windows client sends 16 kHz mono PCM16 WAV and skips reproducing the AAC encoder entirely — ~8× more upload traffic per dictation, accepted in exchange for deleting a whole error-prone subsystem. Revisit only if user uplink in Uzbekistan proves to be a real bottleneck.
