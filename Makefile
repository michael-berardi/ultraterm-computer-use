.PHONY: build app test smoke stress check-docs check-repo ci release-package npm-build npm-publish

build:
	swift build

app:
	./scripts/build-ultraterm-computer-use-app.sh debug

test:
	swift test

smoke:
	./scripts/run-tool-smoke-tests.sh

stress:
	./scripts/run-tool-stress-tests.sh

check-docs:
	./scripts/check-docs.sh

check-repo:
	./scripts/check-docs.sh
	./scripts/check-repo-hygiene.sh

ci:
	./scripts/ci.sh

release-package:
	./scripts/release-package.sh

npm-build:
	node ./scripts/npm/build-packages.mjs

npm-publish:
	node ./scripts/npm/publish-packages.mjs
