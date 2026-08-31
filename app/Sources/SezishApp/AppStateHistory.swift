import AppKit
import Foundation
import SezishCore

/// Dictation history actions for `AppState`. Split out like AppStateMeeting to
/// keep the state file on UI/hotkey wiring.
///
/// Everything about recognition itself lives in `DictationCoordinator` (the
/// seam); these are the UI ends of it: the pasteboard, a banner, and the
/// observed list the menu draws.
extension AppState {
    /// Runs a stored take through the current engine again. The coordinator
    /// refuses while a dictation or another retry is in flight, so the guard here
    /// only keeps the spinner honest.
    func retranscribe(_ record: DictationRecord) {
        guard retryingDictation == nil else { return }
        // Only reachable in local mode without a downloaded model, same as a take.
        guard let coordinator else {
            notifier.notify(title: "sezish", body: strings.notifModelMissing)
            return
        }
        retryingDictation = record.id
        Task {
            // The list and the flag come back whatever the outcome, so no early
            // return can ever strand the row on its spinner.
            defer {
                self.refreshDictations()
                self.retryingDictation = nil
            }
            let outcome = await coordinator.retranscribe(record)
            switch outcome {
            case .done(let text):
                // No insertion: the retry is started from a menu, so the focused
                // app is the menu itself and there is no caret to paste into.
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                notifier.notify(title: "sezish", body: strings.notifRetryDone)
            case .noText:
                notifier.notify(title: "sezish", body: strings.notifRetryFailed)
            case .busy:
                break
            }
        }
    }

    /// Selects the WAV itself, not the folder holding it: the user came for one take.
    func revealAudio(_ record: DictationRecord) {
        guard let audioURL = record.audioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
    }

    /// Re-reads the dictation list the menu and the History tab draw. Keeps the
    /// last known list when there is no history directory to read.
    func refreshDictations() {
        dictations = history?.records ?? dictations
    }

    /// Re-reads the meetings folder. Pulled, not observed: the folder is the
    /// user's own and can change under us, so the tab reads it when it appears
    /// and the app refreshes it whenever it writes a meeting itself.
    func refreshMeetings() {
        meetings = MeetingLibrary.entries(in: MeetingRecorder.meetingsDirectory)
    }

    func deleteDictation(_ record: DictationRecord) {
        guard retryingDictation != record.id else { return }
        try? history?.remove(id: record.id)
        refreshDictations()
    }
}
