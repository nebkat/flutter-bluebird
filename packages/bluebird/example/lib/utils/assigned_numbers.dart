// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Name lookups over the Bluetooth SIG Assigned Numbers registry.
///
/// The `bluebird` package deliberately carries only a handful of well-known
/// names ([Uuid.name]) so it stays dependency- and weight-free; this app ships
/// the whole registry instead, generated from the SIG's own published YAML by
/// `tool/gen_assigned_numbers.dart`, so a scan can put a name next to almost
/// every number it turns up.
library;

import 'package:bluebird/bluebird.dart';

import 'assigned_numbers/appearance_values.g.dart';
import 'assigned_numbers/company_identifiers.g.dart';
import 'assigned_numbers/uuid_names.g.dart';

export 'assigned_numbers/appearance_values.g.dart';
export 'assigned_numbers/company_identifiers.g.dart';
export 'assigned_numbers/uuid_names.g.dart';

/// The base every 16-bit and 32-bit SIG assigned number expands to. A UUID that
/// does not sit on this base is a vendor UUID and has no assigned name.
const _sigBaseSuffix = '-0000-1000-8000-00805f9b34fb';

/// The registry a 16-bit assigned UUID is listed in. Each range belongs to
/// exactly one registry, so the number alone says which kind of thing it names.
enum UuidRegistry {
  service('Service', serviceUuidNames),
  characteristic('Characteristic', characteristicUuidNames),
  descriptor('Descriptor', descriptorUuidNames),
  declaration('Declaration', declarationUuidNames),
  serviceClass('Service Class', serviceClassUuidNames),
  member('Member', memberUuidNames),
  sdo('SDO', sdoUuidNames);

  const UuidRegistry(this.label, this.names);

  /// Human-readable registry name, e.g. for a tooltip or a subtitle.
  final String label;

  /// The assigned number → name table for this registry.
  final Map<int, String> names;
}

/// Registry lookups keyed by something other than a [Uuid].
abstract final class AssignedNumbers {
  /// The SIG company name for a 16-bit company identifier — the key of an
  /// advertisement's manufacturer-specific data — or null if it isn't assigned.
  static String? companyName(int id) => companyIdentifiers[id];

  /// A company identifier as `0x004C (Apple, Inc.)`, or bare hex when the id
  /// isn't assigned (so an unrecognised device still shows *something*).
  static String companyLabel(int id) => _labelled(hex16(id), companyName(id));

  /// The GAP appearance name for a 16-bit appearance value, falling back to the
  /// category name when the exact subcategory isn't assigned (the low 6 bits
  /// are the subcategory, so masking them off gives the category).
  static String? appearanceName(int value) => appearanceValues[value] ?? appearanceValues[value & 0xFFC0];

  /// An appearance value as `0x0341 (Heart Rate Sensor: Heart Rate Belt)`.
  static String appearanceLabel(int value) => _labelled(hex16(value), appearanceName(value));

  /// A 16-bit number in the `0xNNNN` form the SIG writes it in.
  static String hex16(int value) => '0x${value.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

extension UuidAssignedNumber on Uuid {
  /// The 16-bit SIG assigned number this UUID stands for, or null when it is a
  /// vendor UUID (one that isn't built on the SIG base UUID).
  int? get assignedNumber {
    final full = string128;
    if (!full.startsWith('0000') || !full.endsWith(_sigBaseSuffix)) return null;
    return int.tryParse(full.substring(4, 8), radix: 16);
  }

  /// The registry [assignedNumber] is listed in, or null if it isn't listed.
  UuidRegistry? get assignedRegistry {
    final number = assignedNumber;
    if (number == null) return null;
    for (final registry in UuidRegistry.values) {
      if (registry.names.containsKey(number)) return registry;
    }
    return null;
  }

  /// The SIG name for this UUID, e.g. `Uuid('2A24').assignedName` is
  /// `'Model Number String'`. Null for a vendor or unassigned UUID.
  String? get assignedName {
    final number = assignedNumber;
    return number == null ? null : assignedRegistry?.names[number];
  }

  /// This UUID as `0x180F` when it is an assigned number, and in full 128-bit
  /// form when it is a vendor UUID (where a `0x` prefix would be misleading).
  String get hex {
    final number = assignedNumber;
    return number == null ? string128.toUpperCase() : AssignedNumbers.hex16(number);
  }

  /// This UUID as `0x180F (Battery)`, or just [hex] when it has no known name.
  String get labelled => _labelled(hex, assignedName);
}

String _labelled(String hex, String? name) => name == null ? hex : '$hex ($name)';
