# Default hotkey: Right Ctrl, hold mode

Windows default is a bare Right Ctrl (mirrors Right ⌘ on macOS), default mode hold. Right Alt was rejected — it is AltGr in Uzbek/European layouts; Ctrl+Space was rejected — IME switching; CapsLock was rejected — hijacks the toggle LED state. Bare-modifier hotkeys are exactly why we run our own WH_KEYBOARD_LL hook instead of RegisterHotKey.
