// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_descriptor.dart';
import 'bluetooth_events.dart';
import 'bluetooth_service.dart';
import 'bluetooth_utils.dart';
import 'flutter_blue_plus.dart';
import 'utils.dart';

const int _mtuMax = 517;

class BluetoothDevice {
  final String remoteId;

  List<BluetoothService> _services = [];

  int? _mtu;
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  DisconnectReason? _disconnectReason;
  DateTime? _connectTimestamp;
  BluetoothBondState? _bondState;
  BluetoothBondState? _prevBondState;

  String? _platformName;

  final List<StreamSubscription> _subscriptions = [];
  final List<StreamSubscription> _delayedSubscriptions = [];

  @internal
  BluetoothDevice({required this.remoteId});

  /// Create a device from an id
  ///   - to connect, this device must have been discovered by your app in a previous scan
  ///   - iOS uses 128-bit uuids the remoteId, e.g. e006b3a7-ef7b-4980-a668-1f8005f84383
  ///   - Android uses 48-bit mac addresses as the remoteId, e.g. 06:E5:28:3B:FD:E0
  factory BluetoothDevice.fromId(String address) => FlutterBluePlus.deviceForAddress(address);

  /// platform name
  /// - this name is kept track of by the platform
  /// - this name usually persist between app restarts
  /// - iOS: after you connect, iOS uses the GAP name characteristic (0x2A00)
  ///        if it exists. Otherwise iOS use the advertised name.
  /// - Android: always uses the advertised name
  String get platformName => _platformName ?? "";

  @internal
  set platformNameInternal(String? name) {
    _platformName = name ?? _platformName;
  }

  /// Get services
  ///  - returns empty if discoverServices() has not been called
  ///    or if your device does not have any services (rare)
  List<BluetoothService> get services => _services;

  void ensureConnected(String functionName) {
    if (isConnected) return;
    throw FlutterBluePlusException(
      functionName,
      FbpErrorCode.deviceIsDisconnected,
      "device is not connected",
    );
  }

  /// Register a subscription to be canceled when the device is disconnected.
  /// This function simplifies cleanup, so you can prevent creating duplicate stream subscriptions.
  ///   - this is an optional convenience function
  ///   - prevents accidentally creating duplicate subscriptions on each reconnection.
  ///   - [next] if true, the the stream will be canceled only on the *next* disconnection.
  ///     This is useful if you setup your subscriptions before you connect.
  ///   - [delayed] Note: This option is only meant for `connectionState` subscriptions.
  ///     When `true`, we cancel after a small delay. This ensures the `connectionState`
  ///     listener receives the `disconnected` event.
  void cancelWhenDisconnected(StreamSubscription subscription, {bool next = false, bool delayed = false}) {
    if (isConnected == false && next == false) {
      subscription.cancel(); // cancel immediately if already disconnected.
    } else if (delayed) {
      _delayedSubscriptions.add(subscription);
    } else {
      _subscriptions.add(subscription);
    }
  }

  /// Returns true if this device is currently connected to your app
  bool get isConnected => _connectionState == BluetoothConnectionState.connected;

  /// Returns true if this device is currently disconnected from your app
  bool get isDisconnected => !isConnected;

  /// Establishes a connection to the Bluetooth Device.
  ///   [timeout] if timeout occurs, cancel the connection request and throw exception
  ///   [mtu] Android only. Request a larger mtu right after connection, if set.
  Future<void> connect({
    Duration timeout = const Duration(seconds: 35),
    int? mtu = _mtuMax,
  }) async {
    // make sure no one else is calling disconnect
    await Mutex.disconnect.take();
    bool disconnectReturned = false;

    await Mutex.global.protect(() async {
      // record connection time
      if (System.isAndroid) _connectTimestamp = DateTime.now();

      try {
        final future = FlutterBluePlus.invoke((p) => p.connect(remoteId))
            .fbpEnsureAdapterIsOn("connect")
            .fbpTimeout(timeout, "connect");

        // we return the disconnect mutex now so that this
        // connection attempt can be canceled by calling disconnect
        Mutex.disconnect.give();
        disconnectReturned = true;

        await future;
      } on FlutterBluePlusException catch (e) {
        if (e.code == FbpErrorCode.timeout) {
          await FlutterBluePlus.invoke((p) => p.disconnect(remoteId));
        }
        rethrow;
      }
    });

    if (!disconnectReturned) Mutex.disconnect.give();

    // request larger mtu
    if (System.isAndroid && isConnected && mtu != null) {
      await requestMtu(mtu);
    }
  }

