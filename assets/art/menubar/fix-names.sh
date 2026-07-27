#!/bin/sh
# restore @2x / @3x suffixes stripped by the export pipeline
cd "$(dirname "$0")/png" || exit 1
for f in *-2x.png; do mv "$f" "${f%-2x.png}@2x.png"; done
for f in *-3x.png; do mv "$f" "${f%-3x.png}@3x.png"; done
