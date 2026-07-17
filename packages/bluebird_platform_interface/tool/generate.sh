#!/usr/bin/env bash
# Regenerates the pigeon message layer for all packages:
#   - lib/src/messages.g.dart                     (this package)
#   - bluebird_android  Messages.g.kt    (Kotlin)
#   - bluebird_darwin   Messages.g.swift (Swift)
# Generated files are committed; rerun after editing pigeons/messages.dart.
#
# Pigeon types the attribute UUID as a plain String (the wire format). Each
# platform converts to/from its own Uuid type at the hand-written boundary
# (Dart: BluetoothAttributeId; Kotlin: Proto/DeviceConnection; Swift: the
# CBUUID helpers) — the generated code is used verbatim, no post-processing.
set -euo pipefail
cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/messages.dart

dart format lib/src/messages.g.dart
