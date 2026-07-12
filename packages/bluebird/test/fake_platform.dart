import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

/// A controllable [BluebirdPlatform] for unit tests: drive [emit] to push
/// platform events, and stub method results/errors as needed.
final class FakePlatform extends BluebirdPlatform {
  final _events = StreamController<BmEvent>.broadcast();

  BmAdapterStateEnum adapterState = BmAdapterStateEnum.on;
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
    if (stub != null) return stub() as T;
    return fallback;
  }

  @override
  Future<bool> isSupported() => _run('isSupported', supported);

  @override
  Future<BmAdapterStateEnum> getAdapterState() => _run('getAdapterState', adapterState);

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
      String address, BmCharacteristicRef c, BmWriteType writeType, bool allowLongWrite, Uint8List value) {
    lastCharRef = c;
    lastWriteType = writeType;
    lastWriteValue = value;
    return _run('writeCharacteristic', null);
  }

  @override
  Future<Uint8List> readDescriptor(String address, BmDescriptorRef d) => _run('readDescriptor', Uint8List.fromList([0xcd]));

  @override
  Future<void> writeDescriptor(String address, BmDescriptorRef d, Uint8List value) {
    lastWriteValue = value;
    return _run('writeDescriptor', null);
  }

  @override
  Future<bool> setNotifyValue(String address, BmCharacteristicRef c, bool force, bool enable) =>
      _run('setNotifyValue', true);

  @override
  Future<int> readRssi(String address) => _run('readRssi', -42);

  List<BmBluetoothDevice> systemDevices = const [];

  @override
  Future<List<BmBluetoothDevice>> getSystemDevices(List<String> withServices) => _run('getSystemDevices', systemDevices);

  @override
  Future<bool> turnOn() => _run('turnOn', true);

  @override
  Future<void> setOptions(bool showPowerAlert, bool restoreState) => _run('setOptions', null);

  @override
  Future<void> setLogLevel(LogLevel level, {bool color = true}) => _run('setLogLevel', null);

  @override
  Future<String> getAdapterName() => _run('getAdapterName', 'FakeAdapter');

  // android-only surface
  BmBondStateEnum bondState = BmBondStateEnum.bonded;
  List<BmBluetoothDevice> bondedDevices = const [];

  @override
  Future<int> requestMtu(String address, int mtu) => _run('requestMtu', mtu);

  @override
  Future<bool> createBond(String address, Uint8List? pin) => _run('createBond', bondState == BmBondStateEnum.bonded);

  @override
  Future<bool> removeBond(String address) => _run('removeBond', bondState == BmBondStateEnum.none);

  @override
  Future<void> clearGattCache(String address) => _run('clearGattCache', null);

  @override
  Future<void> requestConnectionPriority(String address, BmConnectionPriorityEnum priority) =>
      _run('requestConnectionPriority', null);

  @override
  Future<void> setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions) => _run('setPreferredPhy', null);

  @override
  Future<BmBondStateEnum> getBondState(String address) => _run('getBondState', bondState);

  @override
  Future<List<BmBluetoothDevice>> getBondedDevices() => _run('getBondedDevices', bondedDevices);

  @override
  Future<BmPhySupport> getPhySupport() => _run('getPhySupport', BmPhySupport(le2M: true, leCoded: false));

  static void install(FakePlatform platform) {
    BluebirdPlatform.instance = platform;
    Bluebird.resetForTest();
  }
}
