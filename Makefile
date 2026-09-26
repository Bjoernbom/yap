# yap app build helpers. YapKit alone builds with `swift build`.

PROJECT      := yap.xcodeproj
SCHEME       := yap
CONFIG       ?= Debug
DERIVED_DATA := build
APP          := $(DERIVED_DATA)/Build/Products/$(CONFIG)/yap.app

.PHONY: app run project clean

project:
	xcodegen generate --quiet

app: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' \
		-quiet build

run: app
	@pkill -x yap || true
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT)
