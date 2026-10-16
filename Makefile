# Makefile
KIT := Packages/EarshotKit

.PHONY: test device-test
# The Swift unit tests, then the script checkers' own tests (no app, no Claude).
test:
	cd $(KIT) && swift test
	python3 -B -m unittest discover -s Scripts -p 'test_*.py'

device-test:
	cd $(KIT) && EARSHOT_DEVICE_TESTS=1 swift test

SIGN_IDENTITY ?= -
APP := build/Build/Products/Release/Earshot.app
# The universal `earshot` helper (spec 11.2), built by SwiftPM in its own scratch folder so `swift test` keeps its cache.
HELPER_FLAGS := -c release --arch arm64 --arch x86_64 --product earshot --scratch-path $(CURDIR)/build/helper
HELPER := $(APP)/Contents/Helpers/earshot

.PHONY: app run release
# Xcode's own ad-hoc signing drops the hardened runtime flag (verified), so build unsigned and sign here.
# The helper is nested code: it is signed on its own first, then the app (never --deep).
app:
	xcodegen generate --quiet
	xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Release -derivedDataPath build \
		-destination 'generic/platform=macOS' -quiet build
	cd $(KIT) && swift build $(HELPER_FLAGS)
	mkdir -p $(APP)/Contents/Helpers
	cp -f "$$(cd $(KIT) && swift build $(HELPER_FLAGS) --show-bin-path)/earshot" $(HELPER)
	lipo $(HELPER) -verify_arch arm64 x86_64
	codesign --force --options runtime --identifier com.stephenthorn.earshot.cli --sign "$(SIGN_IDENTITY)" $(HELPER)
	codesign --force --options runtime --entitlements App/Earshot.entitlements --sign "$(SIGN_IDENTITY)" $(APP)
	@$(MAKE) --no-print-directory verify-app APP_PATH=$(APP)

# Checks a built (or unzipped) app: both signatures, the helper's two architectures, the version and the icon.
APP_PATH ?= $(APP)
.PHONY: verify-app
verify-app:
	codesign --verify --strict --verbose=2 "$(APP_PATH)/Contents/Helpers/earshot"
	codesign --verify --strict --verbose=2 "$(APP_PATH)"
	lipo -info "$(APP_PATH)/Contents/Helpers/earshot"
	lipo "$(APP_PATH)/Contents/Helpers/earshot" -verify_arch arm64 x86_64 \
		|| { echo "the helper isn't universal (arm64 and x86_64)"; exit 1; }
	@# `codesign --verify` doesn't check the hardened runtime, so read the flags of both signatures.
	@for code in "$(APP_PATH)/Contents/Helpers/earshot" "$(APP_PATH)"; do \
		codesign -dv "$$code" 2>&1 | grep -E "flags|Authority"; \
		codesign -dv "$$code" 2>&1 | grep -q 'flags=.*runtime' || { echo "$$code: hardened runtime missing"; exit 1; }; \
	done
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$(APP_PATH)/Contents/Info.plist")" = AppIcon \
		|| { echo "CFBundleIconName isn't AppIcon"; exit 1; }
	@xcrun assetutil --info "$(APP_PATH)/Contents/Resources/Assets.car" | grep -q '"Name" : "AppIcon"' \
		|| { echo "the AppIcon isn't in Assets.car"; exit 1; }
	@echo "Earshot $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(APP_PATH)/Contents/Info.plist")" \
		"build $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(APP_PATH)/Contents/Info.plist"): helper and icon OK"

run: app
	open $(APP)

# The zip is unpacked again and checked, so the release itself is proven to carry the signed helper.
release: app
	rm -f build/Earshot.zip
	rm -rf build/release-check
	ditto -c -k --keepParent $(APP) build/Earshot.zip
	ditto -x -k build/Earshot.zip build/release-check
	@$(MAKE) --no-print-directory verify-app APP_PATH=build/release-check/Earshot.app
	rm -rf build/release-check
	@echo "build/Earshot.zip"

.PHONY: e2e
e2e: app
	zsh Scripts/e2e.sh

# B5a: the app end to end on an imported file, with the user's own Claude Code (spec 18).
.PHONY: e2e-import
e2e-import: app
	python3 -B -m unittest discover -s Scripts -p 'test_e2e_import_check.py'
	zsh Scripts/e2e-import.sh

# B5b: README screenshots and the live panel GIF (Scripts/screenshots.sh). EARSHOT_BUILD_LOCK=<file> serializes the build.
.PHONY: screenshots
screenshots:
	zsh Scripts/screenshots.sh

# B5c: real calls to your own signed-in Claude Code (spec 18): the gated Swift checks (a) to (j), then earshot
# process, the MCP server and both plugins (k) to (m). Temporary folders only. Set EARSHOT_BUILD_LOCK=<file> to run
# the builds under /usr/bin/lockf.
.PHONY: claude-test
claude-test:
	python3 -B -m unittest discover -s Scripts -p 'test_claude_test_check.py'
	python3 -B -m unittest discover -s Scripts -p 'test_process_check.py'
	zsh Scripts/claude-test.sh

# Real calls to your own local model server (Ollama, LM Studio, llama.cpp): the gated Swift checks (a) and (c) to (i),
# then earshot process (k), and with EARSHOT_LOCAL_ANTHROPIC_URL the MCP server and both plugins (l) (m) with Claude
# Code on the local model. Needs EARSHOT_LOCAL_URL (for example http://localhost:11434/v1) and EARSHOT_LOCAL_MODEL.
# Temporary folders only. Set EARSHOT_BUILD_LOCK=<file> to run the builds under /usr/bin/lockf.
.PHONY: local-test
local-test:
	python3 -B -m unittest discover -s Scripts -p 'test_local_test_setup.py'
	python3 -B -m unittest discover -s Scripts -p 'test_process_check.py'
	python3 -B -m unittest discover -s Scripts -p 'test_claude_test_check.py'
	zsh Scripts/local-test.sh
