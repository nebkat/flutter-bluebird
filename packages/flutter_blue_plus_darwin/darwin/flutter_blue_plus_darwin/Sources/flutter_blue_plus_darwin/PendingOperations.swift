// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Key for pending operations targeting a specific attribute of a device.
struct DeviceOpKey<Ref: Hashable>: Hashable {
  let address: String
  let ref: Ref
}

/// A map of in-flight completions for a single kind of operation.
///
/// Contract:
/// - `register` fails the *new* completion with "operation_in_progress" if an
///   operation for the same key already exists, and returns false.
/// - `take` removes and returns the completion, guaranteeing exactly-once
///   invocation by the caller.
final class PendingMap<Key: Hashable, Value> {
  private var completions: [Key: (Result<Value, Error>) -> Void] = [:]

  /// Registers a completion. Returns false (and fails `completion`) if an
  /// operation with the same key is already in flight.
  func register(_ key: Key, _ completion: @escaping (Result<Value, Error>) -> Void) -> Bool {
    if completions[key] != nil {
      completion(
        .failure(
          PigeonError(
            code: FbpErrorCode.operationInProgress.wire,
            message: "this operation is already in progress",
            details: nil)))
      return false
    }
    completions[key] = completion
    return true
  }

  /// Removes and returns the completion for `key`, if any.
  func take(_ key: Key) -> ((Result<Value, Error>) -> Void)? {
    return completions.removeValue(forKey: key)
  }

  /// Fails every pending operation whose key matches `predicate`.
  func failAll(where predicate: (Key) -> Bool, error: Error) {
    let keys = completions.keys.filter(predicate)
    for key in keys {
      completions.removeValue(forKey: key)?(.failure(error))
    }
  }

  /// Fails every pending operation.
  func failAll(error: Error) {
    let all = completions
    completions.removeAll()
    for (_, completion) in all {
      completion(.failure(error))
    }
  }

  /// Drops all pending operations *without* invoking them
  /// (hot restart / flutterRestart — the dart side no longer exists).
  func clearAll() {
    completions.removeAll()
  }
}

/// Typed per-operation storage for all @async host-api calls that complete
/// from CoreBluetooth delegate callbacks.
final class PendingOperations {
  let connect = PendingMap<String, Void>()
  let disconnect = PendingMap<String, Void>()
  let discover = PendingMap<String, [BmBluetoothService]>()
  let rssi = PendingMap<String, Int64>()
  let charRead = PendingMap<DeviceOpKey<BmCharacteristicRef>, FlutterStandardTypedData>()
  let charWrite = PendingMap<DeviceOpKey<BmCharacteristicRef>, Void>()
  let setNotify = PendingMap<DeviceOpKey<BmCharacteristicRef>, Bool>()
  let descRead = PendingMap<DeviceOpKey<BmDescriptorRef>, FlutterStandardTypedData>()
  let descWrite = PendingMap<DeviceOpKey<BmDescriptorRef>, Void>()

  /// Fails every attribute-level operation for one device (used when the
  /// device disconnects). Connect/disconnect are handled explicitly by the
  /// caller before this is invoked.
  func failAllForDevice(_ address: String, error: Error) {
    discover.failAll(where: { $0 == address }, error: error)
    rssi.failAll(where: { $0 == address }, error: error)
    charRead.failAll(where: { $0.address == address }, error: error)
    charWrite.failAll(where: { $0.address == address }, error: error)
    setNotify.failAll(where: { $0.address == address }, error: error)
    descRead.failAll(where: { $0.address == address }, error: error)
    descWrite.failAll(where: { $0.address == address }, error: error)
  }

  /// Fails every pending operation of every kind (adapter turned off).
  func failAll(error: Error) {
    connect.failAll(error: error)
    disconnect.failAll(error: error)
    discover.failAll(error: error)
    rssi.failAll(error: error)
    charRead.failAll(error: error)
    charWrite.failAll(error: error)
    setNotify.failAll(error: error)
    descRead.failAll(error: error)
    descWrite.failAll(error: error)
  }

  /// Drops everything without invoking (hot restart / engine detach).
  func clearAll() {
    connect.clearAll()
    disconnect.clearAll()
    discover.clearAll()
    rssi.clearAll()
    charRead.clearAll()
    charWrite.clearAll()
    setNotify.clearAll()
    descRead.clearAll()
    descWrite.clearAll()
  }
}
