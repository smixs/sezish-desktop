import Foundation
import Testing
@testable import SezishCore

private func freshSettings(baked: CloudCredentials? = nil) -> (AppSettings, UserDefaults) {
    let suite = "TranscriptionModeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (AppSettings(defaults: defaults, bakedCloud: baked), defaults)
}

private let baked = CloudCredentials(
    endpoint: URL(string: "https://baked.example.com")!,
    apiKey: "ak-baked"
)

struct TranscriptionModeTests {
    @Test func defaultModeIsCloud() {
        let (settings, _) = freshSettings(baked: baked)
        #expect(settings.transcriptionMode == .cloud)
        #expect(settings.effectiveTranscriptionMode == .cloud)
    }

    @Test func withoutCredentialsEffectiveModeDegradesToLocal() {
        let (settings, _) = freshSettings(baked: nil)
        #expect(settings.transcriptionMode == .cloud)
        #expect(settings.effectiveTranscriptionMode == .local)
        #expect(settings.cloudCredentials == nil)
    }

    @Test func defaultsOverrideBeatsBakedCredentials() {
        let (settings, defaults) = freshSettings(baked: baked)
        defaults.set("https://override.example.com", forKey: "cloudEndpoint")
        defaults.set("ak-override", forKey: "cloudApiKey")
        #expect(settings.cloudCredentials?.apiKey == "ak-override")
        #expect(settings.cloudCredentials?.endpoint.host == "override.example.com")
    }

    @Test func partialOverrideFallsBackToBaked() {
        let (settings, defaults) = freshSettings(baked: baked)
        defaults.set("https://override.example.com", forKey: "cloudEndpoint") // no key
        #expect(settings.cloudCredentials == baked)
    }

    @Test func modeRoundTripsAndGarbageDegradesToCloud() {
        let (settings, defaults) = freshSettings(baked: baked)
        settings.transcriptionMode = .local
        #expect(settings.transcriptionMode == .local)
        #expect(settings.effectiveTranscriptionMode == .local)

        defaults.set("hologram", forKey: "transcriptionMode")
        #expect(settings.transcriptionMode == .cloud)
    }
}
