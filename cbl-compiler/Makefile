.PHONY: build clean test install run-example

build:
	dune build

clean:
	dune clean

test:
	dune test

install:
	dune install

# Run example
run-example: build
	./_build/default/bin/cblc.exe check examples/traffic_basic.cbl
	./_build/default/bin/cblc.exe compile examples/traffic_basic.cbl -o _build/traffic.json
	@echo ""
	@echo "Generated JSON IR:"
	@cat _build/traffic.json

# Development targets
watch:
	dune build --watch

fmt:
	dune build @fmt --auto-promote
