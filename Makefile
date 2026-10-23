# minilab's workflows. `make help` lists them.

.PHONY: help build run test check fmt fmt-check release check-files hooks

help:
	@echo "make build        build minilab into zig-out/bin"
	@echo "make run          build and run the app (ARGS='open --library <folder>' and so on)"
	@echo "make test         run the tests"
	@echo "make check        run the checks CI runs: formatting, files, tests"
	@echo "make check-files  check that no scans or other files that stay out are in the repository"
	@echo "make fmt          format the Zig code"
	@echo "make fmt-check    check the Zig code's formatting, as CI does"
	@echo "make release      build optimised for speed, as the releases are"
	@echo "make hooks        install the pre-commit hook that keeps scans and other files out"

build:
	zig build --release=safe

run:
	zig build run --release=safe -- $(ARGS)

test:
	zig build test --summary all

check: check-files fmt-check
	zig build test --summary all

fmt:
	zig fmt src build.zig deps

fmt-check:
	zig fmt --check src build.zig deps

release:
	zig build --release=fast -Dstrip

check-files:
	scripts/check-files.sh

# Asks git where the hooks go, since in a worktree .git is a file, not a folder.
hooks:
	hooks=$$(git rev-parse --git-path hooks) && mkdir -p "$$hooks" && \
		printf '#!/bin/sh\nexec scripts/check-files.sh --staged\n' > "$$hooks/pre-commit" && \
		chmod +x "$$hooks/pre-commit"
