#!/bin/sh
# Runs test/ios/main.swift against the iOS plugin sources on macOS:
#   sh test/ios/run.sh
set -e
repo=$(cd "$(dirname "$0")/../.." && pwd)
src="$repo/ios/flutter_patcher/Sources/flutter_patcher"
out=$(mktemp -d)
swiftc -O -o "$out/ios-rules" -lz "$src/Protocol.swift" "$src/Bytecode.swift" "$src/Stores.swift" \
  "$src/Support.swift" "$src/PatchArchive.swift" "$repo/test/ios/main.swift"
"$out/ios-rules" "$repo"
