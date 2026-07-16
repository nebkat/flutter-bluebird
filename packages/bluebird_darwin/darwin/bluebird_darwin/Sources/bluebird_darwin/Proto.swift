// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import CoreBluetooth
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

extension BluebirdErrorCode {
  /// The snake_case wire form of this error code (crosses the channel as
  /// `PlatformException.code`).
  var wire: String {
    var out = ""
    for c in String(describing: self) {
      if c.isUppercase {
        out.append("_")
        out.append(contentsOf: c.lowercased())
      } else {
        out.append(c)
      }
    }
    return out
  }
}

/// Wraps a CoreBluetooth NSError. An ATT protocol error (CBATTErrorDomain)
/// carries the spec ATT code directly, so it is surfaced uniformly as
/// "att_error" with the raw code as details — matching Android. Any other
/// domain stays "darwin_error" with the native domain + code as details (e.g.
/// "CBErrorDomain (3)"), so the exact cause is recoverable on the Dart side.
func cbError(_ error: Error) -> PigeonError {
  let ns = error as NSError
  if ns.domain == CBATTErrorDomain {
    return PigeonError(
      code: BluebirdErrorCode.attError.wire, message: ns.localizedDescription, details: Int64(ns.code))
  }
  return PigeonError(
    code: BluebirdErrorCode.darwinError.wire, message: ns.localizedDescription, details: "\(ns.domain) (\(ns.code))")
}

func notConnectedError() -> PigeonError {
  PigeonError(
    code: BluebirdErrorCode.notConnected.wire, message: "device is disconnected", details: nil)
}

func deviceDisconnectedError() -> PigeonError {
  PigeonError(
    code: BluebirdErrorCode.deviceDisconnected.wire, message: "device is disconnected", details: nil)
}

func operationInProgressError() -> PigeonError {
  PigeonError(
    code: BluebirdErrorCode.operationInProgress.wire,
    message: "this operation is already in progress",
    details: nil)
}

func adapterOffError(_ state: CBManagerState) -> PigeonError {
  PigeonError(
    code: BluebirdErrorCode.adapterOff.wire,
    message: "bluetooth must be turned on. (\(cbManagerStateString(state)))",
    details: nil)
}

func unsupportedError(_ message: String) -> PigeonError {
  PigeonError(code: BluebirdErrorCode.unsupported.wire, message: message, details: nil)
}

