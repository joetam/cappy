.PHONY: build lint test icon app app-update-smoke dmg run video clean-state

build:
	swift build

lint:
	./scripts/lint.sh

test: build
	.build/debug/CappyClientStateSelfTest
	.build/debug/quota-selftest
	./scripts/test-codex-handshake.sh
	./scripts/test-keychain-write.sh
	./scripts/test-login-cancel.sh
	./scripts/test-reorder.sh
	./scripts/test-account-preservation.sh
	./scripts/test-profile-naming.sh
	./scripts/test-autoupdate.sh

icon:
	./scripts/build-app-icon.sh

app:
	./scripts/package-app.sh
	./scripts/package-dmg.sh

app-update-smoke:
	CAPPY_ENABLE_SOFTWARE_UPDATES=1 CAPPY_SOFTWARE_UPDATE_SMOKE_TEST=1 ./scripts/package-app.sh
	./scripts/package-dmg.sh

dmg: app

run:
	./scripts/package-app.sh
	open "build/Cappy.app"

video:
	./scripts/render-launch-video.sh

clean-state:
	@echo "Cappy state is intentionally not removed automatically."
