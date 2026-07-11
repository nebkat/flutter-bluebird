// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_device.dart';
import 'bluetooth_events.dart';
import 'bluetooth_utils.dart';
import 'utils.dart';

class FlutterBluePlus {
  ///////////////////
  //  Internal
  //
  static bool _initialized = false;

  static final StreamController<dynamic> _eventStream = StreamController.broadcast();

  // always keep track of these device variables
  static final Map<String, BluetoothDevice> _devices = LinkedHashMap<String, BluetoothDevice>(
    equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
    hashCode: (a) => a.toLowerCase().hashCode,
  );
  static final List<StreamSubscription> _scanSubscriptions = [];

  /// stream used for the isScanning public api
  static final _isScanning = StreamControllerReEmit<bool>(initialValue: false);

  /// stream used for the scanResults public api
  static final _scanResults = StreamControllerReEmit<List<ScanResult>>(initialValue: []);

  /// timeout for scanning that can be cancelled by stopScan
  static Timer? _scanTimeout;

  /// the last known adapter state
  static BluetoothAdapterState? _adapterStateNow;

  /// FlutterBluePlus log level
  static LogLevel _logLevel = LogLevel.debug;

  ////////////////////
  //  Public
  //

  static LogLevel get logLevel => _logLevel;

  /// Checks whether the hardware supports Bluetooth
  static Future<bool> get isSupported async => await invoke((p) => p.isSupported());

  /// The current adapter state
  static BluetoothAdapterState get adapterStateNow => _adapterStateNow ?? BluetoothAdapterState.unknown;

  /// Return the friendly Bluetooth name of the local Bluetooth adapter
  static Future<String> get adapterName async => await invoke((p) => p.getAdapterName());

  /// returns whether we are scanning as a stream
  static Stream<bool> get isScanning => _isScanning.stream;

  /// are we scanning right now?
  static bool get isScanningNow => _isScanning.latestValue;

  /// the most recent scan results
  static List<ScanResult> get lastScanResults => _scanResults.latestValue;

  /// a stream of scan results
  /// - if you re-listen to the stream it re-emits the previous results
  /// - the list contains all the results since the scan started
  /// - the returned stream is never closed.
  static Stream<List<ScanResult>> get scanResults => _scanResults.stream;

  /// This is the same as scanResults, except:
  /// - it *does not* re-emit previous results after scanning stops.
  static Stream<List<ScanResult>> get onScanResults {
    if (isScanningNow) {
      return _scanResults.stream;
    } else {
      // skip previous results & push empty list
      return _scanResults.stream.skip(1).newStreamWithInitialValue([]);
    }
  }

  /// Get access to all device event streams
  static final BluetoothEvents events = BluetoothEvents();

  /// Set configurable options
  ///   - [showPowerAlert] Whether to show the power alert (iOS & MacOS only). i.e. CBCentralManagerOptionShowPowerAlertKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See: https://developer.apple.com/documentation/corebluetooth/cbcentralmanageroptionshowpoweralertkey
  ///       This option has no effect on Android.
  ///   - [restoreState] Whether to opt into state restoration (iOS & MacOS only). i.e. CBCentralManagerOptionRestoreIdentifierKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See Apple Documentation for more details. This option has no effect on Android.
  static Future<void> setOptions({
    bool showPowerAlert = true,
    bool restoreState = false,
  }) async {
    ensurePlatform(System.isDarwin, "setOptions");
    await invoke((p) => p.setOptions(showPowerAlert, restoreState));
  }

  /// Turn on Bluetooth (Android only),
  static Future<void> turnOn({Duration timeout = const Duration(seconds: 60)}) async {
    final userAccepted = await invoke((p) => p.turnOn());

    if (!userAccepted) {
      throw FlutterBluePlusException("turnOn", FbpErrorCode.userRejected, "user rejected");
    }

    // wait for adapter to turn on
    await adapterState.where((s) => s == BluetoothAdapterState.on).first.fbpTimeout(timeout, "turnOn");
  }

