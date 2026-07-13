// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bluetooth_device.dart';
import 'bluetooth_events.dart';
import 'bluetooth_utils.dart';
import 'utils.dart';

class Bluebird {
  ///////////////////
  //  Internal
  //
  static bool _initialized = false;

  static final StreamController<BluebirdEvent> _eventStream = StreamController.broadcast();

  // always keep track of these device variables
  static final Map<String, BluetoothDevice> _devices = LinkedHashMap<String, BluetoothDevice>(
    equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
    hashCode: (a) => a.toLowerCase().hashCode,
  );

  /// tracks whether a [scan] is currently running (also the guard that prevents
  /// two concurrent scans on the single radio)
  static final _isScanning = StreamControllerReEmit<bool>(initialValue: false);

  /// the last known adapter state
  static BluetoothAdapterState? _adapterStateNow;

  /// Bluebird log level
  static LogLevel _logLevel = LogLevel.debug;

  /// Resets all global state and re-subscribes to the current platform on the
  /// next call. For tests only.
  @visibleForTesting
  static void resetForTest() {
    _devices.clear();
    _adapterStateNow = null;
    _isScanning.add(false);
    _logLevel = LogLevel.debug;
    _initialized = false;
  }

  ////////////////////
  //  Public
  //

  static LogLevel get logLevel => _logLevel;

  /// Checks whether the hardware supports Bluetooth
  static Future<bool> get isSupported async => await invoke("isSupported", (p) => p.isSupported());

  /// Return the friendly Bluetooth name of the local Bluetooth adapter
  static Future<String> get adapterName async => await invoke("getAdapterName", (p) => p.getAdapterName());

  /// whether a [scan] is currently running, as a stream that also exposes the
  /// current value:
  ///   - `Bluebird.isScanning.value` is `true` if scanning right now
  static ValueStream<bool> get isScanning => _isScanning.stream;

  /// The raw stream of all app-level events, of every type.
  ///   - [BluebirdEvent] is `sealed`, so you can `switch` over it exhaustively,
  ///     or filter to the events you care about, e.g.
  ///     `Bluebird.events.where((e) => e is OnMtuChangedEvent)`.
  ///   - most consumers want the scoped streams instead (e.g. `device.mtu`,
  ///     `device.connectionState`, `characteristic.notifications`).
  static Stream<BluebirdEvent> get events => _eventStream.stream;

  /// Set configurable options
  ///   - [showPowerAlert] Whether to show the power alert (iOS & MacOS only). i.e. CBCentralManagerOptionShowPowerAlertKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See: https://developer.apple.com/documentation/corebluetooth/cbcentralmanageroptionshowpoweralertkey
  ///       This option has no effect on Android.
  ///   - [restoreState] Whether to opt into state restoration (iOS & MacOS only). i.e. CBCentralManagerOptionRestoreIdentifierKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See Apple Documentation for more details. This option has no effect on Android.
  static Future<void> setOptions({bool showPowerAlert = true, bool restoreState = false}) async {
    ensurePlatform(System.isDarwin, "setOptions");
    await invoke("setOptions", (p) => p.setOptions(showPowerAlert, restoreState));
  }

  /// Turn on Bluetooth (Android only),
  static Future<void> turnOn({Duration timeout = const Duration(seconds: 60)}) async {
    final userAccepted = await invoke("turnOn", (p) => p.turnOn());

    if (!userAccepted) {
      throw BluebirdException("turnOn", BluebirdErrorCode.userRejected, "user rejected");
    }

    // wait for adapter to turn on
    await adapterState.where((s) => s == BluetoothAdapterState.on).first.bluebirdTimeout(timeout, "turnOn");
  }

  /// The state of the Bluetooth adapter, as a stream that also exposes the
  /// current value via `await Bluebird.adapterState.value`.
  ///   - the platform reports adapter state only on demand (events fire on
  ///     *changes*), so the current value is fetched the first time it is needed.
  static final AsyncValueStream<BluetoothAdapterState> adapterState = AsyncValueStream(
    value: _fetchAdapterState,
    changes: () => extractEventStream<OnAdapterStateChangedEvent>().map((e) => e.adapterState),
  );

  /// Returns the current adapter state, fetching it from the platform the first
  /// time it is needed (adapter events fire only on *changes*).
  static Future<BluetoothAdapterState> _fetchAdapterState() async =>
      (_adapterStateNow ??= await invoke("getAdapterState", (p) => p.getAdapterState()))!;

