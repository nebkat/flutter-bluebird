// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A Bluetooth UUID which can be 16-bit, 32-bit, or 128-bit.
class Uuid {
  final List<int> bytes;

  const Uuid.constant(this.bytes);

  Uuid.fromBytes(this.bytes)
    : assert(bytes.length == 2 || bytes.length == 4 || bytes.length == 16, "UUID must be 16, 32, or 128 bits long");

  factory Uuid(String input) {
    if (input.length == 4 || input.length == 8) {
      return Uuid.fromBytes(_tryHexDecode(input) ?? (throw FormatException("UUID invalid hex", input)));
    } else if (input.length == 36) {
      if (input[8] != '-' || input[13] != '-' || input[18] != '-' || input[23] != '-') {
        throw FormatException("UUID 128-bit must be in the format XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", input);
      }
      input = input.replaceAll('-', '');
      return Uuid.fromBytes(_tryHexDecode(input) ?? (throw FormatException("UUID invalid hex", input)));
    } else {
      throw FormatException("UUID must be 4, 8, or 36 characters long", input);
    }
  }

  // 128-bit representation
  String get string128 => switch (bytes.length) {
    2 => '0000${bytes.toHexString()}-0000-1000-8000-00805f9b34fb'.toLowerCase(),
    4 => '${bytes.toHexString()}-0000-1000-8000-00805f9b34fb'.toLowerCase(),
    _ =>
      "${bytes.sublist(0, 4).toHexString()}-"
              "${bytes.sublist(4, 6).toHexString()}-"
              "${bytes.sublist(6, 8).toHexString()}-"
              "${bytes.sublist(8, 10).toHexString()}-"
              "${bytes.sublist(10, 16).toHexString()}"
          .toLowerCase(),
  };

  // Shortest representation
  String get string => switch (bytes.length) {
    2 || 4 => bytes.toHexString(),
    _ => string128,
  };

  /// The human-readable name of this UUID if it is a well-known Bluetooth SIG
  /// assigned number (e.g. `Uuid('2A24').name == 'Model Number String'`), else
  /// null. See [Uuids.nameOf].
  String? get name => Uuids.nameOf(this);

  /// The 16-bit SIG short code if this is a 16-bit assigned-number UUID (i.e. it
  /// uses the standard `0000xxxx-0000-1000-8000-00805f9b34fb` base), else null.
  int? get _sigShortCode {
    final s = string128;
    if (s.startsWith('0000') && s.endsWith('-0000-1000-8000-00805f9b34fb')) {
      return int.tryParse(s.substring(4, 8), radix: 16);
    }
    return null;
  }

  @override
  String toString() => string;

  /// Uuids are compared by value in their 128-bit form, so the same uuid
  /// expressed in short (16/32-bit) and long form compare equal.
  @override
  operator ==(Object other) => other is Uuid && string128 == other.string128;

  @override
  int get hashCode => string128.hashCode;
}

/// Well-known Bluetooth SIG assigned UUIDs, grouped by kind:
/// `Uuids.service.*`, `Uuids.characteristic.*`, `Uuids.descriptor.*`.
class Uuids {
  const Uuids._();

  static const service = _Services._();
  static const characteristic = _Characteristics._();
  static const descriptor = _Descriptors._();

  /// The human-readable name of a well-known Bluetooth SIG UUID, or null if it
  /// is not a recognized 16-bit assigned number. See [Uuid.name].
  static String? nameOf(Uuid uuid) {
    final short = uuid._sigShortCode;
    return short == null ? null : _names[short];
  }

  /// Assigned-number → name, keyed by the 16-bit SIG short code. Covers the
  /// common services (0x18xx), characteristics (0x2Axx), and descriptors
  /// (0x29xx); it is a useful subset, not the full registry.
  static const Map<int, String> _names = {
    // Services
    0x1800: 'Generic Access',
    0x1801: 'Generic Attribute',
    0x1802: 'Immediate Alert',
    0x1803: 'Link Loss',
    0x1804: 'Tx Power',
    0x1805: 'Current Time',
    0x1809: 'Health Thermometer',
    0x180A: 'Device Information',
    0x180D: 'Heart Rate',
    0x180F: 'Battery',
    0x1812: 'Human Interface Device',
    0x181A: 'Environmental Sensing',
    // Characteristics
    0x2A00: 'Device Name',
    0x2A01: 'Appearance',
    0x2A05: 'Service Changed',
    0x2A19: 'Battery Level',
    0x2A1C: 'Temperature Measurement',
    0x2A23: 'System ID',
    0x2A24: 'Model Number String',
    0x2A25: 'Serial Number String',
    0x2A26: 'Firmware Revision String',
    0x2A27: 'Hardware Revision String',
    0x2A28: 'Software Revision String',
    0x2A29: 'Manufacturer Name String',
    0x2A2A: 'IEEE 11073-20601 Regulatory Certification Data List',
    0x2A37: 'Heart Rate Measurement',
    0x2A38: 'Body Sensor Location',
    0x2A50: 'PnP ID',
    // Descriptors
    0x2900: 'Characteristic Extended Properties',
    0x2901: 'Characteristic User Description',
    0x2902: 'Client Characteristic Configuration',
    0x2903: 'Server Characteristic Configuration',
    0x2904: 'Characteristic Presentation Format',
    0x2905: 'Characteristic Aggregate Format',
    0x2906: 'Valid Range',
    0x2907: 'External Report Reference',
    0x2908: 'Report Reference',
    0x2909: 'Number of Digitals',
    0x290A: 'Value Trigger Setting',
    0x290B: 'Environmental Sensing Configuration',
    0x290C: 'Environmental Sensing Measurement',
    0x290D: 'Environmental Sensing Trigger Setting',
    0x290E: 'Time Trigger Setting',
  };
}