  /// Gets the current state of the Bluetooth module
  static Stream<BluetoothAdapterState> get adapterState async* {
    // get current state if needed
    if (_adapterStateNow == null) {
      final state = await invoke((p) => p.getAdapterState());
      // update _adapterStateNow if it is still null after the await
      // (an adapter state event may have arrived first — prefer it)
      _adapterStateNow ??= bmToAdapterState(state);
    }

    yield* FlutterBluePlus.extractEventStream<OnAdapterStateChangedEvent>()
        .map((s) => s.adapterState)
        .newStreamWithInitialValue(_adapterStateNow!);
  }

  /// Retrieve a list of devices currently connected to your app
  static List<BluetoothDevice> get connectedDevices => _devices.values.where((d) => d.isConnected).toList();

  /// Retrieve a list of devices currently connected to the system
  /// - The list includes devices connected to by *any* app
  /// - You must still call device.connect() to connect them to *your app*
  /// - [withServices] required on iOS (for privacy purposes). ignored on android.
  static Future<List<BluetoothDevice>> systemDevices(List<Uuid> withServices) async {
    final devices = await invoke((p) => p.getSystemDevices(withServices.map((s) => s.string).toList()));
    return devices.map(_deviceForBm).toList();
  }

  /// Retrieve a list of bonded devices (Android only)
  static Future<List<BluetoothDevice>> get bondedDevices async {
    ensurePlatform(System.isAndroid, "getBondedDevices");
    final devices = await invoke((p) => p.getBondedDevices());
    return devices.map(_deviceForBm).toList();
  }

  static BluetoothDevice _deviceForBm(BmBluetoothDevice d) {
    return deviceForAddress(d.address)..platformNameInternal = d.platformName;
  }

