// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_descriptor.dart';
import 'bluetooth_device.dart';
import 'bluetooth_service.dart';

/// A typed view over a [BluetoothCharacteristic]: its value-carrying members
/// ([read], [write], [notifications], …) are mapped to `T` while everything else
/// delegates to the wrapped characteristic.
///
/// Create one with [BluetoothCharacteristicMapping.map]:
/// ```dart
/// final level = characteristic.map((bytes) => bytes.first, encode: (n) => [n]);
/// final n = await level.read();          // Future<int>
/// level.notifications.listen(print);      // Stream<int>
/// await level.write(42);                  // encodes then writes
/// ```
///
/// It is *not* a [BluetoothCharacteristic] (its `read` returns `Future<T>`), but
/// mirrors its API; reach the underlying characteristic via [raw].
class MappedBluetoothCharacteristic<T> {
  /// The wrapped characteristic. Use it to access the raw `List<int>` API.
  final BluetoothCharacteristic raw;

  final T Function(List<int> bytes) _decode;
  final List<int> Function(T value)? _encode;

  MappedBluetoothCharacteristic._(this.raw, this._decode, this._encode);

  List<int> _encodeOrThrow(T value) {
    final encode = _encode;
    if (encode == null) {
      throw StateError('mapped characteristic is read-only: no encode was given to map()');
    }
    return encode(value);
  }

  //
  // mapped value members
  //

  /// [BluetoothCharacteristic.read], decoded to [T].
  Future<T> read({Duration timeout = const Duration(seconds: 15)}) async =>
      _decode(await raw.read(timeout: timeout));

  /// [BluetoothCharacteristic.write], encoding [value] first.
  /// Throws a [StateError] if this mapping has no encode function.
  Future<void> write(
    T value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    Duration timeout = const Duration(seconds: 15),
  }) =>
      raw.write(
        _encodeOrThrow(value),
        withoutResponse: withoutResponse,
        allowLongWrite: allowLongWrite,
        timeout: timeout,
      );

  /// [BluetoothCharacteristic.notifications], decoded to [T].
  Stream<T> get notifications => raw.notifications.map(_decode);

  /// [BluetoothCharacteristic.notificationsPassive], decoded to [T].
  Stream<T> get notificationsPassive => raw.notificationsPassive.map(_decode);

  /// [BluetoothCharacteristic.values], decoded to [T].
  Stream<T> get values => raw.values.map(_decode);

  /// [BluetoothCharacteristic.valuesPassive], decoded to [T].
  Stream<T> get valuesPassive => raw.valuesPassive.map(_decode);

  /// A further-mapped view over the same underlying characteristic.
  MappedBluetoothCharacteristic<S> map<S>(
    S Function(T value) decode, {
    T Function(S value)? encode,
  }) {
    final innerEncode = _encode;
    return MappedBluetoothCharacteristic._(
      raw,
      (bytes) => decode(_decode(bytes)),
      (encode != null && innerEncode != null) ? (s) => innerEncode(encode(s)) : null,
    );
  }

  //
  // delegated metadata
  //

  Uuid get uuid => raw.uuid;
  int? get index => raw.index;
  BluetoothAttributeId get id => raw.id;
  BluetoothDevice get device => raw.device;
  BluetoothService get service => raw.service;
  CharacteristicProperties get properties => raw.properties;
  List<BluetoothDescriptor> get descriptors => raw.descriptors;
  BluetoothDescriptor? get cccd => raw.cccd;
  bool get canRead => raw.canRead;
  bool get canWrite => raw.canWrite;
  bool get canNotify => raw.canNotify;
  bool get isValid => raw.isValid;

  /// [BluetoothCharacteristic.subscribe] — keeps notify on until unsubscribed.
  Future<CharacteristicSubscription> subscribe({Duration timeout = const Duration(seconds: 15)}) =>
      raw.subscribe(timeout: timeout);

  @override
  String toString() => 'MappedBluetoothCharacteristic<$T>{raw: $raw}';
}

extension BluetoothCharacteristicMapping on BluetoothCharacteristic {
  /// A typed view over this characteristic. [decode] maps received bytes to [T];
  /// [encode] (required only if you [MappedBluetoothCharacteristic.write]) maps
  /// [T] back to bytes.
  MappedBluetoothCharacteristic<T> map<T>(
    T Function(List<int> bytes) decode, {
    List<int> Function(T value)? encode,
  }) =>
      MappedBluetoothCharacteristic._(this, decode, encode);
}

/// A typed view over a [BluetoothDescriptor]: [read] / [write] are mapped to `T`
/// while everything else delegates to the wrapped descriptor. Create one with
/// [BluetoothDescriptorMapping.map]. Reach the underlying descriptor via [raw].
class MappedBluetoothDescriptor<T> {
  /// The wrapped descriptor. Use it to access the raw `List<int>` API.
  final BluetoothDescriptor raw;

  final T Function(List<int> bytes) _decode;
  final List<int> Function(T value)? _encode;

  MappedBluetoothDescriptor._(this.raw, this._decode, this._encode);

  List<int> _encodeOrThrow(T value) {
    final encode = _encode;
    if (encode == null) {
      throw StateError('mapped descriptor is read-only: no encode was given to map()');
    }
    return encode(value);
  }

  /// [BluetoothDescriptor.read], decoded to [T].
  Future<T> read({Duration timeout = const Duration(seconds: 15)}) async =>
      _decode(await raw.read(timeout: timeout));

  /// [BluetoothDescriptor.write], encoding [value] first.
  /// Throws a [StateError] if this mapping has no encode function.
  Future<void> write(T value, {Duration timeout = const Duration(seconds: 15)}) =>
      raw.write(_encodeOrThrow(value), timeout: timeout);

  /// A further-mapped view over the same underlying descriptor.
  MappedBluetoothDescriptor<S> map<S>(
    S Function(T value) decode, {
    T Function(S value)? encode,
  }) {
    final innerEncode = _encode;
    return MappedBluetoothDescriptor._(
      raw,
      (bytes) => decode(_decode(bytes)),
      (encode != null && innerEncode != null) ? (s) => innerEncode(encode(s)) : null,
    );
  }

  Uuid get uuid => raw.uuid;
  int? get index => raw.index;
  BluetoothAttributeId get id => raw.id;
  BluetoothDevice get device => raw.device;
  BluetoothCharacteristic get characteristic => raw.characteristic;
  bool get isValid => raw.isValid;

  @override
  String toString() => 'MappedBluetoothDescriptor<$T>{raw: $raw}';
}

extension BluetoothDescriptorMapping on BluetoothDescriptor {
  /// A typed view over this descriptor. [decode] maps read bytes to [T];
  /// [encode] (required only if you [MappedBluetoothDescriptor.write]) maps
  /// [T] back to bytes.
  MappedBluetoothDescriptor<T> map<T>(
    T Function(List<int> bytes) decode, {
    List<int> Function(T value)? encode,
  }) =>
      MappedBluetoothDescriptor._(this, decode, encode);
}
