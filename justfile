# statusline-sprite tasks

prefix := env_var_or_default("PREFIX", env_var("HOME") / ".local")

default:
    @just --list

# Build the executable
build:
    zig build

# Build in release mode
release:
    zig build -Doptimize=ReleaseFast

# Run the app (pass args after --)
run *args:
    zig build run -- {{args}}

# Preview the statusline
demo tokens="120000":
    zig build
    printf '{"model":{"display_name":"Opus 4.8"},"total_input_tokens":{{tokens}}}' | ./zig-out/bin/statusline-sprite

# Run unit tests
test:
    zig build test

# Run the integration test script
integration:
    zig build integration

# Run all tests
check: test integration

# Install the release binary to {{prefix}}/bin (override with PREFIX=...)
install:
    zig build -Doptimize=ReleaseFast
    mkdir -p {{prefix}}/bin
    install -m 755 zig-out/bin/statusline-sprite {{prefix}}/bin/statusline-sprite
    @echo "installed -> {{prefix}}/bin/statusline-sprite"

# Format source
fmt:
    zig fmt src build.zig

# Check formatting without writing
fmt-check:
    zig fmt --check src build.zig

# Remove build artifacts
clean:
    rm -rf .zig-cache zig-out