  /// Retrieve a list of devices currently connected to your app
  static List<BluetoothDevice> get connectedDevices => _devices.values.where((d) => d.isConnected).toList();

  /// Retrieve a list of devices currently connected to the system
  /// - The list includes devices connected to by *any* app
  /// - You must still call device.connect() to connect them to *your app*
  /// - [withServices] required on iOS (for privacy purposes). ignored on android.
  static Future<List<BluetoothDevice>> systemDevices(List<Uuid> withServices) async {
    final devices = await invoke(
      "getSystemDevices",
      (p) => p.getSystemDevices(withServices.map((s) => s.string).toList()),
    );
    return devices.map(_deviceForBm).toList();
  }

  /// Retrieve a list of bonded devices (Android only)
  static Future<List<BluetoothDevice>> get bondedDevices async {
    ensurePlatform(System.isAndroid, "getBondedDevices");
    final devices = await invoke("getBondedDevices", (p) => p.getBondedDevices());
    return devices.map(_deviceForBm).toList();
  }

  static BluetoothDevice _deviceForBm(BmBluetoothDevice d) =>
      deviceForAddress(d.address)..platformNameInternal = d.platformName;

  /// Scan for Bluetooth Low Energy devices, as a stream of advertisements.
  ///
  /// The native scan starts when the returned stream is first listened to, and
  /// stops when the subscription is cancelled — so a `timeout` is just cancel
  /// after a duration, and there is no separate `stopScan`. Only one scan may
  /// run at a time (the radio is a single resource); listening while a scan is
  /// already running throws [BluebirdErrorCode.operationInProgress].
  ///
  /// Each advertisement is emitted one at a time. To collect them into a
  /// growing, de-duplicated device list, use [ScanResultAccumulate.accumulate].
  ///
  /// Note: scan filters use an "or" behavior. i.e. if you set `withServices` &
  /// `withNames` we return all the advertisements that match any of the
  /// specified services *or* any of the specified names.
  ///   - [withServices] filter by advertised services
  ///   - [withRemoteIds] filter for known remoteIds (iOS: 128-bit guid, android: 48-bit mac address)
  ///   - [withNames] filter by advertised names (exact match)
  ///   - [withKeywords] filter by advertised names (matches any substring)
  ///   - [withMsd] filter by manufacturer specific data
  ///   - [withServiceData] filter by service data
  ///   - [continuousUpdates] If `true`, we continually update 'lastSeen' & 'rssi' by processing
  ///        duplicate advertisements. This takes more power. You typically should not use this option.
  ///   - [continuousDivisor] Useful to help performance. If divisor is 3, then two-thirds of advertisements are
  ///        ignored, and one-third are processed. This reduces main-thread usage caused by the platform channel.
  ///        The scan counting is per-device so you always get the 1st advertisement from each device.
  ///        If divisor is 1, all advertisements are returned. This argument only matters for `continuousUpdates` mode.
  ///   - [androidLegacy] Android only. If `true`, scan on 1M phy only.
  ///        If `false`, scan on all supported phys. How the radio cycles through all the supported phys is purely
  ///        dependent on the your Bluetooth stack implementation.
  ///   - [androidScanMode] choose the android scan mode to use when scanning
  ///   - [androidUsesFineLocation] request `ACCESS_FINE_LOCATION` permission at runtime
  static Stream<ScanResult> scan({
    List<Uuid> withServices = const [],
    List<String> withRemoteIds = const [],
    List<String> withNames = const [],
    List<String> withKeywords = const [],
    List<MsdFilter> withMsd = const [],
    List<ServiceDataFilter> withServiceData = const [],
    bool continuousUpdates = false,
    int continuousDivisor = 1,
    bool androidLegacy = false,
    AndroidScanMode androidScanMode = AndroidScanMode.lowLatency,
    bool androidUsesFineLocation = false,
    List<Uuid> webOptionalServices = const [],
  }) async* {
    assert(continuousDivisor >= 1, "divisor must be >= 1");

    // Note: `withKeywords` is not compatible with other filters on android
    // because it is implemented in custom bluebird code, not android code, and the
    // android 'name' filter is only available as of android sdk 33 (August 2022)
    if (System.isAndroid) {
      final hasOtherFilter =
          withServices.isNotEmpty ||
          withRemoteIds.isNotEmpty ||
          withNames.isNotEmpty ||
          withMsd.isNotEmpty ||
          withServiceData.isNotEmpty;
      assert(withKeywords.isEmpty || !hasOtherFilter, "withKeywords is not compatible with other filters on Android");
    }

    // one scan at a time — claim synchronously so concurrent listens can't race
    if (_isScanning.value) {
      throw BluebirdException("scan", BluebirdErrorCode.operationInProgress, "a scan is already in progress");
    }
    _isScanning.add(true);

    final settings = BmScanSettings(
      withServices: withServices.map((s) => s.string).toList(),
      withRemoteIds: withRemoteIds,
      withNames: withNames,
      withKeywords: withKeywords,
      withMsd: withMsd.map((d) => d.bm).toList(),
      withServiceData: withServiceData.map((d) => d.bm).toList(),
      continuousUpdates: continuousUpdates,
      continuousDivisor: continuousDivisor,
      androidLegacy: androidLegacy,
      androidScanMode: androidScanMode.value,
      androidUsesFineLocation: androidUsesFineLocation,
      webOptionalServices: webOptionalServices.map((s) => s.string).toList(),
    );

    // Buffer advertisements from *before* the native scan starts, so none are
    // missed while startScan is in flight.
    final controller = StreamController<ScanResult>();
    final advertisements = extractEventStream<OnScanAdvertisementEvent>()
        .map((e) => e.advertisement)
        .listen(controller.add, onError: controller.addError);

    // Ways the scan ends without us telling the platform to stop, because the
    // native scan is already dead: it reported a failure, the adapter turned
    // off, or the engine detached (hot restart). In each case skip stopScan.
    var nativeScanDead = false;
    void endScan({Object? error}) {
      if (controller.isClosed) return;
      nativeScanDead = true;
      if (error != null) controller.addError(error);
      controller.close();
    }

    final failures = extractEventStream<OnScanFailedEvent>().listen(
      (e) => endScan(error: BluebirdException("scan", BluebirdErrorCode.platform, "(${e.errorCode}) ${e.errorString}")),
    );
    final adapterOff = adapterState.changes
        .where((s) => s == BluetoothAdapterState.off || s == BluetoothAdapterState.turningOff)
        .listen((_) => endScan());
    final detached = extractEventStream<OnDetachedFromEngineEvent>().listen((_) => endScan());

    var started = false;
    try {
      await invoke("startScan", (p) => p.startScan(settings));
      started = true;
      yield* controller.stream;
    } finally {
      await advertisements.cancel();
      await failures.cancel();
      await adapterOff.cancel();
      await detached.cancel();
      if (!controller.isClosed) await controller.close();
      try {
        // release the guard only after the native scan has actually stopped, so
        // a new scan can't start before this one's stopScan lands
        if (started && !nativeScanDead) await invoke("stopScan", (p) => p.stopScan());
      } finally {
        _isScanning.add(false);
      }
    }
  }

