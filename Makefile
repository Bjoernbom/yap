# yap app build helpers. YapKit alone builds with `swift build`.

PROJECT      := yap.xcodeproj
SCHEME       := yap
CONFIG       ?= Debug
DERIVED_DATA := build
APP          := $(DERIVED_DATA)/Build/Products/$(CONFIG)/yap.app

.PHONY: app run project clean

# The app's package pins live in App/Package.resolved, apart from the root
# Package.resolved, which only holds YapKit's: `swift build` would otherwise
# fetch Sparkle, and each tool would rewrite the other's file. Xcode reads the
# workspace's copy when there is one, and leaves the root file alone. After
# changing a package in project.yml, copy the workspace's file back to App/.
WORKSPACE_RESOLVED := $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

project:
	xcodegen generate --quiet
	mkdir -p $(dir $(WORKSPACE_RESOLVED))
	cp App/Package.resolved $(WORKSPACE_RESOLVED)

app: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' \
		-quiet build

run: app
	@pkill -x yap || true
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT)
