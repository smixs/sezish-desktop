APP_NAME   = sezish
CONFIG     = release
APP_BUNDLE = build/$(APP_NAME).app
BINARY     = .build/$(CONFIG)/$(APP_NAME)
# Cloud credentials baked into the bundle's Info.plist (key file is gitignored;
# builds without it simply ship local-only and the app degrades gracefully).
CLOUD_ENDPOINT = https://asr.sezi.sh
CLOUD_KEY_FILE = ../cloud/.api-key
# Sign with the local "Sezish Dev" identity when present (stable CDHash → TCC grants
# survive rebuilds); fall back to ad-hoc for anyone building without it.
SIGN_ID   ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Sezish Dev" && echo "Sezish Dev")
SIGN_FLAGS ?=
# Distribution identity: Developer ID + hardened runtime, required for notarization.
DIST_SIGN_ID = Developer ID Application: Timurkhuja Latipov (WW2ZW8XUX3)
DIST_SIGN_FLAGS = --options runtime --timestamp
# Sparkle 2 (auto-update). SwiftPM downloads it as a binary artifact on `swift build`;
# the framework itself sits inside the xcframework, the CLI tools next to it.
SPARKLE_DIR = .build/artifacts/sparkle/Sparkle
SPARKLE_BIN = $(SPARKLE_DIR)/bin
SPARKLE_FW_SRC = $(SPARKLE_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_FW = $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
# dev builds never phone home for updates; `make dist` flips CHANNEL to release.
# FEED_URL overrides the appcast baked into Info.plist (staging feeds, test channels).
CHANNEL ?= dev
FEED_URL ?=
UPDATES_DIR = updates
# cx = dedicated sezish box (Contabo); h1:sezish-dl was the pre-migration home.
DEPLOY_DEST ?= cx:/opt/sezish-dl

.PHONY: build bundle run test clean dist notarize sparkle-keys appcast deploy release

# Sparkle's nested helpers each need their own signature, applied inside-out —
# a plain --deep sign on the app is not enough (and Apple discourages it).
define sign_sparkle
	@for xpc in "$(SPARKLE_FW)/Versions/B/XPCServices/"*.xpc; do \
		[ -d "$$xpc" ] || continue; \
		codesign --force $(SIGN_FLAGS) --preserve-metadata=entitlements --sign "$(1)" "$$xpc"; \
	done
	@codesign --force $(SIGN_FLAGS) --preserve-metadata=entitlements --sign "$(1)" "$(SPARKLE_FW)/Versions/B/Autoupdate"
	@codesign --force $(SIGN_FLAGS) --preserve-metadata=entitlements --sign "$(1)" "$(SPARKLE_FW)/Versions/B/Updater.app"
	@codesign --force $(SIGN_FLAGS) --preserve-metadata=entitlements --sign "$(1)" "$(SPARKLE_FW)"
endef

build:
	swift build -c $(CONFIG)

test:
	swift test

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@cp -R "$(SPARKLE_FW_SRC)" "$(APP_BUNDLE)/Contents/Frameworks/"
	@chmod -R u+w "$(SPARKLE_FW)"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@if [ -f "$(CLOUD_KEY_FILE)" ]; then \
		/usr/libexec/PlistBuddy -c "Add :SezishCloudEndpoint string $(CLOUD_ENDPOINT)" "$(APP_BUNDLE)/Contents/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Add :SezishCloudKey string $$(tr -d '[:space:]' < $(CLOUD_KEY_FILE))" "$(APP_BUNDLE)/Contents/Info.plist"; \
		echo "Baked cloud credentials into Info.plist"; \
	fi
	@cp Resources/sezish.icns "$(APP_BUNDLE)/Contents/Resources/sezish.icns"
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@install_name_tool -add_rpath @executable_path/../Frameworks "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@# SwiftPM links the xcframework through an absolute rpath into .build; leaving it
	@# in would make the shipped app load the developer's copy of Sparkle (or fail
	@# signature validation on another machine). Only ../Frameworks may survive.
	@otool -l "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" \
		| awk '/LC_RPATH/ { rpath = 1; next } rpath && /path / { print $$2; rpath = 0 }' \
		| grep '\.build' \
		| while read -r path; do \
			install_name_tool -delete_rpath "$$path" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true; \
		done || true
	@for bundle in .build/$(CONFIG)/*.bundle; do \
		[ -d "$$bundle" ] && cp -R "$$bundle" "$(APP_BUNDLE)/Contents/Resources/" || true; \
	done
	@# SPUUpdater refuses to start on an unparseable SUPublicEDKey and shows a modal
	@# alert a second after launch. Until `make sparkle-keys` has produced the real
	@# key, drop the placeholder from the built bundle: the HTTPS feed plus the
	@# Developer ID signature still gate updates, just without EdDSA on top.
	@if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null | grep -q REPLACE_WITH; then \
		/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$(APP_BUNDLE)/Contents/Info.plist"; \
		echo "WARNING: SUPublicEDKey is still a placeholder — run 'make sparkle-keys' before shipping updates"; \
	fi
ifneq ($(CHANNEL),release)
	@/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$(APP_BUNDLE)/Contents/Info.plist"
endif
ifneq ($(strip $(FEED_URL)),)
	@/usr/libexec/PlistBuddy -c "Set :SUFeedURL $(FEED_URL)" "$(APP_BUNDLE)/Contents/Info.plist"
endif
ifneq ($(strip $(SIGN_ID)),)
	$(call sign_sparkle,$(SIGN_ID))
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_ID)" --entitlements Resources/sezish.entitlements "$(APP_BUNDLE)"
else
	$(call sign_sparkle,-)
	codesign --force $(SIGN_FLAGS) --sign - --entitlements Resources/sezish.entitlements "$(APP_BUNDLE)"
endif
	@echo "Bundled $(APP_BUNDLE)"

run: bundle
	@killall $(APP_NAME) 2>/dev/null; while killall -0 $(APP_NAME) 2>/dev/null; do sleep 0.1; done
	@open "$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf build

# Distributables. One Developer ID-signed app (hardened runtime) goes into both the
# zip (curl installer) and the styled DMG. Run `make notarize` after `make dist`
# before uploading — Gatekeeper needs the notarization ticket.
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
dist:
	$(MAKE) bundle SIGN_ID="$(DIST_SIGN_ID)" SIGN_FLAGS="$(DIST_SIGN_FLAGS)" CHANNEL=release
	@rm -f build/sezish-app.zip
	@ditto -c -k --keepParent "$(APP_BUNDLE)" build/sezish-app.zip
	@echo "Built build/sezish-app.zip ($$(codesign -dv build/sezish.app 2>&1 | grep ^Authority | head -1))"
	scripts/make-dmg.sh "$(APP_BUNDLE)" "build/sezish-$(VERSION).dmg"

# One-time setup (any team member's Apple ID + its app-specific password):
#   xcrun notarytool store-credentials sezish-notary \
#     --apple-id <apple-id> --team-id WW2ZW8XUX3 --password <app-specific-password>
notarize:
	xcrun notarytool submit build/sezish-app.zip --keychain-profile sezish-notary --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	@rm -f build/sezish-app.zip
	@ditto -c -k --keepParent "$(APP_BUNDLE)" build/sezish-app.zip
	codesign --force --timestamp --sign "$(DIST_SIGN_ID)" "build/sezish-$(VERSION).dmg"
	xcrun notarytool submit "build/sezish-$(VERSION).dmg" --keychain-profile sezish-notary --wait
	xcrun stapler staple "build/sezish-$(VERSION).dmg"

# One-time Sparkle setup. generate_keys stores the private EdDSA key in the login
# Keychain and prints the public one — paste that into Resources/Info.plist under
# :SUPublicEDKey. Back the private key up with `$(SPARKLE_BIN)/generate_keys -x <file>`
# and keep that file offline: losing it means already-installed copies can never be
# updated again. NEVER commit the private key or its export.
sparkle-keys: build
	$(SPARKLE_BIN)/generate_keys

# Signs the update archive and (re)writes updates/appcast.xml. Run AFTER `make
# notarize` — that step re-zips the stapled app, so the archive published here
# carries the notarization ticket.
appcast:
	@mkdir -p $(UPDATES_DIR)
	@cp build/sezish-app.zip "$(UPDATES_DIR)/sezish-$(VERSION).zip"
	$(SPARKLE_BIN)/generate_appcast "$(UPDATES_DIR)" --download-url-prefix https://dl.sezi.sh/ --link https://sezi.sh

# Publishes to dl.sezi.sh. Additive on purpose (no --delete): older archives must
# stay reachable, and generate_appcast keeps referencing them for delta updates.
deploy:
	rsync -av "$(UPDATES_DIR)/" "$(DEPLOY_DEST)/"
	rsync -av build/sezish-app.zip "$(DEPLOY_DEST)/sezish-app.zip"
	rsync -av "build/sezish-$(VERSION).dmg" "$(DEPLOY_DEST)/sezish.dmg"

# Full release. Bump CFBundleShortVersionString AND CFBundleVersion in
# Resources/Info.plist first — Sparkle compares CFBundleVersion, which must
# strictly increase or existing installs will not see the update.
release:
	$(MAKE) dist && $(MAKE) notarize && $(MAKE) appcast && $(MAKE) deploy