  /// Sets the internal Bluebird log level
  static Future<void> setLogLevel(LogLevel level, {bool color = true}) async {
    _logLevel = level;
    await invoke("setLogLevel", (p) => p.setLogLevel(level, color: color));
  }

  /// Request Bluetooth PHY support
  static Future<PhySupport> getPhySupport() async {
    ensurePlatform(System.isAndroid, "getPhySupport");
    return await invoke("getPhySupport", (p) => p.getPhySupport());
  }

  static BluetoothDevice deviceForAddress(String address) {
    return _devices.putIfAbsent(address, () => BluetoothDevice(remoteId: address));
  }

  static void _initBluebird() {
    if (_initialized) return;
    _initialized = true;

    BluebirdPlatform.instance.events.listen(_onPlatformEvent);
  }

  static void _onPlatformEvent(BmEvent event) {
    switch (event) {
      case BmAdapterStateEvent():
        _adapterStateNow = event.adapterState;
        _eventStream.add(OnAdapterStateChangedEvent(event.adapterState));

      case BmScanAdvertisementEvent():
        _eventStream.add(OnScanAdvertisementEvent(ScanResult.fromProto(event.advertisement)));

      case BmScanFailedEvent():
        _eventStream.add(OnScanFailedEvent(event.errorCode, event.errorString));

      case BmConnectionStateEvent():
        final device = deviceForAddress(event.address);
        final disconnectReason = event.connectionState == BluetoothConnectionState.disconnected
            ? DisconnectReason(event.disconnectReasonCode, event.disconnectReasonString)
            : null;
        _dispatchDeviceEvent(device, OnConnectionStateChangedEvent(device, event.connectionState, disconnectReason));

      case BmCharacteristicNotificationEvent():
        final characteristic = deviceForAddress(event.address).characteristicForRefOrNull(event.characteristic);
        if (characteristic == null) {
          if (_logLevel.index >= LogLevel.warning.index) {
            BluebirdPlatform.log(
              "[Bluebird] received notification for unknown characteristic: ${event.characteristic.characteristic.uuid}",
            );
          }
          break;
        }
        _eventStream.add(OnCharacteristicNotifiedEvent(characteristic, event.value));

      case BmMtuChangedEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(device, OnMtuChangedEvent(device, event.mtu));

      case BmNameChangedEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(device, OnNameChangedEvent(device, event.name));

      case BmServicesResetEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(device, OnServicesResetEvent(device));

      case BmBondStateEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(
          device,
          OnBondStateChangedEvent(device, event.bondState, event.prevState ?? device.currentBondState),
        );

      case BmDetachedFromEngineEvent():
        _eventStream.add(OnDetachedFromEngineEvent());
    }
  }

