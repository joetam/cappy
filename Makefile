.PHONY: build lint test app run video clean-state

build:
	swift build

lint:
	./scripts/lint.sh

test: build
	.build/debug/quota-selftest

app:
	./scripts/package-app.sh

run: app
	open "build/Cappy.app"

video:
	./scripts/render-launch-video.sh

clean-state:
	@echo "Cappy state is intentionally not removed automatically."
