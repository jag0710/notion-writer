#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --scratch-path work/build >/dev/null
BUILD=$(swift build --scratch-path work/build --show-bin-path)
SOURCES=()
for source in Sources/NotionWriter/*.swift; do
    [[ "$source" == */main.swift ]] || SOURCES+=("$source")
done
swiftc -swift-version 5 -parse-as-library -module-cache-path work/build/ModuleCache \
    -I "$BUILD/Modules" "${SOURCES[@]}" Tests/NotionWriterAppTests/*.swift \
    "$BUILD"/NotionWriterCore.build/*.swift.o -o work/NotionWriterAppVerify
work/NotionWriterAppVerify "$@"
