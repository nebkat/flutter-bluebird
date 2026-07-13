// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import CoreBluetooth
import Foundation

extension CBUUID {
  /// Lowercase uuid string. `CBUUID.uuidString` already uses the shortest
  /// form (16/32-bit) where applicable, matching the ObjC `uuidStr` helper.
  var uuidStr: String {
    uuidString.lowercased()
  }
}

/// Platform-opaque instance token disambiguating duplicate uuids.
/// Mirrors the ObjC identifier strings which used the pointer address
/// (`(uintptr_t)obj`) of the CoreBluetooth object.
func instanceToken(_ obj: AnyObject) -> Int64 {
  Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(obj).toOpaque())))
}

/// The uuid:instance pair identifying one CoreBluetooth attribute.
func attributeId(_ attribute: CBAttribute) -> BmAttributeId {
  BmAttributeId(uuid: attribute.uuid.uuidStr, instance: instanceToken(attribute))
}

private func matches(_ attribute: CBAttribute, _ id: BmAttributeId) -> Bool {
  attribute.uuid.uuidStr == id.uuid.lowercased() && instanceToken(attribute) == id.instance
}

private func findService(_ id: BmAttributeId, in services: [CBService]?) -> CBService? {
  services?.first { matches($0, id) }
}

// ─────────────────────────────────────────────────────────────────────────────
// Building refs from CoreBluetooth objects
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the typed ref for a service. Secondary (included) services carry
/// the id of the primary service that contains them.
func serviceRef(for service: CBService, in peripheral: CBPeripheral) -> BmServiceRef {
  let parent = service.isPrimary
    ? nil
    : peripheral.services?.first { primary in
      primary.includedServices?.contains { $0 === service } ?? false
    }
  return BmServiceRef(service: attributeId(service), parentService: parent.map(attributeId))
}

func characteristicRef(for characteristic: CBCharacteristic, in peripheral: CBPeripheral)
  -> BmCharacteristicRef?
{
  guard let service = characteristic.service else { return nil }
  return BmCharacteristicRef(
    service: serviceRef(for: service, in: peripheral),
    characteristic: attributeId(characteristic))
}

func descriptorRef(for descriptor: CBDescriptor, in peripheral: CBPeripheral) -> BmDescriptorRef? {
  guard let characteristic = descriptor.characteristic,
    let charRef = characteristicRef(for: characteristic, in: peripheral)
  else { return nil }
  // descriptors are uuid-unique within a characteristic, so instance is 0
  return BmDescriptorRef(
    characteristic: charRef, id: BmAttributeId(uuid: descriptor.uuid.uuidStr, instance: 0))
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolving refs back to CoreBluetooth objects
// ─────────────────────────────────────────────────────────────────────────────

private func invalidIdentifier(_ message: String) -> PigeonError {
  PigeonError(code: BluebirdErrorCode.invalidIdentifier.wire, message: message, details: nil)
}

func locateService(_ ref: BmServiceRef, in peripheral: CBPeripheral) throws -> CBService {
  // secondary service: locate the parent first, then search its includedServices
  if let parentId = ref.parentService {
    guard let parent = findService(parentId, in: peripheral.services) else {
      throw invalidIdentifier("service not found in peripheral (svc: '\(parentId.uuid)')")
    }
    guard let service = findService(ref.service, in: parent.includedServices) else {
      throw invalidIdentifier(
        "included service not found in service (svc: '\(ref.service.uuid)', parent: '\(parentId.uuid)')")
    }
    return service
  }

  if let service = findService(ref.service, in: peripheral.services) {
    return service
  }

  // fallback: search included services of every primary service
  for s in peripheral.services ?? [] {
    if let service = findService(ref.service, in: s.includedServices) {
      return service
    }
  }

  throw invalidIdentifier("service not found in peripheral (svc: '\(ref.service.uuid)')")
}

func locateCharacteristic(_ ref: BmCharacteristicRef, in peripheral: CBPeripheral) throws
  -> CBCharacteristic
{
  let service = try locateService(ref.service, in: peripheral)
  guard
    let characteristic = service.characteristics?.first(where: { matches($0, ref.characteristic) })
  else {
    throw invalidIdentifier(
      "characteristic not found in service (chr: '\(ref.characteristic.uuid)', svc: '\(ref.service.service.uuid)')")
  }
  return characteristic
}

func locateDescriptor(_ ref: BmDescriptorRef, in peripheral: CBPeripheral) throws -> CBDescriptor {
  let characteristic = try locateCharacteristic(ref.characteristic, in: peripheral)
  guard
    let descriptor = characteristic.descriptors?.first(where: {
      $0.uuid.uuidStr == ref.id.uuid.lowercased()
    })
  else {
    throw invalidIdentifier(
      "descriptor not found in characteristic (desc: '\(ref.id.uuid)', chr: '\(ref.characteristic.characteristic.uuid)')")
  }
  return descriptor
}
