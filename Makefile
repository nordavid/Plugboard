# Plugboard — local build commands. No CI: everything runs on this Mac.

APP := build/Plugboard.app

.PHONY: app debug run check icon install snapshot clean

## Build a signed release app at build/Plugboard.app (universal: Apple silicon + Intel)
app:
	Scripts/bundle.sh release

## Build a debug app for the current architecture only (faster)
debug:
	ARCHS=$$(uname -m) Scripts/bundle.sh debug

## Build and open the app
run: app
	open "$(APP)"

## Run the core checks and the translation check
check:
	ARCHS=$$(uname -m) Scripts/build.sh debug
	.build-swiftc/debug/PlugboardChecks
	python3 -I Scripts/check-localization.py

## Redraw Resources/AppIcon.icns
icon:
	mkdir -p .build-swiftc/tools
	swiftc -O -sdk "$$(xcrun --show-sdk-path)" Scripts/make-icon.swift -o .build-swiftc/tools/make-icon
	.build-swiftc/tools/make-icon "$(CURDIR)"

## Copy the app to /Applications
install: app
	rm -rf "/Applications/Plugboard.app"
	cp -R "$(APP)" /Applications/
	@echo "✓ Installed /Applications/Plugboard.app"

## Render the window in several states to build/snapshots (for checking the UI)
snapshot: debug
	rm -rf build/snapshots
	"$(APP)/Contents/MacOS/Plugboard" --snapshot "$(CURDIR)/build/snapshots"

clean:
	rm -rf .build-swiftc build
