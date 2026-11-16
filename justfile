# SPDX-License-Identifier: GPL-3.0

set positional-arguments

_default:
    @just --list

# Build zig-out/Velocitty.app.
build *args:
    zig build "$@"

# Build and launch the app.
run *args:
    zig build run "$@"

# Build the app with Swift release optimizations.
release:
    zig build -Dconfiguration=Release

# Run configuration and Core tests.
test:
    zig build test

# Run all tests; requires an unlocked desktop and herdr.
test-gui:
    zig build test-gui
