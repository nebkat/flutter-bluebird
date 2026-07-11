#!/usr/bin/env bash
# Regenerates the pigeon message layer for all packages:
#   - lib/src/messages.g.dart                     (this package)
#   - bluebird_android  Messages.g.kt    (Kotlin)
#   - bluebird_darwin   Messages.g.swift (Swift)
# Generated files are committed; rerun after editing pigeons/messages.dart.
set -euo pipefail
cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/messages.dart

# Post-generation patch: BmAttributeId.uuid and BmDescriptorRef.uuid are typed
# as String by pigeon (the wire format stays a plain string), but the Dart and
# Kotlin sides expose them as a real Uuid. Each replacement is exact-match and
# asserted so the script fails loudly if pigeon's output ever shifts.
# NOTE: Swift is intentionally NOT patched — Messages.g.swift keeps String, so
# the Swift plugin compiles and interoperates unchanged. When bluebird_darwin
# gains its own Uuid type, apply the same treatment there.
python3 - <<'EOF'
def patch(path, replacements):
    with open(path) as f:
        src = f.read()
    for old, new in replacements:
        count = src.count(old)
        assert count == 1, (
            f"expected exactly 1 occurrence of {old!r} in {path}, found {count}; "
            "pigeon output changed — update tool/generate.sh"
        )
        src = src.replace(old, new)
    with open(path, 'w') as f:
        f.write(src)
    print(f"patched {path}")

# --- Dart: lib/src/messages.g.dart ---------------------------------------
patch('lib/src/messages.g.dart', [
    # Uuid import (uuid.dart lives alongside messages.g.dart).
    (
        "import 'package:meta/meta.dart' show immutable, protected, visibleForTesting;\n",
        "import 'package:meta/meta.dart' show immutable, protected, visibleForTesting;\n\n"
        "import 'uuid.dart';\n",
    ),
    # BmAttributeId: field, _toList, decode.
    (
        "class BmAttributeId {\n"
        "  BmAttributeId({\n"
        "    required this.uuid,\n"
        "    required this.instance,\n"
        "  });\n"
        "\n"
        "  String uuid;",
        "class BmAttributeId {\n"
        "  BmAttributeId({\n"
        "    required this.uuid,\n"
        "    required this.instance,\n"
        "  });\n"
        "\n"
        "  Uuid uuid;",
    ),
    (
        "    return <Object?>[\n      uuid,\n      instance,\n    ];",
        "    return <Object?>[\n      uuid.string,\n      instance,\n    ];",
    ),
    (
        "    return BmAttributeId(\n      uuid: result[0]! as String,",
        "    return BmAttributeId(\n      uuid: Uuid(result[0]! as String),",
    ),
    # BmDescriptorRef: field, _toList, decode.
    (
        "  /// Descriptor uuids are unique within a characteristic; no instance needed.\n"
        "  String uuid;",
        "  /// Descriptor uuids are unique within a characteristic; no instance needed.\n"
        "  Uuid uuid;",
    ),
    (
        "    return <Object?>[\n      characteristic,\n      uuid,\n    ];",
        "    return <Object?>[\n      characteristic,\n      uuid.string,\n    ];",
    ),
    (
        "    return BmDescriptorRef(\n"
        "      characteristic: result[0]! as BmCharacteristicRef,\n"
        "      uuid: result[1]! as String,\n"
        "    );",
        "    return BmDescriptorRef(\n"
        "      characteristic: result[0]! as BmCharacteristicRef,\n"
        "      uuid: Uuid(result[1]! as String),\n"
        "    );",
    ),
])

# --- Kotlin: bluebird_android Messages.g.kt (Uuid is in the same package) --
patch('../bluebird_android/android/src/main/kotlin/com/lib/bluebird/Messages.g.kt', [
    # BmAttributeId: constructor param, fromList, toList.
    (
        "data class BmAttributeId (\n  val uuid: String,",
        "data class BmAttributeId (\n  val uuid: Uuid,",
    ),
    (
        "      val uuid = pigeonVar_list[0] as String\n"
        "      val instance = pigeonVar_list[1] as Long\n"
        "      return BmAttributeId(uuid, instance)",
        "      val uuid = Uuid.parse(pigeonVar_list[0] as String)\n"
        "      val instance = pigeonVar_list[1] as Long\n"
        "      return BmAttributeId(uuid, instance)",
    ),
    (
        "    return listOf(\n      uuid,\n      instance,\n    )",
        "    return listOf(\n      uuid.str,\n      instance,\n    )",
    ),
    # BmDescriptorRef: constructor param, fromList, toList.
    (
        "  /** Descriptor uuids are unique within a characteristic; no instance needed. */\n"
        "  val uuid: String",
        "  /** Descriptor uuids are unique within a characteristic; no instance needed. */\n"
        "  val uuid: Uuid",
    ),
    (
        "      val uuid = pigeonVar_list[1] as String\n"
        "      return BmDescriptorRef(characteristic, uuid)",
        "      val uuid = Uuid.parse(pigeonVar_list[1] as String)\n"
        "      return BmDescriptorRef(characteristic, uuid)",
    ),
    (
        "    return listOf(\n      characteristic,\n      uuid,\n    )",
        "    return listOf(\n      characteristic,\n      uuid.str,\n    )",
    ),
])
EOF

dart format lib/src/messages.g.dart
