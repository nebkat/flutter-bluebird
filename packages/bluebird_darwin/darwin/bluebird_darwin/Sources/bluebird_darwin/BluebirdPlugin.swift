// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
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

/// Per-device state for a peripheral we are connecting to or connected to.
/// Mirrors the Android side's DeviceConnection.
final class PeripheralState {
  enum Connection { case connecting, connected }

  let peripheral: CBPeripheral
  var connection: Connection = .connecting

  /// last observed mtu (see checkForMtuChanges)
  var mtu = 23

  // service discovery bookkeeping
  var discoveredServices: [CBService] = []
  var servicesToDiscover: [CBService] = []
  var characteristicsToDiscover: [CBCharacteristic] = []

  init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }

  func clearDiscoveryState() {
    discoveredServices = []
    servicesToDiscover = []
    characteristicsToDiscover = []
  }
}

/// iOS / macOS implementation of bluebird.
///
/// All host-api methods and CoreBluetooth delegate callbacks run on the main
/// thread (the CBCentralManager is created with the main queue), so no
/// locking is required.
public class BluebirdPlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate,
  CBPeripheralDelegate
{
  var sink: PigeonEventSink<BmEvent>?

  private var centralManager: CBCentralManager?

  /// Strong references to every CBPeripheral we have seen. CoreBluetooth does
  /// not keep strong references itself and warns about API misuse otherwise.
  private var knownPeripherals: [String: CBPeripheral] = [:]

  /// Per-device state, keyed by device address. Only devices currently
  /// connecting or connected have an entry.
  private var peripherals: [String: PeripheralState] = [:]

  private let pending = PendingOperations()

  // scanning
  private var scanSettings: BmScanSettings?
  private var scanCounts: [String: Int] = [:]

  private var mtuPollTimer: Timer?

  private var logLevel: LogLevel = .debug
  private var showPowerAlert = true
  private var restoreState = false

  /// random error code defined by bluebird for user-initiated
  /// connection cancellation
  private static let userCanceledErrorCode: Int64 = 23789258
  /// random error code defined by bluebird for adapter-off
  /// disconnections
  private static let adapterOffDisconnectCode: Int64 = 1573878

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let instance = BluebirdPlugin()
    BluebirdHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    NativeEventsStreamHandler.register(
      with: messenger, streamHandler: BluebirdStreamHandler(plugin: instance))
  }

  #if os(iOS)
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
      log(.debug, "detachFromEngine")
      pending.clearAll()
      sink?.success(BmDetachedFromEngineEvent())
      sink?.endOfStream()
      sink = nil
    }
  #endif

  // ───────────────────────────────────────────────────────────────────────────
  // Utils
  // ───────────────────────────────────────────────────────────────────────────

  /// Lazily initializes the CBCentralManager, honoring setOptions.
  @discardableResult
  private func ensureCentralManager() -> CBCentralManager {
    if let central = centralManager {
      return central
    }

    log(.debug, "initializing CBCentralManager")

    var options: [String: Any] = [:]
    if showPowerAlert {
      options[CBCentralManagerOptionShowPowerAlertKey] = true
    }
    #if os(iOS)
      if restoreState {
        options[CBCentralManagerOptionRestoreIdentifierKey] = "bluebirdRestoreIdentifier"
      }
    #endif

    log(.debug, "showPowerAlert: \(showPowerAlert ? "yes" : "no")")
    log(.debug, "restoreState: \(restoreState ? "yes" : "no")")

    let central = CBCentralManager(delegate: self, queue: nil, options: options)
    centralManager = central
    return central
  }

  private var isAdapterOn: Bool {
    centralManager?.state == .poweredOn
  }

  /// The peripheral for `address`, if currently connected.
  private func connectedPeripheral(_ address: String) -> CBPeripheral? {
    guard let state = peripherals[address], state.connection == .connected else { return nil }
    return state.peripheral
  }

  private var connectedPeripheralCount: Int {
    peripherals.values.filter { $0.connection == .connected }.count
  }

  private func log(_ level: LogLevel, _ message: String) {
    if level.rawValue <= logLevel.rawValue {
      NSLog("[Bluebird-Darwin] %@", message)
    }
  }

  /// Logs a delegate callback result: error at .error level, otherwise
  /// `detail` at .debug level.
  private func logResult(_ name: String, _ error: Error?, _ detail: @autoclosure () -> String) {
    if let error {
      log(.error, "\(name): \(error.localizedDescription)")
    } else {
      log(.debug, "\(name): \(detail())")
    }
  }

  /// Completes a pending operation from a delegate callback: failure with the
  /// wrapped CoreBluetooth error, or success with `success()`.
  private func complete<T>(
    _ completion: ((Result<T, Error>) -> Void)?, _ error: Error?, success: @autoclosure () -> T
  ) {
    guard let completion else { return }
    if let error {
      completion(.failure(cbError(error)))
    } else {
      completion(.success(success()))
    }
  }

  /// if allowLongWrite is disabled, we can only write up to MTU-3
  private func getMaxPayload(
    _ peripheral: CBPeripheral, type: CBCharacteristicWriteType, allowLongWrite: Bool
  ) -> Int {
    let effectiveType: CBCharacteristicWriteType = allowLongWrite ? type : .withoutResponse
    let maxForType = peripheral.maximumWriteValueLength(for: effectiveType)
    // In order to operate the same on both iOS & Android, we enforce a
    // maximum of 512, the maxAttrLen of a characteristic in the BLE spec.
    return min(maxForType, 512)
  }

  private func getMtu(_ peripheral: CBPeripheral) -> Int {
    return getMaxPayload(peripheral, type: .withoutResponse, allowLongWrite: false) + 3  // ATT overhead
  }

  /// iOS & macOS negotiate the mtu automatically sometime after the
  /// connection process, but there is no platform callback for it, and
  /// `maximumWriteValueLength` still returns the un-negotiated default at
  /// `didConnect` time. So, while any device is connected, poll for changes
  /// and emit BmMtuChangedEvent when the negotiated value appears.
  private func startMtuPolling() {
    guard mtuPollTimer == nil else { return }
    mtuPollTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
      self?.checkForMtuChanges()
    }
  }

  private func stopMtuPollingIfIdle() {
    if connectedPeripheralCount == 0 {
      mtuPollTimer?.invalidate()
      mtuPollTimer = nil
    }
  }

  private func checkForMtuChanges() {
    for (address, state) in peripherals where state.connection == .connected {
      let mtu = getMtu(state.peripheral)
      if state.mtu != mtu {
        state.mtu = mtu
        log(.debug, "mtu changed: \(mtu) (\(address))")
        sink?.success(BmMtuChangedEvent(address: address, mtu: Int64(mtu)))
      }
    }
    stopMtuPollingIfIdle()
  }

  private func scanCountIncrement(_ remoteId: String) -> Int {
    let count = scanCounts[remoteId] ?? 0
    scanCounts[remoteId] = count + 1
    return count
  }

  // ───────────────────────────────────────────────────────────────────────────
  // CBCentralManagerDelegate
  // ───────────────────────────────────────────────────────────────────────────

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
      peripherals.removeAll()
      stopMtuPollingIfIdle()

      pending.failAll(
        error: PigeonError(code: BluebirdErrorCode.adapterOff.wire, message: "the adapter is turned off", details: nil))
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

    sink?.success(BmScanAdvertisementsEvent(advertisements: [advertisement]))
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

    pending.connect.take(address)?(.success(()))

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
    if peripherals[address]?.connection == .connecting {
      peripherals.removeValue(forKey: address)
    }

    let failure =
      error.map(cbError)
      ?? PigeonError(code: BluebirdErrorCode.cbError.wire, message: "failed to connect", details: nil)
    pending.connect.take(address)?(.failure(failure))
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

    peripherals.removeValue(forKey: address)
    stopMtuPollingIfIdle()

    // unregister self as delegate for peripheral
    peripheral.delegate = nil

    pending.disconnect.take(address)?(.success(()))

    // a pending connect means the connection was canceled or failed
    if let connect = pending.connect.take(address) {
      let failure =
        error.map(cbError)
        ?? PigeonError(code: BluebirdErrorCode.userCanceled.wire, message: "connection canceled", details: nil)
      connect(.failure(failure))
    }

    pending.failAllForDevice(address, error: deviceDisconnectedError())

    sink?.success(
      BmConnectionStateEvent(
        address: address,
        connectionState: .disconnected,
        disconnectReasonCode: (error as NSError?).map { Int64($0.code) }
          ?? Self.userCanceledErrorCode,
        disconnectReasonString: error?.localizedDescription ?? "connection canceled"))
  }

  // ───────────────────────────────────────────────────────────────────────────
  // CBPeripheralDelegate — service discovery
  // ───────────────────────────────────────────────────────────────────────────

  /// Handles the error case shared by all discovery callbacks: logs, resets
  /// discovery bookkeeping, and fails the pending discoverServices call.
  /// Returns true if an error was handled.
  private func failDiscoveryIfNeeded(_ name: String, _ address: String, _ error: Error?) -> Bool {
    guard let error else { return false }
    log(.error, "\(name): \(error.localizedDescription)")
    peripherals[address]?.clearDiscoveryState()
    pending.discover.take(address)?(.failure(cbError(error)))
    return true
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverServices", address, error) { return }
    log(.debug, "didDiscoverServices")

    guard let state = peripherals[address] else { return }

    let services = peripheral.services ?? []
    state.discoveredServices = services
    state.servicesToDiscover = services
    state.characteristicsToDiscover = []

    // discover characteristics and included services
    for service in services {
      log(.debug, "  svc: \(service.uuid.uuidStr)")
      peripheral.discoverIncludedServices(nil, for: service)
      peripheral.discoverCharacteristics(nil, for: service)
    }

    maybeCompleteDiscovery(peripheral)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverIncludedServicesFor service: CBService,
    error: Error?
  ) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverIncludedServicesForService", address, error) { return }
    log(.debug, "didDiscoverIncludedServicesForService: \(service.uuid.uuidStr)")

    guard let state = peripherals[address] else { return }

    for included in service.includedServices ?? [] {
      log(.debug, "    svc: \(included.uuid.uuidStr)")

      // don't try to discover services we already know about
      if state.discoveredServices.contains(where: { $0 === included }) {
        continue
      }

      state.discoveredServices.append(included)
      state.servicesToDiscover.append(included)
      peripheral.discoverCharacteristics(nil, for: included)
      peripheral.discoverIncludedServices(nil, for: included)
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverCharacteristicsForService", address, error) { return }
    log(.debug, "didDiscoverCharacteristicsForService: \(service.uuid.uuidStr)")

    guard let state = peripherals[address] else { return }
    state.servicesToDiscover.removeAll { $0 === service }

    // loop through and discover descriptors for characteristics
    let characteristics = service.characteristics ?? []
    state.characteristicsToDiscover.append(contentsOf: characteristics)
    for characteristic in characteristics {
      log(.debug, "    chr: \(characteristic.uuid.uuidStr)")
      peripheral.discoverDescriptors(for: characteristic)
    }

    maybeCompleteDiscovery(peripheral)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverDescriptorsFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverDescriptorsForCharacteristic", address, error) { return }
    log(.debug, "didDiscoverDescriptorsForCharacteristic: \(characteristic.uuid.uuidStr)")

    guard let state = peripherals[address] else { return }
    state.characteristicsToDiscover.removeAll { $0 === characteristic }

    maybeCompleteDiscovery(peripheral)
  }

  /// Completes the pending discoverServices call once every service has
  /// reported its characteristics and every characteristic its descriptors.
  private func maybeCompleteDiscovery(_ peripheral: CBPeripheral) {
    let address = peripheral.identifier.uuidString

    guard let state = peripherals[address],
      state.servicesToDiscover.isEmpty,
      state.characteristicsToDiscover.isEmpty,
      let complete = pending.discover.take(address)
    else { return }

    complete(.success(state.discoveredServices.map { bmBluetoothService($0, in: peripheral) }))
  }

  // ───────────────────────────────────────────────────────────────────────────
  // CBPeripheralDelegate — GATT operations
  // ───────────────────────────────────────────────────────────────────────────

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // this callback is shared by manual reads and notifications
    logResult("didUpdateValueForCharacteristic", error, characteristic.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = characteristicRef(for: characteristic, in: peripheral) else { return }
    let key = DeviceOpKey(address: address, ref: ref)

    if let read = pending.charRead.take(key) {
      // a pending read exists: this is the read response
      complete(read, error, success: FlutterStandardTypedData(bytes: characteristic.value ?? Data()))
    } else if error == nil {
      // otherwise it's a notification / indication
      sink?.success(
        BmCharacteristicNotificationEvent(
          address: address,
          characteristic: ref,
          value: FlutterStandardTypedData(bytes: characteristic.value ?? Data())))
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // note: this callback is only called for writeWithResponse
    logResult("didWriteValueForCharacteristic", error, characteristic.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = characteristicRef(for: characteristic, in: peripheral) else { return }

    complete(pending.charWrite.take(DeviceOpKey(address: address, ref: ref)), error, success: ())
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    logResult("didUpdateNotificationStateForCharacteristic", error, characteristic.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = characteristicRef(for: characteristic, in: peripheral) else { return }

    complete(
      pending.setNotify.take(DeviceOpKey(address: address, ref: ref)), error,
      success: characteristic.isNotifying)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    logResult("didUpdateValueForDescriptor", error, descriptor.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = descriptorRef(for: descriptor, in: peripheral) else { return }

    complete(
      pending.descRead.take(DeviceOpKey(address: address, ref: ref)), error,
      success: FlutterStandardTypedData(bytes: descriptorValueData(descriptor)))
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    logResult("didWriteValueForDescriptor", error, descriptor.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = descriptorRef(for: descriptor, in: peripheral) else { return }

    complete(pending.descWrite.take(DeviceOpKey(address: address, ref: ref)), error, success: ())
  }

  public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    logResult("didReadRSSI", error, "\(RSSI)")

    let address = peripheral.identifier.uuidString
    complete(pending.rssi.take(address), error, success: Int64(truncating: RSSI))
  }

  public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
    log(.debug, "didUpdateName: \(peripheral.name ?? "")")
    sink?.success(
      BmNameChangedEvent(
        address: peripheral.identifier.uuidString,
        name: peripheral.name ?? ""))
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]
  ) {
    log(.debug, "didModifyServices")
    sink?.success(BmServicesResetEvent(address: peripheral.identifier.uuidString))
  }

  public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    log(.verbose, "peripheralIsReadyToSendWriteWithoutResponse")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Host API
// ─────────────────────────────────────────────────────────────────────────────

extension BluebirdPlugin: BluebirdHostApi {

  func flutterRestart() throws -> Int64 {
    let central = ensureCentralManager()

    if isAdapterOn {
      central.stopScan()
    }

    // all dart state is reset after a hot restart, so reset native state too
    pending.clearAll()
    peripherals.values.forEach { $0.clearDiscoveryState() }
    scanSettings = nil
    scanCounts.removeAll()

    // request disconnection of everything
    if isAdapterOn {
      for (address, state) in peripherals {
        if state.connection == .connected {
          log(.debug, "flutterRestart: disconnecting \(address)")
        }
        central.cancelPeripheralConnection(state.peripheral)
      }
    }

    log(.debug, "connectedPeripherals: \(connectedPeripheralCount)")

    // note: we do *not* clear knownPeripherals, otherwise the peripherals
    // would lose their last strong reference and didDisconnectPeripheral
    // would never be called
    if connectedPeripheralCount == 0 {
      knownPeripherals.removeAll()
    }

    return Int64(connectedPeripheralCount)
  }

  func connectedCount() throws -> Int64 {
    log(.debug, "connectedPeripherals: \(connectedPeripheralCount)")
    if connectedPeripheralCount == 0 {
      log(.debug, "Hot Restart: complete")
      knownPeripherals.removeAll()
    }
    return Int64(connectedPeripheralCount)
  }

  func setLogLevel(level: LogLevel) throws {
    logLevel = level
  }

  func setOptions(showPowerAlert: Bool, restoreState: Bool) throws {
    self.showPowerAlert = showPowerAlert
    self.restoreState = restoreState
  }

  func isSupported() throws -> Bool {
    ensureCentralManager()
    return centralManager != nil
  }

  func getAdapterName(completion: @escaping (Result<String, Error>) -> Void) {
    ensureCentralManager()
    #if os(iOS)
      completion(.success(UIDevice.current.name))
    #else
      completion(.success(Host.current().localizedName ?? "Mac Bluetooth Adapter"))
    #endif
  }

  func getAdapterState() throws -> BmAdapterStateEnum {
    let central = ensureCentralManager()
    return bmAdapterState(central.state)
  }

  func turnOn(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.failure(unsupportedError("iOS & macOS do not support turning on bluetooth")))
  }

  func turnOff(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.failure(unsupportedError("iOS & macOS do not support turning off bluetooth")))
  }

  func startScan(settings: BmScanSettings, completion: @escaping (Result<Void, Error>) -> Void) {
    let central = ensureCentralManager()

    guard isAdapterOn else {
      completion(.failure(adapterOffError(central.state)))
      return
    }

    // remember this for later
    scanSettings = settings
    scanCounts.removeAll()

    var scanOpts: [String: Any] = [:]
    if settings.continuousUpdates {
      scanOpts[CBCentralManagerScanOptionAllowDuplicatesKey] = true
    }

    // If any custom filter is set then we cannot filter by services.
    // Why? An advertisement can match either the service filter *or* the
    // custom filter. It does not have to match both. So we cannot have
    // iOS & macOS filtering out any advertisements.
    var services: [CBUUID] = []
    if !ScanFilters.hasCustomFilters(settings) {
      services = settings.withServices.map { CBUUID(string: $0) }
    }

    central.scanForPeripherals(
      withServices: services.isEmpty ? nil : services, options: scanOpts)

    completion(.success(()))
  }

  func stopScan() throws {
    ensureCentralManager().stopScan()
  }

  func getSystemDevices(
    withServices: [String], completion: @escaping (Result<[BmBluetoothDevice], Error>) -> Void
  ) {
    let central = ensureCentralManager()
    let services = withServices.map { CBUUID(string: $0) }

    // this returns devices connected by *any* app
    let peripherals = central.retrieveConnectedPeripherals(withServices: services)

    completion(.success(peripherals.map { bmBluetoothDevice($0) }))
  }

  func getBondedDevices(completion: @escaping (Result<[BmBluetoothDevice], Error>) -> Void) {
    completion(.failure(unsupportedError("android only")))
  }

  func connect(address: String, completion: @escaping (Result<Void, Error>) -> Void) {
    let central = ensureCentralManager()

    guard isAdapterOn else {
      completion(.failure(adapterOffError(central.state)))
      return
    }

    // already connected?
    if connectedPeripheral(address) != nil {
      log(.debug, "already connected")
      completion(.success(()))
      return
    }

    guard pending.connect.register(address, completion) else { return }

    guard let uuid = UUID(uuidString: address) else {
      pending.connect.take(address)?(
        .failure(
          PigeonError(code: BluebirdErrorCode.invalidIdentifier.wire, message: "invalid remoteId", details: address)))
      return
    }

    // check the devices iOS knows about
    guard
      let peripheral = central.retrievePeripherals(withIdentifiers: [uuid])
        .first(where: { $0.identifier.uuidString == address })
    else {
      pending.connect.take(address)?(
        .failure(
          PigeonError(
            code: BluebirdErrorCode.invalidIdentifier.wire, message: "peripheral not found", details: address)))
      return
    }

    // we must keep a strong reference to any CBPeripheral before we connect
    // to it. CoreBluetooth does not keep strong references itself.
    knownPeripherals[address] = peripheral

    // set ourself as delegate
    peripheral.delegate = self

    peripherals[address] = PeripheralState(peripheral)
    central.connect(peripheral, options: nil)
  }

  func disconnect(address: String, completion: @escaping (Result<Void, Error>) -> Void) {
    let central = ensureCentralManager()

    // connection still in progress? cancel it
    if let state = peripherals[address], state.connection == .connecting {
      peripherals.removeValue(forKey: address)
      log(.debug, "disconnect: cancelling connection in progress")
      central.cancelPeripheralConnection(state.peripheral)

      // canceling a pending connection does not reliably invoke
      // didDisconnectPeripheral, so complete everything here
      pending.connect.take(address)?(
        .failure(
          PigeonError(code: BluebirdErrorCode.userCanceled.wire, message: "connection canceled", details: nil)))

      sink?.success(
        BmConnectionStateEvent(
          address: address,
          connectionState: .disconnected,
          disconnectReasonCode: Self.userCanceledErrorCode,
          disconnectReasonString: "connection canceled"))

      completion(.success(()))
      return
    }

    // already disconnected?
    guard let peripheral = connectedPeripheral(address) else {
      log(.debug, "already disconnected")
      completion(.success(()))
      return
    }

    guard pending.disconnect.register(address, completion) else { return }

    central.cancelPeripheralConnection(peripheral)
  }

  func discoverServices(
    address: String, completion: @escaping (Result<[BmBluetoothService], Error>) -> Void
  ) {
    ensureCentralManager()

    guard let state = peripherals[address], state.connection == .connected else {
      completion(.failure(notConnectedError()))
      return
    }

    guard pending.discover.register(address, completion) else { return }

    // reset discovery bookkeeping
    state.clearDiscoveryState()

    state.peripheral.discoverServices(nil)
  }

  func readCharacteristic(
    address: String,
    characteristic: BmCharacteristicRef,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    ensureCentralManager()

    guard let peripheral = connectedPeripheral(address) else {
      completion(.failure(notConnectedError()))
      return
    }

    do {
      let chr = try locateCharacteristic(characteristic, in: peripheral)

      // check readable
      guard chr.properties.contains(.read) else {
        throw unsupportedError("The READ property is not supported by this BLE characteristic")
      }

      // key by the canonical ref so the delegate callback finds it
      guard let ref = characteristicRef(for: chr, in: peripheral) else {
        throw notConnectedError()
      }
      guard pending.charRead.register(DeviceOpKey(address: address, ref: ref), completion) else {
        return
      }

      peripheral.readValue(for: chr)
    } catch {
      completion(.failure(error))
    }
  }

  func writeCharacteristic(
    address: String,
    characteristic: BmCharacteristicRef,
    writeType: BmWriteType,
    allowLongWrite: Bool,
    value: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    ensureCentralManager()

    guard let peripheral = connectedPeripheral(address) else {
      completion(.failure(notConnectedError()))
      return
    }

    do {
      let cbWriteType: CBCharacteristicWriteType =
        writeType == .withResponse ? .withResponse : .withoutResponse

      // check maximum payload
      let maxLen = getMaxPayload(peripheral, type: cbWriteType, allowLongWrite: allowLongWrite)
      let dataLen = value.data.count
      if dataLen > maxLen {
        let t = writeType == .withResponse ? "withResponse" : "withoutResponse"
        let a = allowLongWrite ? ", allowLongWrite" : ", noLongWrite"
        let b = writeType == .withResponse ? a : ""
        throw unsupportedError(
          "data longer than allowed. dataLen: \(dataLen) > max: \(maxLen) (\(t)\(b))")
      }

      // device not ready?
      if cbWriteType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
        // canSendWriteWithoutResponse is the current readiness of the
        // peripheral to accept more write requests
        throw unsupportedError("canSendWriteWithoutResponse is false. you must slow down")
      }

      let chr = try locateCharacteristic(characteristic, in: peripheral)

      // check writeable
      if cbWriteType == .withoutResponse {
        guard chr.properties.contains(.writeWithoutResponse) else {
          throw unsupportedError(
            "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic")
        }
      } else {
        guard chr.properties.contains(.write) else {
          throw unsupportedError("The WRITE property is not supported by this BLE characteristic")
        }
      }

      if cbWriteType == .withResponse {
        // key by the canonical ref so the delegate callback finds it
        guard let ref = characteristicRef(for: chr, in: peripheral) else {
          throw notConnectedError()
        }
        guard pending.charWrite.register(DeviceOpKey(address: address, ref: ref), completion)
        else { return }

        peripheral.writeValue(value.data, for: chr, type: .withResponse)
      } else {
        // writes without response are not acknowledged; complete immediately
        peripheral.writeValue(value.data, for: chr, type: .withoutResponse)
        completion(.success(()))
      }
    } catch {
      completion(.failure(error))
    }
  }

  func readDescriptor(
    address: String,
    descriptor: BmDescriptorRef,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    ensureCentralManager()

    guard let peripheral = connectedPeripheral(address) else {
      completion(.failure(notConnectedError()))
      return
    }

    do {
      let desc = try locateDescriptor(descriptor, in: peripheral)

      guard let ref = descriptorRef(for: desc, in: peripheral) else {
        throw notConnectedError()
      }
      guard pending.descRead.register(DeviceOpKey(address: address, ref: ref), completion) else {
        return
      }

      peripheral.readValue(for: desc)
    } catch {
      completion(.failure(error))
    }
  }

  func writeDescriptor(
    address: String,
    descriptor: BmDescriptorRef,
    value: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    ensureCentralManager()

    guard let peripheral = connectedPeripheral(address) else {
      completion(.failure(notConnectedError()))
      return
    }

    do {
      // check mtu
      let mtu = getMtu(peripheral)
      let dataLen = value.data.count
      if (mtu - 3) < dataLen {
        throw unsupportedError(
          "data is longer than MTU allows. dataLen: \(dataLen) > maxDataLen: \(mtu - 3)")
      }

      let desc = try locateDescriptor(descriptor, in: peripheral)

      guard let ref = descriptorRef(for: desc, in: peripheral) else {
        throw notConnectedError()
      }
      guard pending.descWrite.register(DeviceOpKey(address: address, ref: ref), completion) else {
        return
      }

      peripheral.writeValue(value.data, for: desc)
    } catch {
      completion(.failure(error))
    }
  }

  func setNotifyValue(
    address: String,
    characteristic: BmCharacteristicRef,
    forceIndications: Bool,
    enable: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    ensureCentralManager()

    guard let peripheral = connectedPeripheral(address) else {
      completion(.failure(notConnectedError()))
      return
    }

    do {
      let chr = try locateCharacteristic(characteristic, in: peripheral)

      // check notify-able
      let canNotify = chr.properties.contains(.notify)
      let canIndicate = chr.properties.contains(.indicate)
      guard canNotify || canIndicate else {
        throw unsupportedError(
          "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic")
      }

      // check that the CCCD is present — necessary for subscribing
      let cccd = CBUUID(string: CBUUIDClientCharacteristicConfigurationString)
      if !(chr.descriptors?.contains(where: { $0.uuid == cccd }) ?? false) {
        log(
          .warning,
          "Warning: CCCD descriptor for characteristic not found: \(chr.uuid.uuidStr)")
      }

      guard let ref = characteristicRef(for: chr, in: peripheral) else {
        throw notConnectedError()
      }
      guard pending.setNotify.register(DeviceOpKey(address: address, ref: ref), completion) else {
        return
      }

      peripheral.setNotifyValue(enable, for: chr)
    } catch {
      completion(.failure(error))
    }
  }

  func requestMtu(
    address: String, mtu: Int64, completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    completion(
      .failure(unsupportedError("iOS & macOS do not allow mtu requests to the peripheral")))
  }

  func readRssi(address: String, completion: @escaping (Result<Int64, Error>) -> Void) {
    ensureCentralManager()

    guard let peripheral = connectedPeripheral(address) else {
      completion(.failure(notConnectedError()))
      return
    }

    guard pending.rssi.register(address, completion) else { return }

    peripheral.readRSSI()
  }

  func requestConnectionPriority(
    address: String, connectionPriority: BmConnectionPriorityEnum
  ) throws {
    throw unsupportedError("android only")
  }

  func getPhySupport() throws -> BmPhySupport {
    throw unsupportedError("android only")
  }

  func setPreferredPhy(
    address: String, txPhy: Int64, rxPhy: Int64, phyOptions: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(.failure(unsupportedError("android only")))
  }

  func getBondState(address: String) throws -> BmBondStateEnum {
    throw unsupportedError("android only")
  }

  func createBond(
    address: String, pin: FlutterStandardTypedData?,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    completion(.failure(unsupportedError("android only")))
  }

  func removeBond(address: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.failure(unsupportedError("android only")))
  }

  func clearGattCache(address: String, completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(unsupportedError("android only")))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Event channel
// ─────────────────────────────────────────────────────────────────────────────

class BluebirdStreamHandler: NativeEventsStreamHandler {
  private weak var plugin: BluebirdPlugin?

  init(plugin: BluebirdPlugin) {
    self.plugin = plugin
  }

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<BmEvent>) {
    plugin?.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    plugin?.sink = nil
  }
}
