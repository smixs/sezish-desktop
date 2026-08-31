# Windows insertion restores the clipboard (deliberate deviation from macOS)

macOS deliberately leaves the dictated text on the clipboard (failed paste = text still in hand, PasteInserter.swift). On Windows we DO restore the user's clipboard, generation-tracked: restore fires 500-750 ms later only if the clipboard still holds exactly what we placed, and is skipped when insertion failed — preserving the "failure leaves text in hand" semantics. Deviation exists because Windows paste fails silently more often (elevated windows, UIPI) and users notice clipboard clobbering more than on macOS.
