// Pigeon schema for the flutter_blue_plus platform channel protocol.
//
// This is the single source of truth for all messages exchanged between the
// Dart platform interface and the native (Kotlin/Swift) implementations.
// Regenerate with: tool/generate.sh

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: '../flutter_blue_plus_android/android/src/main/kotlin/com/lib/flutter_blue_plus/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.lib.flutter_blue_plus'),
    swiftOut: '../flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/Messages.g.swift',
    dartPackageName: 'flutter_blue_plus',
  ),
)

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

enum BmAdapterStateEnum {
  unknown,
  unavailable,
  unauthorized,
  turningOn,
  on,
  turningOff,
  off,
}

enum BmConnectionStateEnum {
  disconnected,
  connected,
}

enum BmWriteType {
  withResponse,
  withoutResponse,
}

enum BmConnectionPriorityEnum {
  balanced,
  high,
  lowPower,
}

enum BmBondStateEnum {
  none,
  bonding,
  bonded,
}

enum LogLevel {
  none,
  error,
  warning,
  info,
  debug,
  verbose,
}

/// Single source of truth for error codes, shared by every platform.
///
/// Errors cross the channel as `PlatformException.code` *strings* (pigeon
/// cannot type that field), so the wire form of each code is, by convention,
/// the snake_case of its name here (e.g. [FbpErrorCode.deviceDisconnected]
/// crosses as `"device_disconnected"`). Each language has a small `wire`
/// helper implementing that convention; never hand-write a code string.
enum FbpErrorCode {
  success,
  timeout,
  platform,
  serviceNotFound,
  characteristicNotFound,
  userRejected,
  removeBondFailed,
  // codes emitted by the native implementations:
  gattError,
  cbError,
  deviceDisconnected,
  adapterOff,
  notConnected,
  invalidIdentifier,
  bondFailed,
  userCanceled,
  unsupported,
  operationInProgress,
  permissionDenied,
  invalidArgument,
}

// ─────────────────────────────────────────────────────────────────────────────
// Attribute references
//
// A GATT attribute is addressed by its uuid plus a platform-opaque instance
// token that disambiguates duplicate uuids (Android: instanceId, darwin:
// object pointer). Refs compose hierarchically instead of the legacy
// "uuid:instance/uuid:instance" path strings.
// ─────────────────────────────────────────────────────────────────────────────

/// The universal uuid:instance pair identifying one attribute.
class BmAttributeId {
  late String uuid;

  /// Platform-opaque token disambiguating duplicate uuids.
  late int instance;
}

class BmServiceRef {
  late BmAttributeId service;

  /// Set when this is a secondary (included) service.
  BmAttributeId? parentService;
}

class BmCharacteristicRef {
  late BmServiceRef service;
  late BmAttributeId characteristic;
}

class BmDescriptorRef {
  late BmCharacteristicRef characteristic;

  /// Descriptor uuids are unique within a characteristic; no instance needed.
  late String uuid;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scanning
// ─────────────────────────────────────────────────────────────────────────────

class BmMsdFilter {
  late int manufacturerId;
  Uint8List? data;
  Uint8List? mask;
}

class BmServiceDataFilter {
  late String service;
  late Uint8List data;
  Uint8List? mask;
}

class BmScanSettings {
  late List<String> withServices;
  late List<String> withRemoteIds;
  late List<String> withNames;
  late List<String> withKeywords;
  late List<BmMsdFilter> withMsd;
  late List<BmServiceDataFilter> withServiceData;
  late bool continuousUpdates;
  late int continuousDivisor;
  late bool androidLegacy;
  late int androidScanMode;
  late bool androidUsesFineLocation;
  late List<String> webOptionalServices;
}

class BmScanAdvertisement {
  late String address;
  String? platformName;
  String? advName;
  late bool connectable;
  int? txPowerLevel;

  /// Not supported on iOS / macOS.
  int? appearance;
  late Map<int, Uint8List> manufacturerData;
  late Map<String, Uint8List> serviceData;
  late List<String> serviceUuids;
  late int rssi;
}

// ─────────────────────────────────────────────────────────────────────────────
// Devices and the GATT tree
// ─────────────────────────────────────────────────────────────────────────────

class BmBluetoothDevice {
  late String address;
  String? platformName;
}

class BmBluetoothService {
  late BmAttributeId id;
  late bool isPrimary;
  late List<BmBluetoothCharacteristic> characteristics;
  late List<BmServiceRef> includedServices;
}

class BmBluetoothCharacteristic {
  late BmAttributeId id;
  late List<BmBluetoothDescriptor> descriptors;
  late BmCharacteristicProperties properties;
}

class BmBluetoothDescriptor {
  late String uuid;
}

class BmCharacteristicProperties {
  late bool broadcast;
  late bool read;
  late bool writeWithoutResponse;
  late bool write;
  late bool notify;
  late bool indicate;
  late bool authenticatedSignedWrites;
  late bool extendedProperties;
  late bool notifyEncryptionRequired;
  late bool indicateEncryptionRequired;
}

class BmPhySupport {
  /// High speed (PHY 2M)
  late bool le2M;

