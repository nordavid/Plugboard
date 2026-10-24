#!/bin/bash
# Compiles Plugboard with swiftc directly.
#
# SwiftPM in Command Line Tools 15.0 fails with "unable to lookup item 'PlatformPath'",
# so this script builds the same three modules Package.swift describes without it.
# With Xcode or newer Command Line Tools, `swift build` works too.
#
# Usage: Scripts/build.sh [debug|release]   (default: release)
#   ARCHS="arm64 x86_64"  architectures to build; more than one produces a universal binary

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build-swiftc/$CONFIG"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS="${ARCHS:-arm64 x86_64}"
DEPLOYMENT_TARGET="14.0"

case "$CONFIG" in
    release) OPT_FLAGS=(-O -whole-module-optimization); PRODUCTS=(Plugboard) ;;
    # -enable-testing lets PlugboardChecks use @testable import.
    debug) OPT_FLAGS=(-Onone -g -DDEBUG -enable-testing); PRODUCTS=(Plugboard PlugboardChecks) ;;
    *) echo "Unknown configuration: $CONFIG" >&2; exit 64 ;;
esac

# Fills the array named by $2 with the Swift files of module $1. Paths may contain spaces.
sources() {
    eval "$2=()"
    while IFS= read -r -d '' file; do
        eval "$2+=(\"\$file\")"
    done < <(find "$ROOT/Sources/$1" -name '*.swift' -print0 | sort -z)
}

build_arch() {
    local arch="$1"
    local dir="$OUT/$arch"
    local target="$arch-apple-macos$DEPLOYMENT_TARGET"
    mkdir -p "$dir/modules"

    local common=(-sdk "$SDK" -target "$target" "${OPT_FLAGS[@]}" -swift-version 5)

    local core_sources app_sources check_sources
    sources PlugboardCore core_sources
    sources Plugboard app_sources
    sources PlugboardChecks check_sources

    echo "▸ PlugboardCore ($arch)"
    swiftc "${common[@]}" -parse-as-library -module-name PlugboardCore \
        -emit-module -emit-module-path "$dir/modules/PlugboardCore.swiftmodule" \
        -emit-library -static -o "$dir/libPlugboardCore.a" \
        "${core_sources[@]}"

    echo "▸ Plugboard ($arch)"
    swiftc "${common[@]}" -parse-as-library -module-name Plugboard \
        -I "$dir/modules" -L "$dir" -lPlugboardCore -framework Security \
        -o "$dir/Plugboard" \
        "${app_sources[@]}"

    [[ "$CONFIG" == debug ]] || return 0
    echo "▸ PlugboardChecks ($arch)"
    swiftc "${common[@]}" -module-name PlugboardChecks \
        -I "$dir/modules" -L "$dir" -lPlugboardCore -framework Security \
        -o "$dir/PlugboardChecks" \
        "${check_sources[@]}"
}

for arch in $ARCHS; do
    build_arch "$arch"
done

# Merge per-architecture binaries.
for product in "${PRODUCTS[@]}"; do
    inputs=()
    for arch in $ARCHS; do inputs+=("$OUT/$arch/$product"); done
    lipo -create "${inputs[@]}" -output "$OUT/$product"
done

echo "✓ Built $OUT/Plugboard ($ARCHS)"