  /// Applies a device event to its device (a synchronous state update) and then
  /// broadcasts it. The `Bm…Event` → `On…Event` translation happens in
  /// [_onPlatformEvent]; the device only reacts to the app-level event.
  static void _dispatchDeviceEvent(BluetoothDevice device, BluebirdDeviceEvent event) {
    device.applyEvent(event);
    _eventStream.add(event);
  }

  /// Broadcast an app-level event that does not originate from the platform
  /// event stream (e.g. a read result, which arrives via the method future).
  @internal
  static void emitEvent(BluebirdEvent event) => _eventStream.add(event);

  /// Runs one platform call with the standard guard pipeline, stating the
  /// operation [name] once. Device-scoped calls go through
  /// [BluetoothDevice.invoke], which adds the connection guards.
  @internal
  static Future<T> invoke<T>(
    String name,
    Future<T> Function(BluebirdPlatform p) call, {
    Duration? timeout,
    bool ensureAdapterIsOn = false,
  }) {
    // Only allow 1 invocation at a time (guarantees that hot restart finishes)
    var future = Mutex.platform.protect(() async {
      _initBluebird();
      try {
        return await call(BluebirdPlatform.instance);
      } on PlatformException catch (e) {
        throw BluebirdException(e.code, _errorCodes[e.code] ?? BluebirdErrorCode.platform, e.message, e.details);
      }
    });
    if (ensureAdapterIsOn) future = future.bluebirdEnsureAdapterIsOn(name);
    if (timeout != null) future = future.bluebirdTimeout(timeout, name);
    return future;
  }

  /// Wire-string -> [BluebirdErrorCode] lookup, built from the shared pigeon enum.
  static final _errorCodes = {for (final c in BluebirdErrorCode.values) c.wire: c};

  /// The stream of events of type [T], optionally filtered by [test].
  @internal
  static Stream<T> extractEventStream<T extends BluebirdEvent>([bool Function(T event)? test]) =>
      _eventStream.stream.where((e) => e is T).cast<T>().where(test ?? (_) => true);
}

enum AndroidScanMode {
  lowPower(0),
  balanced(1),
  lowLatency(2),
  opportunistic(-1);

  final int value;
  const AndroidScanMode(this.value);
}

class MsdFilter {
  final int manufacturerId;

  /// Filter for this data
  final List<int> data;

  /// Optional bitwise mask to define which bits in [data] must match.
  /// Must have the same length as [data].
  final List<int>? mask;

  MsdFilter(this.manufacturerId, {this.data = const [], this.mask = const []})
    : assert(mask == null || (data.length == mask.length), "mask & data must be same length");

  BmMsdFilter get bm => BmMsdFilter(
    manufacturerId: manufacturerId,
    data: data.isEmpty ? null : Uint8List.fromList(data),
    mask: mask == null || mask!.isEmpty ? null : Uint8List.fromList(mask!),
  );
}

class ServiceDataFilter {
  final Uuid service;

  /// Filter for this data
  final List<int> data;

  /// Optional bitwise mask to define which bits in [data] must match.
  /// Must have the same length as [data].
  final List<int>? mask;

  ServiceDataFilter(this.service, {this.data = const [], this.mask})
    : assert(mask == null || (data.length == mask.length), "mask & data must be same length");

  // convert to bmMsg
  BmServiceDataFilter get bm => BmServiceDataFilter(
    service: service.string,
    data: Uint8List.fromList(data),
    mask: mask == null ? null : Uint8List.fromList(mask!),
  );
}

