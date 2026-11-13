.PHONY: configure check mac phone

configure:
	python3 scripts/configure.py

check:
	swift test
	python3 scripts/check_public_tree.py

mac:
	xcodebuild -project PadSteps.xcodeproj -scheme PadStepsMac -destination 'platform=macOS' -derivedDataPath build/mac build

phone:
	xcodebuild -project PadSteps.xcodeproj -scheme PadStepsPhone -destination 'generic/platform=iOS' -derivedDataPath build/phone build
