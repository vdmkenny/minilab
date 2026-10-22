# negscan's workflows. `make help` lists them.

.PHONY: help build run test check fmt release check-files hooks

help:
	@echo "make build        build negscan into zig-out/bin"
	@echo "make run          build and run the app (ARGS='open --library <folder>' and so on)"
	@echo "make test         run the tests"
	@echo "make check        run the checks CI runs: formatting, files, tests"
	@echo "make fmt          format the Zig code"
	@echo "make release      build optimised for speed, as the releases are"
	@echo "make hooks        install the pre-commit hook that keeps scans and other files out"

build:
	zig build --release=safe

run:
	zig build run --release=safe -- $(ARGS)

test:
	zig build test --summary all

check: check-files
	zig fmt --check src build.zig
	zig build test --summary all

fmt:
	zig fmt src build.zig

release:
	zig build --release=fast -Dstrip

check-files:
	scripts/check-files.sh

hooks:
	printf '#!/bin/sh\nexec scripts/check-files.sh --staged\n' > .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
