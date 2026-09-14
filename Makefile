VERSION ?= 0.1.0
APP = dist/BeQuiet.app
BUNDLE_ID = cz.nymsa.BeQuiet
ICONS = Packaging/Icons
ZIP = dist/BeQuiet-$(VERSION).zip
TAP_DIR ?= ../homebrew-tap
RELEASE_BIN = $(shell swift build -c release --show-bin-path)/BeQuietApp
UNIVERSAL_BIN = .build/apple/Products/Release/BeQuietApp

.PHONY: all build test app install dist cask release publish-cask docs-images clean

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
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Built $(ZIP) (universal)"

# The Homebrew cask for the zip built by `dist`, with the version and checksum
# filled in. Ends up in the petrnymsa/homebrew-tap repository via publish-cask.
cask:
	@test -f $(ZIP) || (echo "$(ZIP) missing — run make dist first"; exit 1)
	@sha=$$(shasum -a 256 $(ZIP) | cut -d' ' -f1); \
	sed -e 's/@VERSION@/$(VERSION)/g' -e "s/@SHA256@/$$sha/g" Packaging/bequiet.rb > dist/bequiet.rb; \
	echo "Wrote dist/bequiet.rb (sha256 $$sha)"

# Tags the current main, builds the universal zip and publishes a GitHub
# release whose notes are this version's CHANGELOG section.
release:
	@test "$$(git branch --show-current)" = main || (echo "release from main, not $$(git branch --show-current)"; exit 1)
	@test -z "$$(git status --porcelain)" || (echo "working tree is not clean"; exit 1)
	@grep -q '^## \[$(VERSION)\]' CHANGELOG.md || (echo "CHANGELOG.md has no section for $(VERSION)"; exit 1)
	$(MAKE) dist cask
	awk '/^## \[$(VERSION)\]/{f=1; next} /^## \[/{f=0} f' CHANGELOG.md > dist/release-notes.md
	git tag -a v$(VERSION) -m "BeQuiet $(VERSION)"
	git push origin main v$(VERSION)
	gh release create v$(VERSION) $(ZIP) --title "BeQuiet $(VERSION)" --notes-file dist/release-notes.md

publish-cask: cask
	@test -d $(TAP_DIR)/.git || (echo "clone github.com/petrnymsa/homebrew-tap to $(TAP_DIR) first"; exit 1)
	mkdir -p $(TAP_DIR)/Casks
	cp dist/bequiet.rb $(TAP_DIR)/Casks/bequiet.rb
	cd $(TAP_DIR) && git add Casks/bequiet.rb && git commit -m "bequiet $(VERSION)" && git push

# The images embedded in README.md; rerun after changing the SVG sources.
docs-images:
	swift Packaging/make-icons.swift readme $(ICONS) docs/images

clean:
	rm -rf dist
	swift package clean