  /// Cancels connection to the Bluetooth Device
  ///   - [queue] If true, this disconnect request will be executed after all other operations complete.
  ///     If false, this disconnect request will be executed right now, i.e. skipping to the front
  ///     of the fbp operation queue, which is useful to cancel an in-progress connection attempt.
  ///   - [androidDelay] Android only. Minimum gap between connect and disconnect to
  ///     workaround a race condition that leaves connection stranded. A stranded connection in this case
  ///     refers to a connection that FBP and Android Bluetooth stack are not aware of and thus cannot be
  ///     disconnected because there is no gatt handle.
  ///     https://issuetracker.google.com/issues/37121040
  ///     From testing, 2 second delay appears to be enough.
  Future<void> disconnect({
    Duration timeout = const Duration(seconds: 35),
    bool queue = true,
    Duration androidDelay = const Duration(seconds: 2),
  }) async {
    // Only allow a single disconnect operation at a time
    await Mutex.disconnect.protect(() {
      Future<void> action() async {
        // Workaround Android race condition
        await _ensureAndroidDisconnectionDelay(androidDelay);

        // invoke
        await FlutterBluePlus.invoke((p) => p.disconnect(remoteId))
            .fbpEnsureAdapterIsOn("disconnect")
            .fbpTimeout(timeout, "disconnect");

        if (System.isAndroid) {
          // Disconnected, remove connect timestamp
          _connectTimestamp = null;
        }
      }

      return queue ? Mutex.global.protect(action) : action();
    });
  }

