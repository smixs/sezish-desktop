import Foundation
import Testing
@testable import SezishCore

@Suite struct AppSettingsTests {
    @Test func roundTripInIsolatedSuite() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.autoRecordMeetings == false)
        #expect(settings.notesFolder == nil)

        settings.autoRecordMeetings = true
        let folder = URL(fileURLWithPath: "/tmp/sezish-notes", isDirectory: true)
        settings.notesFolder = folder

        #expect(settings.autoRecordMeetings == true)
        #expect(settings.notesFolder == folder)

        // A fresh instance on the same suite must read the persisted values.
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.autoRecordMeetings == true)
        #expect(reloaded.notesFolder == folder)
    }

    @Test func shortcutPersistsAsJSON() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.shortcut == nil) // unset until the user records one

        let recorded = Shortcut.key(keyCode: 49, flags: Shortcut.optionFlag) // ⌥Space
        settings.shortcut = recorded
        #expect(settings.shortcut == recorded)

        // Persisted as JSON: a fresh instance on the same suite reads it back intact.
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.shortcut == recorded)

        // Clearing removes it.
        reloaded.shortcut = nil
        #expect(reloaded.shortcut == nil)
    }

    @Test func hotkeyModeDefaultsToHoldAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.hotkeyMode == .hold) // absent key = today's behavior

        settings.hotkeyMode = .toggle
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.hotkeyMode == .toggle)

        // A stale/garbage raw value degrades to the default instead of crashing.
        defaults.set("hybrid", forKey: "hotkeyMode")
        #expect(reloaded.hotkeyMode == .hold)
    }

    @Test func summaryEngineDefaultsToClaudeAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.summaryEngine == .claude) // absent key = the default engine

        settings.summaryEngine = .codex
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.summaryEngine == .codex)

        // A stale/garbage raw value degrades to the default instead of crashing.
        defaults.set("gemini", forKey: "summaryEngine")
        #expect(reloaded.summaryEngine == .claude)
    }

    @Test func summaryEnabledDefaultsToTrueAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.summaryEnabled == true) // on by default, inert until configured

        settings.summaryEnabled = false
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.summaryEnabled == false)
    }

    @Test func meetingHookIsReadOnlyAndOffByDefault() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.meetingHook == nil) // hidden: nothing in the app ever writes it

        defaults.set("echo hi", forKey: "meetingHook")
        #expect(settings.meetingHook == "echo hi")

        // Blanking the value disables the hook, so a user need not delete the key
        // to stop spawning a process after every meeting.
        defaults.set("", forKey: "meetingHook")
        #expect(settings.meetingHook == nil)
    }

    @Test func localModelDefaultsToMultilingualAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.localModel == .multilingual) // absent key = the model every install already has

        settings.localModel = .ruEnPunctuated
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.localModel == .ruEnPunctuated)

        // A stale/garbage raw value degrades to the default instead of crashing.
        defaults.set("whisper", forKey: "localModel")
        #expect(reloaded.localModel == .multilingual)
    }

    @Test func launchHiddenDefaultsToFalseAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.launchHidden == false)

        settings.launchHidden = true
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.launchHidden == true)
    }

    @Test func geminiApiKeyRoundTripsAndTrims() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.geminiApiKey == nil) // nothing until the user pastes one

        // A pasted key carries the newline the clipboard came with — stored trimmed,
        // or the socket would open with a key the server never sees as valid.
        settings.geminiApiKey = "  AIza-test\n"
        #expect(settings.geminiApiKey == "AIza-test")

        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.geminiApiKey == "AIza-test")

        // Blanking the field is "no key", not an empty-string key.
        reloaded.geminiApiKey = "   "
        #expect(reloaded.geminiApiKey == nil)

        reloaded.geminiApiKey = "AIza-test"
        reloaded.geminiApiKey = nil
        #expect(reloaded.geminiApiKey == nil)
        #expect(defaults.object(forKey: "geminiApiKey") == nil)
    }

    @Test func geminiSmartModeDefaultsToTrueAndRoundTrips() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.geminiSmartMode == true) // cleaned-up text is what people expect

        settings.geminiSmartMode = false
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reloaded.geminiSmartMode == false)
    }

    @Test func geminiWithoutKeyDegradesToCloudWhenCredentialsExist() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let baked = CloudCredentials(
            endpoint: URL(string: "https://baked.example.com")!, apiKey: "ak-baked")
        let settings = AppSettings(defaults: defaults, bakedCloud: baked)
        settings.transcriptionMode = .gemini
        #expect(settings.transcriptionMode == .gemini)
        #expect(settings.effectiveTranscriptionMode == .cloud)

        settings.geminiApiKey = "AIza-test"
        #expect(settings.effectiveTranscriptionMode == .gemini)
    }

    @Test func geminiWithoutKeyDegradesToLocalWithoutCredentials() throws {
        let suiteName = "sezish.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults, bakedCloud: nil)
        settings.transcriptionMode = .gemini
        #expect(settings.effectiveTranscriptionMode == .local)

        settings.geminiApiKey = "AIza-test"
        #expect(settings.effectiveTranscriptionMode == .gemini)
    }
}
