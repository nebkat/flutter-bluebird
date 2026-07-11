// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Uuids {
  static const Uuid gattService = Uuid.constant([0x18, 0x01]);
  static const Uuid servicesChangedCharacteristic = Uuid.constant([0x2A, 0x05]);
  static const Uuid cccdDescriptor = Uuid.constant([0x29, 0x02]);
}

/// A Bluetooth UUID which can be 16-bit, 32-bit, or 128-bit.
class Uuid {
  final List<int> bytes;

  const Uuid.empty() : bytes = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  const Uuid.constant(this.bytes);

  Uuid.fromBytes(this.bytes)
      : assert(
          bytes.length == 2 || bytes.length == 4 || bytes.length == 16,
          "UUID must be 16, 32, or 128 bits long",
        );

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
        _ => "${bytes.sublist(0, 4).toHexString()}-"
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

  @override
  String toString() => string;

  /// Uuids are compared by value in their 128-bit form, so the same uuid
  /// expressed in short (16/32-bit) and long form compare equal.
  @override
  operator ==(Object other) => other is Uuid && string128 == other.string128;

  @override
  int get hashCode => string128.hashCode;
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