  /// Start a scan, and return a stream of results
  /// Note: scan filters use an "or" behavior. i.e. if you set `withServices` & `withNames` we
  /// return all the advertisements that match any of the specified services *or* any of the specified names.
  ///   - [withServices] filter by advertised services
  ///   - [withRemoteIds] filter for known remoteIds (iOS: 128-bit guid, android: 48-bit mac address)
  ///   - [withNames] filter by advertised names (exact match)
  ///   - [withKeywords] filter by advertised names (matches any substring)
  ///   - [withMsd] filter by manufacturer specific data
  ///   - [withServiceData] filter by service data
  ///   - [timeout] calls stopScan after a specified duration
  ///   - [removeIfGone] if true, remove devices after they've stopped advertising for X duration
  ///   - [continuousUpdates] If `true`, we continually update 'lastSeen' & 'rssi' by processing
  ///        duplicate advertisements. This takes more power. You typically should not use this option.
  ///   - [continuousDivisor] Useful to help performance. If divisor is 3, then two-thirds of advertisements are
  ///        ignored, and one-third are processed. This reduces main-thread usage caused by the platform channel.
  ///        The scan counting is per-device so you always get the 1st advertisement from each device.
  ///        If divisor is 1, all advertisements are returned. This argument only matters for `continuousUpdates` mode.
  ///   - [oneByOne] if `true`, we will stream every advertisement one by one, possibly including duplicates.
  ///        If `false`, we deduplicate the advertisements, and return a list of devices.
  ///   - [androidLegacy] Android only. If `true`, scan on 1M phy only.
  ///        If `false`, scan on all supported phys. How the radio cycles through all the supported phys is purely
  ///        dependent on the your Bluetooth stack implementation.
  ///   - [androidScanMode] choose the android scan mode to use when scanning
  ///   - [androidUsesFineLocation] request `ACCESS_FINE_LOCATION` permission at runtime
  static Future<void> startScan({
    List<Uuid> withServices = const [],
    List<String> withRemoteIds = const [],
    List<String> withNames = const [],
    List<String> withKeywords = const [],
    List<MsdFilter> withMsd = const [],
    List<ServiceDataFilter> withServiceData = const [],
    Duration? timeout,
    Duration? removeIfGone,
    bool continuousUpdates = false,
    int continuousDivisor = 1,
    bool oneByOne = false,
    bool androidLegacy = false,
    AndroidScanMode androidScanMode = AndroidScanMode.lowLatency,
    bool androidUsesFineLocation = false,
    List<Uuid> webOptionalServices = const [],
  }) async {
    // check args
    assert(removeIfGone == null || continuousUpdates, "removeIfGone requires continuousUpdates");
    assert(removeIfGone == null || !oneByOne, "removeIfGone is not compatible with oneByOne");
    assert(continuousDivisor >= 1, "divisor must be >= 1");

    // check filters
    final hasOtherFilter = withServices.isNotEmpty ||
        withRemoteIds.isNotEmpty ||
        withNames.isNotEmpty ||
        withMsd.isNotEmpty ||
        withServiceData.isNotEmpty;

    // Note: `withKeywords` is not compatible with other filters on android
    // because it is implemented in custom fbp code, not android code, and the
    // android 'name' filter is only available as of android sdk 33 (August 2022)
    if (System.isAndroid) {
      assert(withKeywords.isEmpty || !hasOtherFilter, "withKeywords is not compatible with other filters on Android");
    }

    // only allow a single task to call
    // startScan or stopScan at a time
    await Mutex.scan.protect(() async {
      // already scanning?
      if (_isScanning.latestValue == true) {
        // stop existing scan
        await _stopScan();
      }

      // push to stream
      _isScanning.add(true);

      var settings = BmScanSettings(
        withServices: withServices.map((s) => s.string).toList(),
        withRemoteIds: withRemoteIds,
        withNames: withNames,
        withKeywords: withKeywords,
        withMsd: withMsd.map((d) => d._bm).toList(),
        withServiceData: withServiceData.map((d) => d._bm).toList(),
        continuousUpdates: continuousUpdates,
        continuousDivisor: continuousDivisor,
        androidLegacy: androidLegacy,
        androidScanMode: androidScanMode.value,
        androidUsesFineLocation: androidUsesFineLocation,
        webOptionalServices: webOptionalServices.map((s) => s.string).toList(),
      );

      Stream<OnScanResponseEvent> responseStream = FlutterBluePlus.extractEventStream<OnScanResponseEvent>();

      // Start listening now, before invokeMethod, so we do not miss any results
      final scanBuffer = responseStream.listenAndBuffer();

      // invoke platform method
      try {
        await invoke((p) => p.startScan(settings));
      } catch (e) {
        scanBuffer.listen(null).cancel();
        _stopScan(invokePlatform: false);
        rethrow;
      }

      // start by pushing an empty array
      _scanResults.add([]);

      Map<String, ScanResult> output = {};

      // listen & push to `scanResults` stream
      _scanSubscriptions.add(scanBuffer.listen((OnScanResponseEvent response) {
        // iterate through advertisements
        for (ScanResult sr in response.advertisements) {
          if (oneByOne) {
            // push single item
            _scanResults.add([sr]);
          } else {
            output[sr.address] = sr;
          }
        }

        // push entire list
        if (!oneByOne) {
          _scanResults.add(List.from(output.values));
        }
      }));

      if (removeIfGone != null) {
        _scanSubscriptions.add(Stream.periodic(Duration(milliseconds: 250)).listen((_) {
          final countBefore = output.length;
          output.removeWhere((adr, sr) => DateTime.now().difference(sr.timestamp) > removeIfGone);
          if (output.length == countBefore) return;
          _scanResults.add(List.from(output.values)); // push to stream
        }));
      }

      // Start timer *after* stream is being listened to, to make sure the
      // timeout does not fire before _scanSubscription is set
      if (timeout != null) {
        _scanTimeout = Timer(timeout, stopScan);
      }
    });
  }

  /// Stops a scan for Bluetooth Low Energy devices
  static Future<void> stopScan() async {
    await Mutex.scan.protect(() async {
      if (isScanningNow) {
        await _stopScan();
      } else if (_logLevel.index >= LogLevel.info.index) {
        FlutterBluePlusPlatform.log("[FBP] stopScan: already stopped");
      }
    });
  }

