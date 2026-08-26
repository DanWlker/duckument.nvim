.PHONY: build test lint format clean

build:
	@cd src && cargo build --release
	@echo "built src/target/release/ducktape"

test:
	@./tests/run_tests.sh

lint:
	@stylua --check lua plugin tests

format:
	@stylua lua plugin tests

clean:
	@cd src && cargo clean