class ScanResult {
  final String address;
  final String platformName;
  final AdvertisementData advertisementData;
  final int rssi;
  final DateTime timestamp;

  ScanResult({
    required this.address,
    required this.platformName,
    required this.advertisementData,
    required this.rssi,
    required this.timestamp,
  });

  ScanResult.fromProto(BmScanAdvertisement p)
    : address = p.address,
      platformName = p.platformName ?? "",
      advertisementData = AdvertisementData.fromProto(p),
      rssi = p.rssi,
      timestamp = DateTime.now();

  BluetoothDevice get device => Bluebird.deviceForAddress(address);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && runtimeType == other.runtimeType && address == other.address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() =>
      'ScanResult{'
      'address: $address, '
      'advertisementData: $advertisementData, '
      'rssi: $rssi, '
      'timestamp: $timestamp'
      '}';
}

/// Layers on top of a raw [Bluebird.scan] stream of individual advertisements.
extension ScanResultAccumulate on Stream<ScanResult> {
  /// Accumulates advertisements into a growing, de-duplicated device list,
  /// keyed by address (the latest advertisement per device wins).
  ///   - emits `[]` first, then the updated list on every advertisement.
  ///   - [removeIfGone]: if set, a device that has not re-advertised within this
  ///     duration is evicted from the list. This only makes sense when the
  ///     underlying scan uses `continuousUpdates: true` (otherwise duplicate
  ///     advertisements are suppressed and every device looks "gone").
  Stream<List<ScanResult>> accumulate({Duration? removeIfGone}) {
    final output = <String, ScanResult>{};
    StreamSubscription<ScanResult>? source;
    Timer? evictTimer;
    late final StreamController<List<ScanResult>> controller;
    controller = StreamController<List<ScanResult>>(
      onListen: () {
        controller.add(const []);
        source = listen(
          (sr) {
            output[sr.address] = sr;
            controller.add(output.values.toList());
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        if (removeIfGone != null) {
          evictTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
            final before = output.length;
            output.removeWhere((_, sr) => DateTime.now().difference(sr.timestamp) > removeIfGone);
            if (output.length != before) controller.add(output.values.toList());
          });
        }
      },
      onCancel: () async {
        evictTimer?.cancel();
        await source?.cancel();
      },
    );
    return controller.stream;
  }
}

class AdvertisementData {
  final String advName;
  final int? txPowerLevel;
  final int? appearance; // not supported on iOS / macOS
  final bool connectable;
  final Map<int, List<int>> manufacturerData; // key: manufacturerId
  final Map<Uuid, List<int>> serviceData; // key: service guid
  final List<Uuid> serviceUuids;

  AdvertisementData({
    required this.advName,
    required this.txPowerLevel,
    required this.appearance,
    required this.connectable,
    required this.manufacturerData,
    required this.serviceData,
    required this.serviceUuids,
  });

  AdvertisementData.fromProto(BmScanAdvertisement p)
    : advName = p.advName ?? "",
      txPowerLevel = p.txPowerLevel,
      appearance = p.appearance,
      connectable = p.connectable,
      manufacturerData = p.manufacturerData,
      serviceData = p.serviceData.map((uuid, data) => MapEntry(Uuid(uuid), data)),
      serviceUuids = p.serviceUuids.map(Uuid.new).toList();

  @override
  String toString() =>
      'AdvertisementData{'
      'advName: $advName, '
      'txPowerLevel: $txPowerLevel, '
      'appearance: $appearance, '
      'connectable: $connectable, '
      'manufacturerData: $manufacturerData, '
      'serviceData: $serviceData, '
      'serviceUuids: $serviceUuids'
      '}';
}

extension BluebirdErrorCodeWire on BluebirdErrorCode {
  /// The wire form of this code: snake_case of the enum name — the
  /// convention shared with the native implementations (see pigeons/messages.dart).
  String get wire => name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
}

class BluebirdException implements Exception {
  /// Which function failed?
  final String function;
  final BluebirdErrorCode code;

  /// note: depends on platform
  final String? description;

  /// The raw platform error detail, when available — e.g. the native error
  /// domain + code behind a [BluebirdErrorCode.cbError]/`gattError`. Useful for
  /// pinning down the exact cause (e.g. which ATT error a write hit).
  final Object? details;

  BluebirdException(this.function, this.code, [this.description, this.details]);

  @override
  String toString() =>
      'BluebirdException | $function | bluebird-code: $code | $description'
      '${details != null ? ' | details: $details' : ''}';
}
