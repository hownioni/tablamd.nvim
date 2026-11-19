.PHONY: test format lint

test:
	nvim --headless -u NONE -i NONE --cmd "set rtp^=." -l tests/run.lua

format:
	stylua lua plugin tests

lint:
	stylua --check lua plugin tests
