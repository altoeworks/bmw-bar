APP_NAME    := BMWBar
BUNDLE      := build/$(APP_NAME).app
CONFIG      := release
BIN         := $(shell swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)

.PHONY: all build app run cli test clean

all: app

build:
	swift build -c $(CONFIG)

## Assemble a self-contained .app bundle around the SwiftPM-built binary.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - --identifier com.ohoefenstock.bmw-bar $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: app
	open $(BUNDLE)

## Headless verification, e.g. `make cli ARGS="auth"`
cli:
	swift run -c debug $(APP_NAME) --cli $(ARGS)

## swift-testing lives outside the default search paths under Command Line Tools
## (XCTest ships only with Xcode.app). These flags are no-ops once Xcode is installed.
DEVDIR    := $(shell xcode-select -p)
TEST_FW   := $(DEVDIR)/Library/Developer/Frameworks
TEST_LIB  := $(DEVDIR)/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F -Xswiftc $(TEST_FW) \
              -Xlinker -F -Xlinker $(TEST_FW) \
              -Xlinker -rpath -Xlinker $(TEST_FW) \
              -Xlinker -rpath -Xlinker $(TEST_LIB)

test:
	swift test $(TEST_FLAGS)

## Launch the real bundle and assert it actually finishes starting up.
##
## No unit test can catch this class of bug: a TimelineView in the MenuBarExtra *label*
## once wedged SwiftUI inside `updateButton`, blocking the main thread so
## `applicationDidFinishLaunching` never returned. Everything compiled, every test
## passed, and the app silently never connected.
smoke: app
	@pkill -f "BMWBar.app" 2>/dev/null || true
	@sleep 1
	@open $(BUNDLE)
	@sleep 12
	@log show --last 1m --predicate 'subsystem == "com.ohoefenstock.bmw-bar"' \
		--style compact --info --debug 2>/dev/null > /tmp/bmwbar-smoke.log || true
	@grep -q "ready:" /tmp/bmwbar-smoke.log \
		&& echo "smoke: OK - app reached .ready" \
		|| { echo "smoke: FAILED - app never reached .ready (main thread blocked?)"; \
		     tail -5 /tmp/bmwbar-smoke.log; exit 1; }

## Follow the running app's own logging.
logs:
	@log stream --predicate 'subsystem == "com.ohoefenstock.bmw-bar"' \
		--style compact --level debug

clean:
	swift package clean
	rm -rf build