  /// Discover services, characteristics, and descriptors of the remote device
  ///   - [subscribeToServicesChanged] Android Only: If true, after discovering services we will subscribe
  ///     to the Services Changed Characteristic (0x2A05) used for the `device.onServicesReset` stream.
  ///     Note: this behavior happens automatically on iOS and cannot be disabled
  Future<List<BluetoothService>> discoverServices({
    bool subscribeToServicesChanged = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    ensureConnected('discoverServices');

    await Mutex.global.protect(() async {
      final services = await FlutterBluePlus.invoke((p) => p.discoverServices(remoteId))
          .fbpEnsureAdapterIsOn("discoverServices")
          .fbpEnsureDeviceIsConnected(this, "discoverServices")
          .fbpTimeout(timeout, "discoverServices");

      _services = BluetoothService.constructServices(this, services);
    });

    // in order to match iOS behavior on all platforms,
    // we always listen to the Services Changed characteristic if it exists.
    if (subscribeToServicesChanged) {
      if (!System.isDarwin) {
        BluetoothCharacteristic? c = _servicesChangedCharacteristic;
        if (c != null && (c.properties.notify || c.properties.indicate)) {
          await c.setNotifyValue(true); // TODO: Use notifications
        }
      }
    }

    return _services;
  }

  /// The most recent disconnection reason
  DisconnectReason? get disconnectReason => _disconnectReason;

  /// The current connection state *of our app* to the device
  Stream<BluetoothConnectionState> get connectionState =>
      FlutterBluePlus.extractEventStream<OnConnectionStateChangedEvent>((m) => m.device == this)
          .map((e) => e.connectionState)
          .newStreamWithInitialValue(_connectionState);

  /// The current MTU size in bytes
  int get mtuNow => _mtu ?? 23;

  /// Stream emits a value:
  ///   - immediately when first listened to
  ///   - whenever the mtu changes
  Stream<int> get mtu => FlutterBluePlus.extractEventStream<OnMtuChangedEvent>((e) => e.device == this)
      .map((e) => e.mtu)
      .newStreamWithInitialValue(mtuNow);

  int get maxAttrLenNow => min(512, mtuNow - 3);
  Stream<int> get maxAttrLen => mtu.map((m) => min(512, m - 3));

  /// Services Reset Stream
  ///  - uses the GAP Services Changed characteristic (0x2A05)
  ///  - you must re-call discoverServices() when services are reset
  Stream<void> get onServicesReset =>
      FlutterBluePlus.extractEventStream<OnServicesResetEvent>((e) => e.device == this).map((m) {});

  /// Read the RSSI of connected remote device
  Future<int> readRssi({Duration timeout = const Duration(seconds: 15)}) async {
    ensureConnected('readRssi');

    // Only allow a single ble operation to be underway at a time
    return Mutex.global.protect(() async {
      return await FlutterBluePlus.invoke((p) => p.readRssi(remoteId))
          .fbpEnsureAdapterIsOn("readRssi")
          .fbpEnsureDeviceIsConnected(this, "readRssi")
          .fbpTimeout(timeout, "readRssi");
    });
  }

  /// Request to change MTU (Android Only)
  ///  - returns new MTU
  ///  - [predelay] adds delay to avoid race conditions on some peripherals. see comments below.
  Future<int> requestMtu(
    int desiredMtu, {
    Duration predelay = const Duration(milliseconds: 350),
    Duration timeout = const Duration(seconds: 15),
  }) async {
    ensurePlatform(System.isAndroid, "requestMtu");
    ensureConnected("requestMtu");

    // Only allow a single ble operation to be underway at a time
    return Mutex.global.protect(() async {
      // predelay
      if (predelay.inMilliseconds > 0) {
        // hack: By adding delay before we call `requestMtu`, we can avoid
        // a race condition that can cause `discoverServices` to timeout or fail.
        //
        // Note: This hack is only needed for peripherals that automatically send an
        // MTU update right after connection. If your peripherals does not do that,
        // you can set this delay to zero. Other people may need to increase it.
        //
        // The race condition goes like this:
        //  1. you call `requestMtu` right after connection
        //  2. some peripherals automatically send a new MTU right after connection, without being asked
        //  3. your call to `requestMtu` confuses the results from step 1 and step 2, and returns to early
        //  4. the user then calls `discoverServices`, thinking that `requestMtu` has finished
        //  5. in reality, `requestMtu` is still happening, and the call to `discoverServices` will fail/timeout
        //
        // Adding delay before we call `requestMtu` helps ensure
        // that the automatic mtu update has already happened.
        await Future.delayed(predelay);
      }

      return await FlutterBluePlus.invoke((p) => p.requestMtu(remoteId, desiredMtu))
          .fbpEnsureAdapterIsOn("requestMtu")
          .fbpEnsureDeviceIsConnected(this, "requestMtu")
          .fbpTimeout(timeout, "requestMtu");
    });
  }

  /// Request connection priority update (Android only)
  Future<void> requestConnectionPriority({
    required ConnectionPriority connectionPriorityRequest,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    ensurePlatform(System.isAndroid, "requestConnectionPriority");
    ensureConnected("requestConnectionPriority");

    await FlutterBluePlus.invoke(
            (p) => p.requestConnectionPriority(remoteId, connectionPriorityRequest))
        .fbpEnsureAdapterIsOn("requestConnectionPriority")
        .fbpEnsureDeviceIsConnected(this, "requestConnectionPriority")
        .fbpTimeout(timeout, "requestConnectionPriority");
  }

  /// Set the preferred connection (Android Only)
  ///   - [txPhy] bitwise OR of all allowed phys for Tx, e.g. (Phy.le2m.mask | Phy.leCoded.mask)
  ///   - [txPhy] bitwise OR of all allowed phys for Rx, e.g. (Phy.le2m.mask | Phy.leCoded.mask)
  ///   - [option] preferred coding to use when transmitting on Phy.leCoded
  /// Please note that this is just a recommendation given to the system.
  Future<void> setPreferredPhy({
    required int txPhy,
    required int rxPhy,
    required PhyCoding option,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    ensurePlatform(System.isAndroid, "setPreferredPhy");
    ensureConnected("setPreferredPhy");

    await FlutterBluePlus.invoke((p) => p.setPreferredPhy(remoteId, txPhy, rxPhy, option.index))
        .fbpEnsureAdapterIsOn("setPreferredPhy")
        .fbpEnsureDeviceIsConnected(this, "setPreferredPhy")
        .fbpTimeout(timeout, "setPreferredPhy");
  }

  /// Force the bonding popup to show now (Android Only)
  /// Note! calling this is usually not necessary!! The platform does it automatically.
  Future<void> createBond({
    Uint8List? pin,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    ensurePlatform(System.isAndroid, "createBond");
    ensureConnected("createBond");

    // Only allow a single ble operation to be underway at a time
    await Mutex.global.protect(() async {
      final bonded = await FlutterBluePlus.invoke((p) => p.createBond(remoteId, pin))
          .fbpEnsureAdapterIsOn("createBond")
          .fbpEnsureDeviceIsConnected(this, "createBond")
          .fbpTimeout(timeout, "createBond");

      if (!bonded) {
        throw FlutterBluePlusException(
          "createBond",
          FbpErrorCode.createBondFailed,
          "Failed to create bond",
        );
      }
    });
  }

  /// Remove bond (Android Only)
  Future<void> removeBond({Duration timeout = const Duration(seconds: 30)}) async {
    ensurePlatform(System.isAndroid, "removeBond");

    // Only allow a single ble operation to be underway at a time
    await Mutex.global.protect(() async {
      final removed = await FlutterBluePlus.invoke((p) => p.removeBond(remoteId))
          .fbpEnsureAdapterIsOn("removeBond")
          .fbpTimeout(timeout, "removeBond");

      if (!removed) {
        throw FlutterBluePlusException(
          "removeBond",
          FbpErrorCode.removeBondFailed,
          "Failed to remove bond",
        );
      }
    });
  }

  /// Refresh ble services & characteristics (Android Only)
  Future<void> clearGattCache() async {
    ensurePlatform(System.isAndroid, "clearGattCache");
    ensureConnected("clearGattCache");
    await FlutterBluePlus.invoke((p) => p.clearGattCache(remoteId))
        .fbpEnsureAdapterIsOn("clearGattCache")
        .fbpEnsureDeviceIsConnected(this, "clearGattCache");
  }

  Future<BluetoothBondState> get bondStateNow async {
    ensurePlatform(System.isAndroid, "bondState");

    // get current state if needed
    _bondState ??= await FlutterBluePlus.invoke((p) => p.getBondState(remoteId))
        .fbpEnsureAdapterIsOn('getBondState');

    return _bondState!;
  }

  /// Get the current bondState of the device (Android Only)
  Stream<BluetoothBondState> get bondState async* {
    ensurePlatform(System.isAndroid, "bondState");

    yield* FlutterBluePlus.extractEventStream<OnBondStateChangedEvent>((m) => m.device == this)
        .map((e) => e.bondState)
        .newStreamWithInitialValue(await bondStateNow);
  }

  /// Get the previous bondState of the device (Android Only)
  BluetoothBondState? get prevBondState => _prevBondState;

  /// Get the GATT service (0x1801)
  BluetoothService? get _gattService => _services.where((s) => s.uuid == Uuids.gattService).firstOrNull;

  /// Get the Services Changed characteristic (0x2A05)
  BluetoothCharacteristic? get _servicesChangedCharacteristic =>
      _gattService?.characteristics.where((chr) => chr.uuid == Uuids.servicesChangedCharacteristic).firstOrNull;

  /// Workaround race condition between connect and disconnect.
  /// The bug: If you call disconnect right as android is establishing a connection
  /// android may still connect to the device. Worse, "onConnectionStateChange" will not be called
  /// so FBP will have no idea this connection is active. Adding a delay fixes this issue.
  /// https://issuetracker.google.com/issues/37121040
  Future<void> _ensureAndroidDisconnectionDelay(Duration minGap) async {
    if (!System.isAndroid) return;
    if (_connectTimestamp == null) return;
    Duration elapsed = DateTime.now().difference(_connectTimestamp!);
    if (elapsed.compareTo(minGap) < 0) {
      Duration timeLeft = minGap - elapsed;
      FlutterBluePlusPlatform.log(
        "[FBP] disconnect: enforcing ${minGap.inMilliseconds}ms disconnect gap,"
        " delaying ${timeLeft.inMilliseconds}ms",
      );
      await Future<void>.delayed(timeLeft);
    }
  }

  //
  // Platform event routing — called by FlutterBluePlus. Each handler updates
  // this device's private state and returns the app-level event to broadcast.
  //

  @internal
  OnConnectionStateChangedEvent handleConnectionStateEvent(BmConnectionStateEvent event) {
    final connectionState = event.connectionState;
    _connectionState = connectionState;

    if (connectionState == BluetoothConnectionState.disconnected) {
      _disconnectReason = DisconnectReason(event.disconnectReasonCode, event.disconnectReasonString);

      // clear mtu
      _mtu = null;

      // cancel & delete subscriptions
      for (final s in _subscriptions) {
        s.cancel();
      }
      _subscriptions.clear();

      // cancel delayed subscriptions after the disconnected event has been
      // delivered to their streams
      if (_delayedSubscriptions.isNotEmpty) {
        final delayed = List.of(_delayedSubscriptions);
        _delayedSubscriptions.clear();
        Future.delayed(Duration.zero).then((_) {
          for (final s in delayed) {
            s.cancel();
          }
        });
      }

      // Note: to make FBP easier to use, we do not clear `_services`,
      // otherwise `services` would be more annoying to use. We also
      // do not clear `_bondState`, for faster performance.
    }

    return OnConnectionStateChangedEvent(
      this,
      connectionState,
      connectionState == BluetoothConnectionState.disconnected ? _disconnectReason : null,
    );
  }

  @internal
  OnMtuChangedEvent handleMtuChangedEvent(BmMtuChangedEvent event) {
    _mtu = event.mtu;
    return OnMtuChangedEvent(this, event.mtu);
  }

  @internal
  OnNameChangedEvent handleNameChangedEvent(BmNameChangedEvent event) {
    if (System.isDarwin) {
      // iOS & macOS internally use the name changed callback for the platform name
      _platformName = event.name;
    }
    return OnNameChangedEvent(this, event.name);
  }

  @internal
  OnServicesResetEvent handleServicesResetEvent(BmServicesResetEvent event) {
    _services = [];
    return OnServicesResetEvent(this);
  }

  @internal
  OnBondStateChangedEvent handleBondStateEvent(BmBondStateEvent event) {
    _prevBondState = event.prevState ?? _bondState;
    _bondState = event.bondState;
    return OnBondStateChangedEvent(this, _bondState!, _prevBondState);
  }

  /// Returns null if the characteristic cannot be resolved
  /// (e.g. services not discovered).
  @internal
  OnCharacteristicReceivedEvent? handleCharacteristicNotification(BmCharacteristicNotificationEvent event) {
    final characteristic = _characteristicForRefOrNull(event.characteristic);
    if (characteristic == null) return null;
    characteristic.handleReceivedValue(event.value);
    return OnCharacteristicReceivedEvent(characteristic, event.value);
  }

  //
  // Attribute lookup by typed ref
  //

  T? _attributeForId<T extends BluetoothAttribute>(List<T> list, BmAttributeId id) =>
      list.where((a) => a.id == BluetoothAttributeId.fromBm(id)).firstOrNull;

  BluetoothCharacteristic? _characteristicForRefOrNull(BmCharacteristicRef ref) {
    final service = _attributeForId(_services, ref.service.service);
    if (service == null) return null;
    return _attributeForId(service.characteristics, ref.characteristic);
  }

  @internal
  BluetoothCharacteristic characteristicForRef(BmCharacteristicRef ref) {
    final characteristic = _characteristicForRefOrNull(ref);
    if (characteristic == null) {
      throw FlutterBluePlusException(
        "characteristicForRef",
        FbpErrorCode.characteristicNotFound,
        "characteristic not found: ${ref.service.service.uuid}/${ref.characteristic.uuid}",
      );
    }
    return characteristic;
  }

  @internal
  BluetoothDescriptor descriptorForRef(BmDescriptorRef ref) {
    final characteristic = characteristicForRef(ref.characteristic);
    final uuid = Uuid(ref.uuid);
    final descriptor = characteristic.descriptors.where((d) => d.uuid == uuid).firstOrNull;
    if (descriptor == null) {
      throw FlutterBluePlusException(
        "descriptorForRef",
        FbpErrorCode.characteristicNotFound,
        "descriptor not found: ${ref.uuid}",
      );
    }
    return descriptor;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BluetoothDevice && runtimeType == other.runtimeType && remoteId == other.remoteId);

  @override
  int get hashCode => remoteId.hashCode;

  @override
  String toString() {
    return '${(BluetoothDevice)}{'
        'remoteId: $remoteId, '
        'platformName: $platformName, '
        'services: $_services'
        '}';
  }
}