  /// Long range (PHY codec)
  late bool leCoded;
}

// ─────────────────────────────────────────────────────────────────────────────
// Events (native → Dart, unsolicited)
// ─────────────────────────────────────────────────────────────────────────────

sealed class BmEvent {}

class BmAdapterStateEvent extends BmEvent {
  late BmAdapterStateEnum adapterState;
}

class BmScanAdvertisementsEvent extends BmEvent {
  late List<BmScanAdvertisement> advertisements;
}

class BmScanFailedEvent extends BmEvent {
  late int errorCode;
  late String errorString;
}

class BmConnectionStateEvent extends BmEvent {
  late String address;
  late BmConnectionStateEnum connectionState;
  int? disconnectReasonCode;
  String? disconnectReasonString;
}

/// A characteristic value received via notify/indicate. Read responses are
/// returned from [FlutterBluePlusHostApi.readCharacteristic] instead.
class BmCharacteristicNotificationEvent extends BmEvent {
  late String address;
  late BmCharacteristicRef characteristic;
  late Uint8List value;
}

class BmBondStateEvent extends BmEvent {
  late String address;
  late BmBondStateEnum bondState;
  BmBondStateEnum? prevState;
}

class BmNameChangedEvent extends BmEvent {
  late String address;
  late String name;
}

class BmServicesResetEvent extends BmEvent {
  late String address;
}

/// Emitted on any MTU change: solicited (requestMtu) or peer-initiated on
/// Android; on darwin, emitted after connect and whenever the negotiated
/// value changes (CoreBluetooth has no MTU callback, so the plugin polls
/// while devices are connected).
class BmMtuChangedEvent extends BmEvent {
  late String address;
  late int mtu;
}

class BmDetachedFromEngineEvent extends BmEvent {
  /// Carries no information — pigeon requires data classes to have a field.
  bool? unused;
}

@EventChannelApi()
abstract class FlutterBluePlusEventChannelApi {
  BmEvent nativeEvents();
}

// ─────────────────────────────────────────────────────────────────────────────
// Host API (Dart → native)
//
// Error contract: natives reject with stable string codes — "gatt_error",
// "cb_error", "device_disconnected", "adapter_off", "not_connected",
// "invalid_identifier", "bond_failed", "user_canceled", "unsupported",
// "operation_in_progress" — human message, and the raw native status int as
// details.
// ─────────────────────────────────────────────────────────────────────────────

@HostApi()
abstract class FlutterBluePlusHostApi {
  // lifecycle / adapter
  /// Hot-restart handshake: disconnects and closes everything, returns the
  /// number of devices still closing.
  int flutterRestart();
  int connectedCount();
  void setLogLevel(LogLevel level);
  void setOptions(bool showPowerAlert, bool restoreState);
  bool isSupported();

  /// @async: may need to request runtime permissions before answering.
  @async
  String getAdapterName();
  BmAdapterStateEnum getAdapterState();

  /// Android: shows the enable-bluetooth dialog; completes with user consent.
  @async
  bool turnOn();
  @async
  bool turnOff();

  // scanning — startScan completes once the scan is running (it may first
  // need to request runtime permissions); advertisements/errors arrive on the
  // event stream
  @async
  void startScan(BmScanSettings settings);
  void stopScan();
  @async
  List<BmBluetoothDevice> getSystemDevices(List<String> withServices);
  @async
  List<BmBluetoothDevice> getBondedDevices();

  // connection
  @async
  void connect(String address);
  @async
  void disconnect(String address);
  @async
  List<BmBluetoothService> discoverServices(String address);

  // GATT operations
  @async
  Uint8List readCharacteristic(String address, BmCharacteristicRef characteristic);
  @async
  void writeCharacteristic(
    String address,
    BmCharacteristicRef characteristic,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  );
  @async
  Uint8List readDescriptor(String address, BmDescriptorRef descriptor);
  @async
  void writeDescriptor(String address, BmDescriptorRef descriptor, Uint8List value);

  /// Completes after the CCCD write confirms (or immediately if no CCCD).
  @async
  bool setNotifyValue(String address, BmCharacteristicRef characteristic, bool forceIndications, bool enable);

  @async
  int requestMtu(String address, int mtu);
  @async
  int readRssi(String address);

  // android-only extras
  void requestConnectionPriority(String address, BmConnectionPriorityEnum connectionPriority);
  BmPhySupport getPhySupport();
  @async
  void setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions);

  // bonding (android)
  BmBondStateEnum getBondState(String address);
  @async
  bool createBond(String address, Uint8List? pin);
  @async
  bool removeBond(String address);
  @async
  void clearGattCache(String address);
}
