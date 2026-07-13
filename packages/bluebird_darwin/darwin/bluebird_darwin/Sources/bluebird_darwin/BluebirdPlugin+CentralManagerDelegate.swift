// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import CoreBluetooth
import Foundation

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

extension BluebirdPlugin: CBCentralManagerDelegate {

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log(.debug, "centralManagerDidUpdateState \(cbManagerStateString(central.state))")

    // stop scanning when the adapter is turned off. Otherwise, scanning
    // automatically resumes when the adapter is turned back on, which most
    // users don't expect.
    if central.state != .poweredOn {
      central.stopScan()
    }

    sink?.success(BmAdapterStateEvent(adapterState: bmAdapterState(central.state)))

    if central.state != .poweredOn {
      // inexplicably, iOS does not call 'didDisconnectPeripheral' when the
      // adapter is turned off, so we must send these events manually.
      // Note: it is 'api misuse' to call cancelPeripheralConnection when the
      // adapter is off. It is implied.
      for (address, state) in peripherals where state.connection == .connected {
        log(.debug, "adapter off: synthesizing disconnection for \(address)")
        sink?.success(
          BmConnectionStateEvent(
            address: address,
            connectionState: .disconnected,
            disconnectReasonCode: Self.adapterOffDisconnectCode,
            disconnectReasonString: "Bluetooth turned off"))
      }
      let states = Array(peripherals.values)
      peripherals.removeAll()
      stopMtuPollingIfIdle()

      let error = PigeonError(
        code: BluebirdErrorCode.adapterOff.wire, message: "the adapter is turned off", details: nil)
      states.forEach { $0.failAllPending(error) }
    }
  }

  #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
      log(.debug, "centralManagerWillRestoreState")

      // restore adapter state
      centralManagerDidUpdateState(central)

      let peripherals =
        dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
      for peripheral in peripherals {
        let address = peripheral.identifier.uuidString
        knownPeripherals[address] = peripheral
        peripheral.delegate = self

        if peripheral.state != .connected {
          log(.debug, "Restore: reconnecting to \(address)")
          central.connect(peripheral, options: nil)
        } else {
          log(.debug, "Restore: already connected to \(address)")
          centralManager(central, didConnect: peripheral)
        }
      }
    }
  #endif

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    log(.verbose, "centralManager didDiscoverPeripheral")

    let remoteId = peripheral.identifier.uuidString

    // add to known peripherals
    knownPeripherals[remoteId] = peripheral

    guard let settings = scanSettings else { return }

    let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
    let advMsd = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    let advSd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]

    // custom filters (implemented by Bluebird, not the OS)
    guard
      ScanFilters.allows(
        settings,
        remoteId: remoteId,
        advName: advName,
        advServices: advServices,
        msd: advMsd,
        serviceData: advSd)
    else { return }

    // filter divisor
    if settings.continuousUpdates && settings.continuousDivisor > 1 {
      let count = scanCountIncrement(remoteId)
      if count % Int(settings.continuousDivisor) != 0 {
        return
      }
    }

    let advertisement = bmScanAdvertisement(
      address: remoteId,
      peripheral: knownPeripherals[remoteId],
      advertisementData: advertisementData,
      rssi: RSSI)

    sink?.success(BmScanAdvertisementEvent(advertisement: advertisement))
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    log(.debug, "didConnectPeripheral")

    let address = peripheral.identifier.uuidString

    // remember the connected peripherals of *this app*
    knownPeripherals[address] = peripheral
    let state = peripherals[address] ?? PeripheralState(peripheral)
    state.connection = .connected
    peripherals[address] = state

    // register self as delegate for peripheral
    peripheral.delegate = self

    state.takeConnect()?.resume(returning: ())

    sink?.success(BmConnectionStateEvent(address: address, connectionState: .connected))

    // iOS negotiates the mtu automatically during connection but offers no
    // callback for it, and it usually hasn't happened yet at didConnect time.
    // Emit the current value now, then poll for the negotiated value.
    let mtu = getMtu(peripheral)
    state.mtu = mtu
    sink?.success(BmMtuChangedEvent(address: address, mtu: Int64(mtu)))
    startMtuPolling()
  }

  public func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    log(.error, "didFailToConnectPeripheral: \(error?.localizedDescription ?? "")")

    let address = peripheral.identifier.uuidString
    let state = peripherals[address]
    if state?.connection == .connecting {
      peripherals.removeValue(forKey: address)
    }

    let failure =
      error.map(cbError)
      ?? PigeonError(code: BluebirdErrorCode.cbError.wire, message: "failed to connect", details: nil)
    state?.takeConnect()?.resume(throwing: failure)
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    if let error {
      log(.error, "didDisconnectPeripheral: \(error.localizedDescription)")
    } else {
      log(.debug, "didDisconnectPeripheral")
    }

    let address = peripheral.identifier.uuidString

    let state = peripherals.removeValue(forKey: address)
    stopMtuPollingIfIdle()

    // unregister self as delegate for peripheral
    peripheral.delegate = nil

    state?.takeDisconnect()?.resume(returning: ())

    // a pending connect means the connection was canceled or failed
    state?.takeConnect()?.resume(
      throwing: error.map(cbError)
        ?? PigeonError(
          code: BluebirdErrorCode.userCanceled.wire, message: "connection canceled", details: nil))

    // fail whatever GATT operation was still in flight
    state?.failAllPending(deviceDisconnectedError())

    sink?.success(
      BmConnectionStateEvent(
        address: address,
        connectionState: .disconnected,
        disconnectReasonCode: (error as NSError?).map { Int64($0.code) }
          ?? Self.userCanceledErrorCode,
        disconnectReasonString: error?.localizedDescription ?? "connection canceled"))
  }
}
