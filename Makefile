# xnu-demo: native macOS/XNU demoscene production. `make` builds, `make run` runs.
#
# Shaders are compiled at runtime by MTLDevice.makeLibrary(source:) so no Metal
# command-line toolchain (xcodebuild -downloadComponent MetalToolchain) is needed.
# The Makefile wraps Shaders.metal in a Swift raw string literal and links it in.

SWIFTC   ?= swiftc
BUILD    := build
BIN      := xnu-demo
SRCS     := $(wildcard Sources/*.swift)
SHADER   := Sources/Shaders.metal
GEN      := $(BUILD)/ShaderSource.swift
SWIFTFLAGS := -O -swift-version 5 -target arm64-apple-macosx14.0 -framework AppKit -framework MetalKit -framework AVFoundation

all: $(BIN)

$(GEN): $(SHADER) | $(BUILD)
	{ printf 'let shaderSource = #"""\n'; cat $(SHADER); printf '\n"""#\n'; } > $@

$(BIN): $(SRCS) $(GEN)
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(SRCS) $(GEN)

$(BUILD):
	mkdir -p $(BUILD)

run: $(BIN)
	./$(BIN)

windowed: $(BIN)
	./$(BIN) --windowed

check: $(BIN)
	./$(BIN) --render-audio /tmp/xnu-demo-check.wav && rm -f /tmp/xnu-demo-check.wav

clean:
	rm -rf $(BUILD) $(BIN)

.PHONY: all run windowed check clean