  /// for internal use
  static Future<void> _stopScan({bool invokePlatform = true}) async {
    for (var subscription in _scanSubscriptions) {
      subscription.cancel();
    }
    _scanSubscriptions.clear();
    _scanTimeout?.cancel();
    _isScanning.add(false);
    if (invokePlatform) await invoke((p) => p.stopScan());
  }

  /// Register a subscription to be canceled when scanning is complete.
  /// This function simplifies cleanup, so you can prevent creating duplicate stream subscriptions.
  ///   - this is an optional convenience function
  ///   - prevents accidentally creating duplicate subscriptions before each scan
  static void cancelWhenScanComplete(StreamSubscription subscription) {
    FlutterBluePlus._scanSubscriptions.add(subscription);
  }

  /// Sets the internal FlutterBlue log level
  static Future<void> setLogLevel(LogLevel level, {bool color = true}) async {
    _logLevel = level;
    await invoke((p) => p.setLogLevel(level, color: color));
  }

  /// Request Bluetooth PHY support
  static Future<BmPhySupport> getPhySupport() async {
    ensurePlatform(System.isAndroid, "getPhySupport");
    return await invoke((p) => p.getPhySupport());
  }

  static BluetoothDevice deviceForAddress(String address) {
    return _devices.putIfAbsent(address, () => BluetoothDevice(remoteId: address));
  }

  static void _initFlutterBluePlus() {
    if (_initialized) return;
    _initialized = true;

    FlutterBluePlusPlatform.instance.events.listen(_onPlatformEvent);
  }

  static void _onPlatformEvent(BmEvent event) {
    switch (event) {
      case BmAdapterStateEvent():
        final adapterState = bmToAdapterState(event.adapterState);
        _adapterStateNow = adapterState;
        if (isScanningNow && adapterState != BluetoothAdapterState.on) {
          _stopScan(invokePlatform: false);
        }
        _eventStream.add(OnAdapterStateChangedEvent(adapterState));

      case BmScanAdvertisementsEvent():
        _eventStream.add(OnScanResponseEvent(event.advertisements.map(ScanResult.fromProto).toList()));

      case BmScanFailedEvent():
        _scanResults.addError(
          FlutterBluePlusException("scan", FbpErrorCode.platform, "(${event.errorCode}) ${event.errorString}"),
        );
        _stopScan(invokePlatform: false);

      case BmConnectionStateEvent():
        _eventStream.add(deviceForAddress(event.address).handleConnectionStateEvent(event));

      case BmCharacteristicNotificationEvent():
        final appEvent = deviceForAddress(event.address).handleCharacteristicNotification(event);
        if (appEvent != null) {
          _eventStream.add(appEvent);
        } else if (_logLevel.index >= LogLevel.warning.index) {
          FlutterBluePlusPlatform.log(
              "[FBP] received notification for unknown characteristic: ${event.characteristic.characteristic.uuid}");
        }

      case BmMtuChangedEvent():
        _eventStream.add(deviceForAddress(event.address).handleMtuChangedEvent(event));

      case BmNameChangedEvent():
        _eventStream.add(deviceForAddress(event.address).handleNameChangedEvent(event));

      case BmServicesResetEvent():
        _eventStream.add(deviceForAddress(event.address).handleServicesResetEvent(event));

      case BmBondStateEvent():
        _eventStream.add(deviceForAddress(event.address).handleBondStateEvent(event));

      case BmDetachedFromEngineEvent():
        _stopScan(invokePlatform: false);
        _eventStream.add(OnDetachedFromEngineEvent());
    }
  }

  /// Broadcast an app-level event (e.g. a read result, which arrives via the
  /// method future rather than the platform event stream).
  @internal
  static void emitEvent(dynamic event) {
    _eventStream.add(event);
  }

