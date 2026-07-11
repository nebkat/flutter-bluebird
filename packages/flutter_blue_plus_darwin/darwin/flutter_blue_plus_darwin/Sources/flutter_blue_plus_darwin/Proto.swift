// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
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

/// Wraps a CoreBluetooth NSError as a stable "cb_error" with the raw native
/// code as details.
func cbError(_ error: Error) -> PigeonError {
  let ns = error as NSError
  return PigeonError(code: "cb_error", message: ns.localizedDescription, details: Int64(ns.code))
}

func notConnectedError() -> PigeonError {
  return PigeonError(code: "not_connected", message: "device is disconnected", details: nil)
}

func deviceDisconnectedError() -> PigeonError {
  return PigeonError(code: "device_disconnected", message: "device is disconnected", details: nil)
}

func adapterOffError(_ state: CBManagerState) -> PigeonError {
  return PigeonError(
    code: "adapter_off",
    message: "bluetooth must be turned on. (\(cbManagerStateString(state)))",
    details: nil)
}

func unsupportedError(_ message: String) -> PigeonError {
  return PigeonError(code: "unsupported", message: message, details: nil)
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

func bmAdapterState(_ state: CBManagerState) -> BmAdapterStateEnum {
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
    BmBluetoothDescriptor(uuid: $0.uuid.uuidStr)
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
  if let manufData = manufData, manufData.count >= 2 {
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
// Scan filters (implemented by FBP, not by the OS)
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
    if !isAnyFilterSet(settings) {
      return true
    }
    if foundService(settings.withServices, target: advServices) {
      return true
    }
    if foundRemoteId(settings.withRemoteIds, target: remoteId) {
      return true
    }
    if foundName(settings.withNames, target: advName) {
      return true
    }
    if foundKeyword(settings.withKeywords, target: advName) {
      return true
    }
    if foundMsd(settings.withMsd, msd: msd) {
      return true
    }
    if foundServiceData(settings.withServiceData, sd: serviceData) {
      return true
    }
    return false
  }

  static func foundService(_ services: [String], target: [CBUUID]?) -> Bool {
    guard let target = target, !target.isEmpty else { return false }
    let lowercased = services.map { $0.lowercased() }
    for uuid in target where lowercased.contains(uuid.uuidStr) {
      return true
    }
    return false
  }

  static func foundName(_ names: [String], target: String?) -> Bool {
    guard let target = target else { return false }
    return names.contains(target)
  }

  static func foundKeyword(_ keywords: [String], target: String?) -> Bool {
    guard let target = target else { return false }
    for keyword in keywords where target.contains(keyword) {
      return true
    }
    return false
  }

  static func foundRemoteId(_ remoteIds: [String], target: String?) -> Bool {
    guard let target = target?.lowercased() else { return false }
    for remoteId in remoteIds where remoteId.lowercased() == target {
      return true
    }
    return false
  }

  static func foundMsd(_ filters: [BmMsdFilter], msd: Data?) -> Bool {
    guard let msd = msd, msd.count >= 2 else { return false }

    // first 2 bytes are the manufacturer id (little endian)
    let bytes = [UInt8](msd.prefix(2))
    let manufId = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

    // trim off first 2 bytes
    let trimmed = msd.subdata(in: 2..<msd.count)

    for filter in filters {
      let data = filter.data?.data ?? Data()
      var mask = filter.mask?.data ?? Data()
      if mask.isEmpty && !data.isEmpty {
        mask = Data(repeating: 0xFF, count: data.count)
      }
      if Int64(manufId) == filter.manufacturerId && findData(data, in: trimmed, mask: mask) {
        return true
      }
    }
    return false
  }

  static func foundServiceData(_ filters: [BmServiceDataFilter], sd: [CBUUID: Data]?) -> Bool {
    guard let sd = sd, !sd.isEmpty else { return false }
    for filter in filters {
      let data = filter.data.data
      var mask = filter.mask?.data ?? Data()
      if mask.isEmpty && !data.isEmpty {
        mask = Data(repeating: 0xFF, count: data.count)
      }
      let service = filter.service.lowercased()
      for (uuid, value) in sd
      where uuid.uuidStr == service && findData(data, in: value, mask: mask) {
        return true
      }
    }
    return false
  }

  /// Bitwise masked prefix comparison of `find` against `data`.
  static func findData(_ find: Data, in data: Data, mask: Data) -> Bool {
    // find & mask must be the same length; data must be long enough
    guard find.count == mask.count, data.count >= find.count else { return false }
    let f = [UInt8](find)
    let d = [UInt8](data)
    let m = [UInt8](mask)
    for i in 0..<f.count where (f[i] & m[i]) != (d[i] & m[i]) {
      return false
    }
    return true
  }
}
