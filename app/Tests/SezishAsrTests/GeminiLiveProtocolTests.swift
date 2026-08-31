import Foundation
import Testing

@testable import SezishAsr

/// Wire format of the Gemini 3.5 Transcribe Live session, byte for byte as the spike
/// recorded it (implementation-notes.md, 27.08.2026).
@Suite("GeminiLiveProtocol")
struct GeminiLiveProtocolTests {
    private func json(_ text: String) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? NSDictionary)
    }

    @Test(arguments: [GeminiTranscriptionMode.smart, .verbatim])
    func setupMessageMatchesTheSpikeFrame(mode: GeminiTranscriptionMode) throws {
        let expected: NSDictionary = [
            "setup": [
                "model": "models/gemini-3.5-transcribe-live",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                "inputAudioTranscription": [
                    "languageCodes": [String](),
                    "mode": mode == .smart ? "SMART" : "VERBATIM",
                ],
            ],
        ]
        #expect(try json(GeminiLiveProtocol.setupMessage(mode: mode)) == expected)
    }

    @Test func modeRawValuesAreServerSpelling() {
        #expect(GeminiTranscriptionMode.smart.rawValue == "SMART")
        #expect(GeminiTranscriptionMode.verbatim.rawValue == "VERBATIM")
    }

    @Test func activityFramesAreEmptyObjects() throws {
        #expect(try json(GeminiLiveProtocol.activityStartMessage)
            == ["realtimeInput": ["activityStart": [:] as [String: String]]] as NSDictionary)
        #expect(try json(GeminiLiveProtocol.activityEndMessage)
            == ["realtimeInput": ["activityEnd": [:] as [String: String]]] as NSDictionary)
    }

    @Test func audioMessageCarriesBase64PcmAt16k() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let expected: NSDictionary = [
            "realtimeInput": [
                "audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"],
            ],
        ]
        #expect(try json(GeminiLiveProtocol.audioMessage(pcm16: pcm)) == expected)
    }

    @Test func pcm16ClampsAndWritesLittleEndian() {
        let data = GeminiLiveProtocol.pcm16([0, 1, -1, 0.5, 1.5, -1.5])
        #expect(data.count == 12)
        let expected: [Int16] = [0, 32_767, -32_768, 16_384, 32_767, -32_768]
        var bytes = Data()
        for value in expected { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        #expect(data == bytes)
    }

    @Test func pcm16LengthIsTwoBytesPerSample() {
        #expect(GeminiLiveProtocol.pcm16([Float](repeating: 0.25, count: 1_600)).count == 3_200)
    }

    @Test func parsesEveryFrameTheServerSends() {
        #expect(GeminiLiveProtocol.parse(#"{"setupComplete": {}}"#) == [.setupComplete])
        #expect(GeminiLiveProtocol.parse(#"{"serverContent": {}}"#) == [.empty])
        #expect(GeminiLiveProtocol.parse(
            #"{"serverContent": {"interimInputTranscription": {"text": "Дай мне, блядь, промт"}}}"#)
            == [.interim("Дай мне, блядь, промт")])
        #expect(GeminiLiveProtocol.parse(
            #"{"serverContent": {"inputTranscription": {"text": "Дай мне промпт"}}}"#)
            == [.final("Дай мне промпт")])
        #expect(GeminiLiveProtocol.parse(#"{"serverContent": {"generationComplete": true}}"#)
            == [.generationComplete])
    }

    /// The spike always got the final and the completion in separate frames, but nothing in the
    /// protocol promises that: one frame carrying both must not lose either half.
    @Test func oneFrameCanCarrySeveralEvents() {
        #expect(GeminiLiveProtocol.parse(
            #"{"serverContent": {"inputTranscription": {"text": "x"}, "generationComplete": true}}"#)
            == [.final("x"), .generationComplete])
        let full = #"{"serverContent": {"interimInputTranscription": {"text": "чер"}, "inputTranscription": {"text": "черновик"}, "generationComplete": true}}"#
        #expect(GeminiLiveProtocol.parse(full) == [.interim("чер"), .final("черновик"), .generationComplete])
    }

    /// The Live API warns before it drops a session. Treating that as noise means the next
    /// take opens on a socket the server is about to close.
    @Test func goAwayIsItsOwnEvent() {
        #expect(GeminiLiveProtocol.parse(#"{"goAway": {"timeLeft": "5s"}}"#) == [.goAway])
        #expect(GeminiLiveProtocol.parse(#"{"goAway": {}}"#) == [.goAway])
    }

    @Test func unknownAndBrokenFramesNeverThrow() {
        #expect(GeminiLiveProtocol.parse("не json вовсе") == [.unknown("не json вовсе")])
        #expect(GeminiLiveProtocol.parse("") == [.unknown("")])
        #expect(GeminiLiveProtocol.parse(#"{"serverContent": {"modelTurn": {}}}"#)
            == [.unknown(#"{"serverContent": {"modelTurn": {}}}"#)])
    }
}