  @internal
  static Future<T> invoke<T>(Future<T> Function(FlutterBluePlusPlatform p) invoke) async {
    // Only allow 1 invocation at a time (guarantees that hot restart finishes)
    return await Mutex.platform.protect(() async {
      // Initialize
      _initFlutterBluePlus();

      // Invoke
      try {
        return await invoke(FlutterBluePlusPlatform.instance);
      } on PlatformException catch (e) {
        throw FlutterBluePlusException(e.code, _fbpCodeForPlatformError(e.code), e.message);
      }
    });
  }

  static FbpErrorCode _fbpCodeForPlatformError(String code) => switch (code) {
        "device_disconnected" => FbpErrorCode.deviceIsDisconnected,
        "adapter_off" => FbpErrorCode.adapterIsOff,
        "user_canceled" => FbpErrorCode.connectionCanceled,
        "bond_failed" => FbpErrorCode.createBondFailed,
        _ => FbpErrorCode.platform,
      };

  /// Extract stream event
  @internal
  static Stream<T> extractEventStream<T>([bool Function(T event)? test]) =>
      _eventStream.stream.where((m) => m is T).map((m) => m as T).where(test ?? (_) => true);
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

  /// filter for this data
  final List<int> data;

  /// For any bit in the mask, set it the 1 if it needs to match
  /// the one in manufacturer data, otherwise set it to 0.
  /// The 'mask' must have the same length as 'data'.
  final List<int>? mask;

  MsdFilter(this.manufacturerId, {this.data = const [], this.mask = const []})
      : assert(mask == null || (data.length == mask.length), "mask & data must be same length");

  // convert to bmMsg
  BmMsdFilter get _bm => BmMsdFilter(
        manufacturerId: manufacturerId,
        data: data.isEmpty ? null : Uint8List.fromList(data),
        mask: mask == null || mask!.isEmpty ? null : Uint8List.fromList(mask!),
      );
}

class ServiceDataFilter {
  final Uuid service;

  /// filter for this data
  final List<int> data;

  /// For any bit in the mask, set it the 1 if it needs to match
  /// the one in service data, otherwise set it to 0.
  /// The 'mask' must have the same length as 'data'.
  final List<int>? mask;

  ServiceDataFilter(this.service, {this.data = const [], this.mask})
      : assert(mask == null || (data.length == mask.length), "mask & data must be same length");

  // convert to bmMsg
  BmServiceDataFilter get _bm => BmServiceDataFilter(
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

  BluetoothDevice get device => FlutterBluePlus.deviceForAddress(address);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && runtimeType == other.runtimeType && address == other.address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() {
    return 'ScanResult{'
        'address: $address, '
        'advertisementData: $advertisementData, '
        'rssi: $rssi, '
        'timestamp: $timestamp'
        '}';
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

  /// for convenience, raw msd data
  ///   * interprets the first two byte as raw data,
  ///     as opposed to a `manufacturerId`
  List<List<int>> get msd => manufacturerData.entries.map((entry) {
        int manufacturerId = entry.key;
        List<int> bytes = entry.value;
        int low = manufacturerId & 0xFF;
        int high = (manufacturerId >> 8) & 0xFF;
        return [low, high] + bytes;
      }).toList();

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
  String toString() {
    return 'AdvertisementData{'
        'advName: $advName, '
        'txPowerLevel: $txPowerLevel, '
        'appearance: $appearance, '
        'connectable: $connectable, '
        'manufacturerData: $manufacturerData, '
        'serviceData: $serviceData, '
        'serviceUuids: $serviceUuids'
        '}';
  }
}

enum FbpErrorCode {
  success,
  timeout,
  platform,
  createBondFailed,
  removeBondFailed,
  deviceIsDisconnected,
  serviceNotFound,
  characteristicNotFound,
  adapterIsOff,
  connectionCanceled,
  userRejected
}

class FlutterBluePlusException implements Exception {
  /// Which function failed?
  final String function;
  final FbpErrorCode code;

  /// note: depends on platform
  final String? description;

  FlutterBluePlusException(this.function, this.code, [this.description]);

  @override
  String toString() => 'FlutterBluePlusException | $function | fbp-code: $code | $description';
}