class _Services {
  const _Services._();
  final genericAccess = const Uuid.constant([0x18, 0x00]);
  final genericAttribute = const Uuid.constant([0x18, 0x01]);
  final immediateAlert = const Uuid.constant([0x18, 0x02]);
  final linkLoss = const Uuid.constant([0x18, 0x03]);
  final txPower = const Uuid.constant([0x18, 0x04]);
  final currentTime = const Uuid.constant([0x18, 0x05]);
  final healthThermometer = const Uuid.constant([0x18, 0x09]);
  final deviceInformation = const Uuid.constant([0x18, 0x0A]);
  final heartRate = const Uuid.constant([0x18, 0x0D]);
  final battery = const Uuid.constant([0x18, 0x0F]);
  final humanInterfaceDevice = const Uuid.constant([0x18, 0x12]);
  final environmentalSensing = const Uuid.constant([0x18, 0x1A]);
}

class _Characteristics {
  const _Characteristics._();
  final deviceName = const Uuid.constant([0x2A, 0x00]);
  final appearance = const Uuid.constant([0x2A, 0x01]);
  final serviceChanged = const Uuid.constant([0x2A, 0x05]);
  final temperatureMeasurement = const Uuid.constant([0x2A, 0x1C]);
  final batteryLevel = const Uuid.constant([0x2A, 0x19]);
  final systemId = const Uuid.constant([0x2A, 0x23]);
  final modelNumber = const Uuid.constant([0x2A, 0x24]);
  final serialNumber = const Uuid.constant([0x2A, 0x25]);
  final firmwareRevision = const Uuid.constant([0x2A, 0x26]);
  final hardwareRevision = const Uuid.constant([0x2A, 0x27]);
  final softwareRevision = const Uuid.constant([0x2A, 0x28]);
  final manufacturerName = const Uuid.constant([0x2A, 0x29]);
  final ieeeRegulatoryCertificationData = const Uuid.constant([0x2A, 0x2A]);
  final pnpId = const Uuid.constant([0x2A, 0x50]);
  final heartRateMeasurement = const Uuid.constant([0x2A, 0x37]);
  final bodySensorLocation = const Uuid.constant([0x2A, 0x38]);
}

class _Descriptors {
  const _Descriptors._();
  final characteristicExtendedProperties = const Uuid.constant([0x29, 0x00]);
  final characteristicUserDescription = const Uuid.constant([0x29, 0x01]);
  final clientCharacteristicConfiguration = const Uuid.constant([0x29, 0x02]);
  final serverCharacteristicConfiguration = const Uuid.constant([0x29, 0x03]);
  final characteristicPresentationFormat = const Uuid.constant([0x29, 0x04]);
  final characteristicAggregateFormat = const Uuid.constant([0x29, 0x05]);
  final validRange = const Uuid.constant([0x29, 0x06]);
  final externalReportReference = const Uuid.constant([0x29, 0x07]);
  final reportReference = const Uuid.constant([0x29, 0x08]);
  final numberOfDigitals = const Uuid.constant([0x29, 0x09]);
  final valueTriggerSetting = const Uuid.constant([0x29, 0x0A]);
  final environmentalSensingConfiguration = const Uuid.constant([0x29, 0x0B]);
  final environmentalSensingMeasurement = const Uuid.constant([0x29, 0x0C]);
  final environmentalSensingTriggerSetting = const Uuid.constant([0x29, 0x0D]);
  final timeTriggerSetting = const Uuid.constant([0x29, 0x0E]);
}

extension _IntHexString on int {
  String toHexString([int? width]) {
    if (width == null) return toRadixString(16);
    assert(
      this < 1 << (width * 4),
      "Value too large for specified width: ${toRadixString(16)} >= ${(1 << (width * 4)).toRadixString(16)}",
    );
    return toRadixString(16).padLeft(width, '0');
  }
}

extension _ListIntHexString on List<int> {
  String toHexString([int? width = 2]) => map((e) => e.toHexString(width)).join();
}

List<int>? _tryHexDecode(String hex) {
  List<int> numbers = [];
  for (int i = 0; i < hex.length; i += 2) {
    String hexPart = hex.substring(i, i + 2);
    int? num = int.tryParse(hexPart, radix: 16);
    if (num == null) {
      return null;
    }
    numbers.add(num);
  }
  return numbers;
}
