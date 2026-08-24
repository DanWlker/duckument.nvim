.PHONY: test lint format

test:
	@./tests/run_tests.sh

lint:
	@stylua --check lua plugin tests

format:
	@stylua lua plugin tests
