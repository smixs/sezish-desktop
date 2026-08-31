import Foundation
import SezishAsr
import SezishCore

/// Model download and activation for `AppState`. Split out to keep the state file focused
/// on the UI/hotkey wiring.
extension AppState {
    /// Starts fetching the model's missing files, streaming progress into `modelPhase`.
    func downloadModel() {
        switch modelPhase {
        case .downloading, .ready: return
        case .missing, .failed: break
        }
        guard downloadTask == nil else { return }
        modelPhase = .downloading(0)
        let store = modelStore
        let downloader = downloader
        // One bar for the whole set: each file's progress is offset by the bytes of
        // the files before it, so the bar never jumps back to zero between files.
        let missing = store.missingFiles
        let totalBytes = missing.reduce(0) { $0 + $1.size }
        // AppState is a lifetime singleton, so a strong self capture here can't leak.
        downloadTask = Task {
            do {
                var base = 0
                for file in missing {
                    let offset = base
                    try await downloader.download(file, store: store) { done, _ in
                        let frac = totalBytes > 0 ? Double(offset + done) / Double(totalBytes) : 0
                        Task { @MainActor in self.setDownloadProgress(frac) }
                    }
                    base += file.size
                }
                self.finishDownload(nil)
            } catch {
                self.finishDownload(error)
            }
        }
    }

    /// Switches dictation and meetings to `model`. A download in flight for the old
    /// model is cancelled; a running meeting keeps the transcriber it already holds
    /// and the new model applies from the next one.
    func setLocalModel(_ model: AsrModel) {
        guard model != localModel else { return }
        downloadTask?.cancel()
        downloadTask = nil
        settings.localModel = model
        localModel = model
        modelStore = ModelStore(model: model)
        modelPhase = modelStore.isComplete ? .ready : .missing
        meetingLocalTranscriber = nil
        refreshInstalledModels()
        rebuildCoordinator()
    }

    /// Frees the disk of a model that is downloaded but not selected. The selected
    /// one is never deleted from here — its files are what dictation runs on.
    func deleteModel(_ model: AsrModel) {
        guard model != localModel else { return }
        do {
            try ModelStore(model: model, root: modelStore.directory).remove()
        } catch {
            NSLog("sezish: model delete failed: %@", error.localizedDescription)
        }
        refreshInstalledModels()
    }

    func refreshInstalledModels() {
        let root = modelStore.directory
        installedModels = Set(AsrModel.allCases.filter { ModelStore(model: $0, root: root).isComplete })
    }

    private func setDownloadProgress(_ frac: Double) {
        if case .downloading = modelPhase {
            modelPhase = .downloading(min(max(frac, 0), 1))
        }
    }

    private func finishDownload(_ error: Error?) {
        // Cancelled by a model switch: `downloadTask` and `modelPhase` already
        // describe the new model, so this task must not touch either.
        if Task.isCancelled { return }
        downloadTask = nil
        refreshInstalledModels()
        if error == nil, modelStore.isComplete {
            modelPhase = .ready
            rebuildCoordinator()
        } else {
            modelPhase = .failed(error?.localizedDescription ?? strings.downloadIncomplete)
            notifier.notify(title: "sezish", body: strings.notifModelDownloadFailed)
        }
    }

    /// (Re)builds the transcriber + coordinator for the effective mode. Safe to call
    /// repeatedly; skipped while a dictation is in flight so the pipeline is never
    /// swapped mid-recording (the new mode applies on the next rebuild).
    func rebuildCoordinator(warmup: Bool = true) {
        guard let history else { return }
        if let coordinator, coordinator.state != .idle { return }

        // Read the mode once: the transcriber that gets built and the engine tag written
        // into history must describe the same decision, or the tag would lie.
        let mode = settings.effectiveTranscriptionMode

        // Every path below replaces `activeTranscriber`, and a streaming one holds a live
        // socket that outlives the reference: its receive loop keeps the transport alive,
        // so deinit never comes. Drop the session here — no take is in flight, the guard
        // above returned if one were. `meetingLocalTranscriber` is never streaming, so a
        // shared local model can't be hit by this.
        if let stale = activeTranscriber as? StreamingTranscriber {
            Task.detached { await stale.cancelStream() }
        }

        guard let transcriber = makeTranscriber(mode: mode) else {
            coordinator = nil
            activeTranscriber = nil
            return
        }

        // Capture only the meter and the transcriber: AppState itself is not Sendable,
        // and both closures fire on the realtime audio thread.
        let meter = levelMeter
        let onLevel: @Sendable (Float) -> Void = { rms in
            Task { @MainActor in meter.push(rms: rms) }
        }
        let mic: MicRecorder = if let streaming = transcriber as? StreamingTranscriber {
            // The transcriber eats the audio live, and history still needs the whole take.
            MicRecorder(
                onLevel: onLevel,
                onSamples16k: { streaming.feed($0) },
                keepsBuffer: true
            )
        } else {
            MicRecorder(onLevel: onLevel)
        }

        activeTranscriber = transcriber
        coordinator = DictationCoordinator(
            mic: mic,
            transcriber: transcriber,
            engine: engineTag(mode: mode),
            inserter: PasteInserter(),
            history: history
        )
        // ONNX session init for local, TLS + Live session for gemini — paid up front so
        // the first take does not.
        if warmup, mode == .local || mode == .gemini {
            Task.detached { try? await transcriber.warmup() }
        }
    }

    /// What goes into history next to every transcript: the engine, and for the two modes
    /// that have variants, which variant produced the text.
    private func engineTag(mode: TranscriptionMode) -> String {
        switch mode {
        case .cloud: mode.rawValue
        case .local: "local/\(localModel.rawValue)"
        case .gemini: settings.geminiSmartMode ? "gemini/live-smart" : "gemini/live-verbatim"
        }
    }

    /// Transcriber for `mode`; shared by dictation and the meeting
    /// pipeline so a local model is never loaded twice.
    private func makeTranscriber(mode: TranscriptionMode) -> Transcriber? {
        switch mode {
        case .cloud:
            guard let creds = settings.cloudCredentials else { return nil }
            return CloudTranscriber(endpoint: creds.endpoint, apiKey: creds.apiKey)
        case .local:
            return loadLocalTranscriber()
        case .gemini:
            // No key, no engine: the coordinator stays nil and the mode falls back
            // through `effectiveTranscriptionMode` on the next rebuild.
            guard let key = settings.geminiApiKey else { return nil }
            return GeminiLiveTranscriber(
                apiKey: key, mode: settings.geminiSmartMode ? .smart : .verbatim)
        }
    }

    /// The selected model as a transcriber, or nil while its files are not on disk.
    /// A token table that fails to parse is surfaced through `modelPhase`.
    func loadLocalTranscriber() -> Transcriber? {
        guard modelStore.isComplete else { return nil }
        do {
            let vocab = try Vocab(contentsOf: modelStore.localURL(for: localModel.vocabFile))
            return GigaAmTranscriber(modelURL: modelStore.localURL(for: localModel.onnxFile), vocab: vocab)
        } catch {
            modelPhase = .failed(strings.modelLoadErrorPrefix + error.localizedDescription)
            return nil
        }
    }
}
