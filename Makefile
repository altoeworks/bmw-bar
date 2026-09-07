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

clean:
	swift package clean
	rm -rf build
