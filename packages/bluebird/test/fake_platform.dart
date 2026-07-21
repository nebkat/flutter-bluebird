import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

/// A controllable [BluebirdPlatform] for unit tests: drive [emit] to push
/// platform events, and stub method results/errors as needed.
final class FakePlatform extends BluebirdPlatform {
  final _events = StreamController<BmEvent>.broadcast();

  BluetoothAdapterState adapterState = BluetoothAdapterState.on;
  bool supported = true;
  List<BmBluetoothService> services = const [];

  /// Records every method name invoked, for assertions.
  final calls = <String>[];

  /// Captures the last write's arguments, for assertions.
  BmWriteType? lastWriteType;
  Uint8List? lastWriteValue;
  BmCharacteristicRef? lastCharRef;

  /// Optional per-method override: return a value or throw.
  final Map<String, Object? Function()> stubs = {};

  @override
  Stream<BmEvent> get events => _events.stream;

  void emit(BmEvent event) => _events.add(event);

  Future<T> _run<T>(String name, T fallback) async {
    calls.add(name);
    final stub = stubs[name];
    if (stub != null) {
      // a stub may return the value directly or a Future of it (e.g. to keep a
      // call in-flight until the test completes it)
      final result = stub();
      return result is Future ? await result as T : result as T;
    }
    return fallback;
  }

  @override
  Future<bool> isSupported() => _run('isSupported', supported);

  @override
  Future<BluetoothAdapterState> getAdapterState() => _run('getAdapterState', adapterState);

  @override
  Future<void> startScan(BmScanSettings settings) => _run('startScan', null);

  @override
  Future<void> stopScan() => _run('stopScan', null);

  @override
  Future<void> connect(String address) => _run('connect', null);

  @override
  Future<void> disconnect(String address) => _run('disconnect', null);

  @override
  Future<List<BmBluetoothService>> discoverServices(String address) => _run('discoverServices', services);

  @override
  Future<Uint8List> readCharacteristic(String address, BmCharacteristicRef c) {
    lastCharRef = c;
    return _run('readCharacteristic', Uint8List.fromList([0xab]));
  }

  @override
  Future<void> writeCharacteristic(
    String address,
    BmCharacteristicRef c,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  ) {
    lastCharRef = c;
    lastWriteType = writeType;
    lastWriteValue = value;
    return _run('writeCharacteristic', null);
  }

  @override
  Future<Uint8List> readDescriptor(String address, BmDescriptorRef d) =>
      _run('readDescriptor', Uint8List.fromList([0xcd]));

  @override
  Future<void> writeDescriptor(String address, BmDescriptorRef d, Uint8List value) {
    lastWriteValue = value;
    return _run('writeDescriptor', null);
  }

  @override
  Future<bool> setNotifyValue(String address, BmCharacteristicRef c, bool enable) => _run('setNotifyValue', true);

  @override
  Future<int> readRssi(String address) => _run('readRssi', -42);

  List<BmBluetoothDevice> systemDevices = const [];

  @override
  Future<List<BmBluetoothDevice>> getSystemDevices(List<String> withServices) =>
      _run('getSystemDevices', systemDevices);

  @override
  Future<bool> turnOn() => _run('turnOn', true);

  @override
  Future<void> setOptions(bool showPowerAlert, bool restoreState) => _run('setOptions', null);

  @override
  Future<void> setLogLevel(LogLevel level) => _run('setLogLevel', null);

  @override
  Future<String> getAdapterName() => _run('getAdapterName', 'FakeAdapter');

  // android-only surface
  BluetoothBondState bondState = BluetoothBondState.bonded;
  List<BmBluetoothDevice> bondedDevices = const [];

  @override
  Future<int> requestMtu(String address, int mtu) => _run('requestMtu', mtu);

  @override
  Future<bool> createBond(String address, Uint8List? pin) => _run('createBond', bondState == BluetoothBondState.bonded);

  @override
  Future<bool> removeBond(String address) => _run('removeBond', bondState == BluetoothBondState.none);

  @override
  Future<void> clearGattCache(String address) => _run('clearGattCache', null);

  @override
  Future<void> requestConnectionPriority(String address, ConnectionPriority priority) =>
      _run('requestConnectionPriority', null);

  @override
  Future<void> setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions) => _run('setPreferredPhy', null);

  @override
  Future<BluetoothBondState> getBondState(String address) => _run('getBondState', bondState);

  @override
  Future<List<BmBluetoothDevice>> getBondedDevices() => _run('getBondedDevices', bondedDevices);

  @override
  Future<BmPhySupport> getPhySupport() => _run('getPhySupport', BmPhySupport(le2M: true, leCoded: false));

  // L2CAP surface
  int l2capNextId = 1;
  int? lastL2capPsm;
  bool? lastL2capSecure;
  final l2capInboundControllers = <int, StreamController<Uint8List>>{};
  final l2capWrites = <int, List<Uint8List>>{};
  final l2capDetached = <int>[];

  @override
  Future<int> openL2capChannel(String address, int psm, bool secure) {
    lastL2capPsm = psm;
    lastL2capSecure = secure;
    return _run('openL2capChannel', l2capNextId++);
  }

  @override
  Future<void> closeL2capChannel(int channelId) => _run('closeL2capChannel', null);

  @override
  Stream<Uint8List> l2capInput(int channelId) =>
      (l2capInboundControllers[channelId] ??= StreamController<Uint8List>()).stream;

  @override
  Future<void> l2capWrite(int channelId, Uint8List data) {
    (l2capWrites[channelId] ??= []).add(data);
    return _run('l2capWrite', null);
  }

  @override
  void l2capDetach(int channelId) {
    l2capDetached.add(channelId);
    l2capInboundControllers.remove(channelId)?.close();
  }

  static void install(FakePlatform platform) {
    BluebirdPlatform.instance = platform;
    Bluebird.resetForTest();
  }
}
