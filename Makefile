.PHONY: build test lint format clean

build:
	@cd src && cargo build --release --target-dir ../out
	@echo "built out/release/ducktape"

test:
	@./tests/run_tests.sh

lint:
	@stylua --check lua plugin tests
	@cd src && cargo fmt --check && cargo clippy --release --target-dir ../out -- -D warnings

format:
	@stylua lua plugin tests
	@cd src && cargo fmt

clean:
	@cd src && cargo clean --target-dir ../out
