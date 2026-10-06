import AVFoundation
import AudioToolbox
import Foundation
import SezishCore

/// The process tap as CoreAudio created it: its object, the UUID the aggregate
/// refers to it by, and its native stream format.
nonisolated struct TapHandle: @unchecked Sendable {
    let id: AudioObjectID
    let uuid: UUID
    let format: AudioStreamBasicDescription
}

/// One aggregate hosting the tap, with its IOProc running. `output` names the output
/// device that clocks it, for the rebuild log.
nonisolated struct AggregateHandle: @unchecked Sendable {
    let id: AudioObjectID
    let ioProcID: AudioDeviceIOProcID?
    let output: String
}

/// The CoreAudio calls `SystemAudioTap` makes, behind a seam so its threading can be
/// tested without the HAL. Every call is blocking and may be slow: `SystemAudioTap`
/// decides which queue each one runs on.
nonisolated protocol SystemTapBackend: Sendable {
    func createTap(coverage: TapCoverage) throws -> TapHandle
    func destroyTap(_ tap: TapHandle)
    /// Builds an aggregate on the current default output that hosts `tap`, registers
    /// the IOProc on `ioQueue` and starts it. Cleans up after itself on failure.
    func startAggregate(
        for tap: TapHandle, ioQueue: DispatchQueue,
        onInput: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void
    ) throws -> AggregateHandle
    /// `AudioDeviceStop`, then destroys the IOProc and the aggregate.
    func stopAggregate(_ aggregate: AggregateHandle)
    func addOutputListener(
        on queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock
    ) throws
    func removeOutputListener(
        on queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock
    )
}

/// The real CoreAudio. Adapted from insidegui/AudioCap
/// (https://github.com/insidegui/AudioCap, BSD-2-Clause license).
nonisolated struct CoreAudioTapBackend: SystemTapBackend {
    func createTap(coverage: TapCoverage) throws -> TapHandle {
        let description = Self.tapDescription(for: coverage)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tapID: AUAudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { throw SystemAudioTapError.tapCreationFailed(err) }
        do {
            let format = try tapID.readTapStreamDescription()
            return TapHandle(id: tapID, uuid: description.uuid, format: format)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemAudioTapError.formatUnavailable
        }
    }

    /// The one CoreAudio description that can express a coverage; which coverage
    /// that is was decided in `SezishCore` (`MeetingAudioScope.coverage`). One
    /// description per recording: a device change rebuilds only the aggregate that
    /// hosts this tap, so the coverage survives it by construction.
    private static func tapDescription(for coverage: TapCoverage) -> CATapDescription {
        guard case .processes(let ids) = coverage else {
            return CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        return CATapDescription(monoMixdownOfProcesses: ids)
    }

    func destroyTap(_ tap: TapHandle) {
        guard tap.id.isValid else { return }
        AudioHardwareDestroyProcessTap(tap.id)
    }

    func startAggregate(
        for tap: TapHandle, ioQueue: DispatchQueue,
        onInput: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void
    ) throws -> AggregateHandle {
        let outputDevice = try AudioObjectID.readDefaultOutputDevice()
        let outputUID = try outputDevice.readDeviceUID()
        let outputName = (try? outputDevice.readDeviceName()) ?? outputUID

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
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]

        var aggregateID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard err == noErr else { throw SystemAudioTapError.aggregateFailed(err) }

        var ioProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            _, inInputData, _, _, _ in
            onInput(inInputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            throw SystemAudioTapError.ioProcFailed(err)
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            throw SystemAudioTapError.ioProcFailed(err)
        }
        return AggregateHandle(id: aggregateID, ioProcID: ioProcID, output: outputName)
    }

    func stopAggregate(_ aggregate: AggregateHandle) {
        guard aggregate.id.isValid else { return }
        if let ioProcID = aggregate.ioProcID {
            AudioDeviceStop(aggregate.id, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        AudioHardwareDestroyAggregateDevice(aggregate.id)
    }

    func addOutputListener(
        on queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        var address = Self.defaultOutputAddress
        let err = AudioObjectAddPropertyListenerBlock(.system, &address, queue, listener)
        guard err == noErr else {
            throw CoreAudioError(message: "output listener failed: \(err)")
        }
    }

    func removeOutputListener(
        on queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(.system, &address, queue, listener)
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