func cbManagerStateString(_ state: CBManagerState) -> String {
  switch state {
  case .unknown: return "CBManagerStateUnknown"
  case .unsupported: return "CBManagerStateUnsupported"
  case .unauthorized: return "CBManagerStateUnauthorized"
  case .resetting: return "CBManagerStateResetting"
  case .poweredOn: return "CBManagerStatePoweredOn"
  case .poweredOff: return "CBManagerStatePoweredOff"
  @unknown default: return "unhandled"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

func bmAdapterState(_ state: CBManagerState) -> BluetoothAdapterState {
  switch state {
  case .unknown: return .unknown
  case .unsupported: return .unavailable
  case .unauthorized: return .unauthorized
  case .resetting: return .turningOn
  case .poweredOn: return .on
  case .poweredOff: return .off
  @unknown default: return .unknown
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GATT tree
// ─────────────────────────────────────────────────────────────────────────────

func bmBluetoothDevice(_ peripheral: CBPeripheral) -> BmBluetoothDevice {
  return BmBluetoothDevice(
    address: peripheral.identifier.uuidString,
    platformName: peripheral.name)
}

func bmBluetoothService(_ service: CBService, in peripheral: CBPeripheral) -> BmBluetoothService {
  let characteristics = (service.characteristics ?? []).map { bmBluetoothCharacteristic($0) }

  // included (secondary) services are referenced by ref; their full trees are
  // emitted as separate top-level entries of the discovery result
  let includedServices = (service.includedServices ?? []).map { included in
    BmServiceRef(service: attributeId(included), parentService: attributeId(service))
  }

  return BmBluetoothService(
    id: attributeId(service),
    isPrimary: service.isPrimary,
    characteristics: characteristics,
    includedServices: includedServices)
}

func bmBluetoothCharacteristic(_ characteristic: CBCharacteristic) -> BmBluetoothCharacteristic {
  let descriptors = (characteristic.descriptors ?? []).map {
    // descriptors are uuid-unique within a characteristic, so instance is 0
    BmBluetoothDescriptor(id: BmAttributeId(uuid: $0.uuid.uuidStr, instance: 0))
  }
  return BmBluetoothCharacteristic(
    id: attributeId(characteristic),
    descriptors: descriptors,
    properties: bmCharacteristicProperties(characteristic.properties))
}

func bmCharacteristicProperties(_ props: CBCharacteristicProperties) -> BmCharacteristicProperties {
  return BmCharacteristicProperties(
    broadcast: props.contains(.broadcast),
    read: props.contains(.read),
    writeWithoutResponse: props.contains(.writeWithoutResponse),
    write: props.contains(.write),
    notify: props.contains(.notify),
    indicate: props.contains(.indicate),
    authenticatedSignedWrites: props.contains(.authenticatedSignedWrites),
    extendedProperties: props.contains(.extendedProperties),
    notifyEncryptionRequired: props.contains(.notifyEncryptionRequired),
    indicateEncryptionRequired: props.contains(.indicateEncryptionRequired))
}

/// CBDescriptor values are typed (NSString / NSNumber / NSData) — convert to
/// raw bytes like the ObjC `descriptorToData`.
func descriptorValueData(_ descriptor: CBDescriptor) -> Data {
  guard let value = descriptor.value else { return Data() }
  if let string = value as? String {
    return string.data(using: .utf8) ?? Data()
  }
  if let number = value as? NSNumber {
    var intValue = Int32(truncatingIfNeeded: number.intValue)
    return withUnsafeBytes(of: &intValue) { Data($0) }
  }
  if let data = value as? Data {
    return data
  }
  return Data()
}

// ─────────────────────────────────────────────────────────────────────────────
// Scan advertisements
// ─────────────────────────────────────────────────────────────────────────────

func bmScanAdvertisement(
  address: String,
  peripheral: CBPeripheral?,
  advertisementData: [String: Any],
  rssi: NSNumber
) -> BmScanAdvertisement {
  let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
  let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
  let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber
  let manufData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
  let serviceUuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
  let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]

  // manufacturer data: first 2 bytes are the manufacturer id (little endian)
  var manufacturerData: [Int64: FlutterStandardTypedData] = [:]
  if let manufData, manufData.count >= 2 {
    let bytes = [UInt8](manufData.prefix(2))
    let manufId = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    let trimmed = manufData.subdata(in: 2..<manufData.count)
    manufacturerData[Int64(manufId)] = FlutterStandardTypedData(bytes: trimmed)
  }

  var serviceDataMap: [String: FlutterStandardTypedData] = [:]
  for (uuid, data) in serviceData ?? [:] {
    serviceDataMap[uuid.uuidStr] = FlutterStandardTypedData(bytes: data)
  }

  return BmScanAdvertisement(
    address: address,
    platformName: peripheral?.name,
    advName: advName,
    connectable: connectable?.boolValue ?? false,
    txPowerLevel: txPower.map { Int64(truncating: $0) },
    appearance: nil,  // not supported on iOS / macOS
    manufacturerData: manufacturerData,
    serviceData: serviceDataMap,
    serviceUuids: (serviceUuids ?? []).map { $0.uuidStr },
    rssi: Int64(truncating: rssi))
}

// ─────────────────────────────────────────────────────────────────────────────
// Scan filters (implemented by Bluebird, not by the OS)
// ─────────────────────────────────────────────────────────────────────────────

enum ScanFilters {
  static func hasCustomFilters(_ settings: BmScanSettings) -> Bool {
    return !settings.withRemoteIds.isEmpty
      || !settings.withNames.isEmpty
      || !settings.withKeywords.isEmpty
      || !settings.withMsd.isEmpty
      || !settings.withServiceData.isEmpty
  }

  static func isAnyFilterSet(_ settings: BmScanSettings) -> Bool {
    return !settings.withServices.isEmpty || hasCustomFilters(settings)
  }

  /// Filters are additive: an advertisement can match *any* filter.
  static func allows(
    _ settings: BmScanSettings,
    remoteId: String,
    advName: String?,
    advServices: [CBUUID]?,
    msd: Data?,
    serviceData: [CBUUID: Data]?
  ) -> Bool {
    return !isAnyFilterSet(settings)
      || foundService(settings.withServices, target: advServices)
      || foundRemoteId(settings.withRemoteIds, target: remoteId)
      || foundName(settings.withNames, target: advName)
      || foundKeyword(settings.withKeywords, target: advName)
      || foundMsd(settings.withMsd, msd: msd)
      || foundServiceData(settings.withServiceData, sd: serviceData)
  }

  static func foundService(_ services: [String], target: [CBUUID]?) -> Bool {
    guard let target, !target.isEmpty else { return false }
    let lowercased = services.map { $0.lowercased() }
    return target.contains { lowercased.contains($0.uuidStr) }
  }

  static func foundName(_ names: [String], target: String?) -> Bool {
    guard let target else { return false }
    return names.contains(target)
  }

  static func foundKeyword(_ keywords: [String], target: String?) -> Bool {
    guard let target else { return false }
    return keywords.contains { target.contains($0) }
  }

  static func foundRemoteId(_ remoteIds: [String], target: String?) -> Bool {
    guard let target = target?.lowercased() else { return false }
    return remoteIds.contains { $0.lowercased() == target }
  }

  static func foundMsd(_ filters: [BmMsdFilter], msd: Data?) -> Bool {
    guard let msd, msd.count >= 2 else { return false }

    // first 2 bytes are the manufacturer id (little endian)
    let bytes = [UInt8](msd.prefix(2))
    let manufId = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

    // trim off first 2 bytes
    let trimmed = msd.subdata(in: 2..<msd.count)

    return filters.contains { filter in
      let data = filter.data?.data ?? Data()
      var mask = filter.mask?.data ?? Data()
      if mask.isEmpty && !data.isEmpty {
        mask = Data(repeating: 0xFF, count: data.count)
      }
      return Int64(manufId) == filter.manufacturerId && findData(data, in: trimmed, mask: mask)
    }
  }

  static func foundServiceData(_ filters: [BmServiceDataFilter], sd: [CBUUID: Data]?) -> Bool {
    guard let sd, !sd.isEmpty else { return false }
    return filters.contains { filter in
      let data = filter.data.data
      var mask = filter.mask?.data ?? Data()
      if mask.isEmpty && !data.isEmpty {
        mask = Data(repeating: 0xFF, count: data.count)
      }
      let service = filter.service.lowercased()
      return sd.contains { uuid, value in
        uuid.uuidStr == service && findData(data, in: value, mask: mask)
      }
    }
  }

  /// Bitwise masked prefix comparison of `find` against `data`.
  static func findData(_ find: Data, in data: Data, mask: Data) -> Bool {
    // find & mask must be the same length; data must be long enough
    guard find.count == mask.count, data.count >= find.count else { return false }
    let f = [UInt8](find)
    let d = [UInt8](data)
    let m = [UInt8](mask)
    return f.indices.allSatisfy { (f[$0] & m[$0]) == (d[$0] & m[$0]) }
  }
}
