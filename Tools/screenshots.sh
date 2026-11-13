#!/bin/zsh
# Regenerates the sample file and README screenshots in docs/.
set -e
cd "$(dirname "$0")/.."
python3 Tools/make_sample.py
TMP=$(mktemp -d)
swiftc -O Shared/*.swift Preview/InfoLine.swift Preview/PlateGridView.swift Tools/Screenshots/main.swift -o "$TMP/screens"
"$TMP/screens" "$PWD"
