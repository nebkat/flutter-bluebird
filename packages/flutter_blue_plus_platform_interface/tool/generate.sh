#!/usr/bin/env bash
# Regenerates the pigeon message layer for all packages:
#   - lib/src/messages.g.dart                     (this package)
#   - flutter_blue_plus_android  Messages.g.kt    (Kotlin)
#   - flutter_blue_plus_darwin   Messages.g.swift (Swift)
# Generated files are committed; rerun after editing pigeons/messages.dart.
set -euo pipefail
cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/messages.dart
dart format lib/src/messages.g.dart
