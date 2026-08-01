#!/bin/sh
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
# The export pipeline cannot write "@" into filenames, so restore them first.
cd "$(dirname "$0")/AppIcon.iconset" || exit 1
for f in *-2x.png; do mv "$f" "${f%-2x.png}@2x.png"; done
cd ..
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "wrote AppIcon.icns"
