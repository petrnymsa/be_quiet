VERSION ?= 0.1.0
APP = dist/BeQuiet.app
BUNDLE_ID = cz.nymsa.BeQuiet
ICONS = Packaging/Icons
RELEASE_BIN = $(shell swift build -c release --show-bin-path)/BeQuietApp
UNIVERSAL_BIN = .build/apple/Products/Release/BeQuietApp

.PHONY: all build test app install dist docs-images clean

all: app

build:
	swift build -c release --product BeQuietApp

test:
	swift test

# $(1) is the BeQuiet binary to wrap. The signature is ad-hoc — there is no
# Developer account — so macOS asks for Automation access again after a rebuild.
define assemble_app
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(1) $(APP)/Contents/MacOS/BeQuiet
	sed 's/@VERSION@/$(VERSION)/g' Packaging/Info.plist > $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	swift Packaging/make-icons.swift icns $(ICONS)/AppIcon.svg $(APP)/Contents/Resources/BeQuiet.icns
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)
endef

app: build
	$(call assemble_app,$(RELEASE_BIN))
	@echo "Built $(APP) ($(VERSION))"

install: app
	killall BeQuiet 2>/dev/null || true
	rm -rf /Applications/BeQuiet.app
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/BeQuiet.app — start it with: open /Applications/BeQuiet.app"

dist:
	swift build -c release --product BeQuietApp --arch arm64 --arch x86_64
	$(call assemble_app,$(UNIVERSAL_BIN))
	ditto -c -k --keepParent $(APP) dist/BeQuiet-$(VERSION).zip
	@echo "Built dist/BeQuiet-$(VERSION).zip (universal)"

# The images embedded in README.md; rerun after changing the SVG sources.
docs-images:
	swift Packaging/make-icons.swift readme $(ICONS) docs/images

clean:
	rm -rf dist
	swift package clean
