.PHONY: build test lint format clean

build:
	@cd src && cargo build --release
	@echo "built src/target/release/ducktape"

test:
	@./tests/run_tests.sh

lint:
	@stylua --check lua plugin tests
	@cd src && cargo fmt --check && cargo clippy --release -- -D warnings

format:
	@stylua lua plugin tests
	@cd src && cargo fmt

clean:
	@cd src && cargo clean
