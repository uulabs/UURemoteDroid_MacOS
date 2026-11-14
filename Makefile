.PHONY: build test app dmg icon clean

REMOTEDROID_BUILD_DIR ?= .build

build:
	swift build --scratch-path "$(REMOTEDROID_BUILD_DIR)"

test:
	swift test --scratch-path "$(REMOTEDROID_BUILD_DIR)"

app:
	./scripts/build-app.sh

dmg: app
	./scripts/package-dmg.sh

icon:
	./scripts/make-icon.sh

clean:
	rm -rf .build dist
