import os
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import SezishCore

// Captures system audio via a Core Audio process tap: the call app's own
// processes when one is known, the global mixdown otherwise.
// Adapted from insidegui/AudioCap (https://github.com/insidegui/AudioCap,
// BSD-2-Clause license). The first `start()` triggers the system's
// "System Audio Recording" TCC prompt (usage string is in Info.plist).

enum SystemAudioTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case formatUnavailable
    case aggregateFailed(OSStatus)
    case ioProcFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s): "Process tap creation failed (\(s))"
        case .formatUnavailable: "No usable tap audio format"
        case .aggregateFailed(let s): "Aggregate device creation failed (\(s))"
        case .ioProcFailed(let s): "Audio IO proc failed (\(s))"
        }
    }
}

/// All state lives on the private serial queue: `start()`/`stop()` hop onto it
/// synchronously, the output-device-change listener rebuilds on it, and the
/// IOProc delivers buffers on it — no lock needed.
nonisolated final class SystemAudioTap: @unchecked Sendable {
    private let onSamples16k: @Sendable ([Float]) -> Void
    private let queue = DispatchQueue(label: "com.smixs.sezish.system-tap", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.smixs.sezish", category: "system-tap")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var tapUUID = UUID()
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(onSamples16k: @escaping @Sendable ([Float]) -> Void) {
        self.onSamples16k = onSamples16k
    }

    func start(scope: MeetingAudioScope) throws {
        try queue.sync { try startOnQueue(scope: scope) }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    // MARK: - On queue

    private func startOnQueue(scope: MeetingAudioScope) throws {
        guard !running else { return }

        // 1. Mono mixdown tap over the requested scope (TCC prompt on first use).
        let description = makeTapDescription(for: scope)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var newTapID: AUAudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr else { throw SystemAudioTapError.tapCreationFailed(err) }
        tapID = newTapID
        tapUUID = description.uuid

        // 2+3. Converter for the tap's native format, then the aggregate that
        //      hosts the tap. Any failure here has to tear the tap down again.
        do {
            try makeConverter()
            try buildAggregateAndStart()
        } catch {
            stopOnQueue()
            throw error
        }

        installDeviceChangeListener()
        running = true
    }

    /// The tap's native format and the 16 kHz mono converter built from it,
    /// stored on the object for the IOProc.
    private func makeConverter() throws {
        var streamDescription = try tapID.readTapStreamDescription()
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: format, to: output)
        else {
            throw SystemAudioTapError.formatUnavailable
        }
        tapFormat = format
        outputFormat = output
        self.converter = converter
    }

    /// One tap description per recording: a device change rebuilds only the
    /// aggregate that hosts this tap, so the scope survives it by construction.
    private func makeTapDescription(for scope: MeetingAudioScope) -> CATapDescription {
        let processes = liveProcesses(of: scope)
        guard !processes.isEmpty else {
            logFallbackToGlobal(scope)
            return CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        return CATapDescription(monoMixdownOfProcesses: processes)
    }

    /// Nothing to tap — a family with no live process, or an unreadable process
    /// list — is the one degradation this path allows: recording the whole Mac
    /// beats not recording the meeting at all.
    private func liveProcesses(of scope: MeetingAudioScope) -> [AudioObjectID] {
        do {
            return try scope.liveProcessIDs()
        } catch {
            logger.error(
                "process list unreadable for \(String(describing: scope), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// `.all` is the fallback itself, so only a named family is worth a line.
    private func logFallbackToGlobal(_ scope: MeetingAudioScope) {
        guard case .family(let family) = scope else { return }
        logger.notice("no live process in \(family, privacy: .public): recording all system audio")
    }

    private func stopOnQueue() {
        running = false
        removeDeviceChangeListener()
        tearDownAggregate()
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        converter = nil
        tapFormat = nil
        outputFormat = nil
    }

    /// Hosts the tap on an aggregate device clocked by the current default output.
    private func buildAggregateAndStart() throws {
        let outputDevice = try AudioObjectID.readDefaultOutputDevice()
        let outputUID = try outputDevice.readDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sezish-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else { throw SystemAudioTapError.aggregateFailed(err) }
        aggregateID = newAggregateID

        guard let tapFormat, let outputFormat, let converter else {
            throw SystemAudioTapError.formatUnavailable
        }
        let onSamples = onSamples16k
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil
            ) else { return }
            let converted = AudioResampler.resample(buffer, using: converter, to: outputFormat)
            if !converted.isEmpty { onSamples(converted) }
        }
        guard err == noErr else { throw SystemAudioTapError.ioProcFailed(err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw SystemAudioTapError.ioProcFailed(err) }
    }

    private func tearDownAggregate() {
        guard aggregateID.isValid else { return }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = kAudioObjectUnknown
    }

    // MARK: - Output device changes (AirPods mid-call, etc.)

    private func installDeviceChangeListener() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already on `queue` (registered below); rebuild the aggregate on the
            // new device. Sub-100ms gap in the system stem — accepted.
            guard let self, self.running else { return }
            self.tearDownAggregate()
            try? self.buildAggregateAndStart()
        }
        AudioObjectAddPropertyListenerBlock(.system, &address, queue, listener)
        deviceListener = listener
    }

    private func removeDeviceChangeListener() {
        guard let deviceListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(.system, &address, queue, deviceListener)
        self.deviceListener = nil
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
