import 'dart:async';
import 'dart:typed_data';

import 'src/messages.g.dart';

export 'src/messages.g.dart';
export 'src/uuid.dart';

/// The interface that implementations of flutter_blue_plus must implement.
abstract base class FlutterBluePlusPlatform {
  static FlutterBluePlusPlatform? _instance;

  /// The default instance of [FlutterBluePlusPlatform] to use. Throws an [UnsupportedError] if flutter_blue_plus is unsupported on this platform.
  static FlutterBluePlusPlatform get instance {
    final instance = _instance;

    if (instance != null) {
      return instance;
    } else {
      throw UnsupportedError('flutter_blue_plus is unsupported on this platform');
    }
  }

  /// Platform-specific plugins should set this with their own platform-specific class that extends [FlutterBluePlusPlatform] when they register themselves.
  static set instance(FlutterBluePlusPlatform instance) {
    _instance = instance;
  }

  /// All unsolicited platform events, in native emission order.
  ///
  /// Implementations override only this getter; the typed event getters below
  /// are derived from it.
  Stream<BmEvent> get events {
    return const Stream.empty();
  }

  Stream<T> _eventsOf<T extends BmEvent>() {
    return events.where((e) => e is T).cast<T>();
  }

  Stream<BmAdapterStateEvent> get onAdapterStateChanged => _eventsOf();

  Stream<BmBondStateEvent> get onBondStateChanged => _eventsOf();

  /// Values received via notify/indicate. Read responses are returned from
  /// [readCharacteristic] instead.
  Stream<BmCharacteristicNotificationEvent> get onCharacteristicNotified => _eventsOf();

  Stream<BmConnectionStateEvent> get onConnectionStateChanged => _eventsOf();

  Stream<BmDetachedFromEngineEvent> get onDetachedFromEngine => _eventsOf();

  Stream<BmMtuChangedEvent> get onMtuChanged => _eventsOf();

  Stream<BmNameChangedEvent> get onNameChanged => _eventsOf();

  Stream<BmScanAdvertisementsEvent> get onScanAdvertisements => _eventsOf();

  Stream<BmScanFailedEvent> get onScanFailed => _eventsOf();

  Stream<BmServicesResetEvent> get onServicesReset => _eventsOf();

  static final _logsController = StreamController<String>.broadcast();
  static Stream<String> get logs => _logsController.stream;

  static void log(String s) {
    _logsController.add(s);
    // ignore: avoid_print
    print(s);
  }

  Future<void> clearGattCache(String address) {
    return Future.value();
  }

  Future<void> connect(String address) {
    return Future.value();
  }

  Future<bool> createBond(String address, Uint8List? pin) {
    return Future.value(false);
  }

  Future<void> disconnect(String address) {
    return Future.value();
  }

  Future<List<BmBluetoothService>> discoverServices(String address) {
    return Future.value(const []);
  }

  Future<String> getAdapterName() {
    return Future.value('');
  }

  Future<BmAdapterStateEnum> getAdapterState() {
    return Future.value(BmAdapterStateEnum.unknown);
  }

  Future<BmBondStateEnum> getBondState(String address) {
    return Future.value(BmBondStateEnum.none);
  }

  Future<List<BmBluetoothDevice>> getBondedDevices() {
    return Future.value(const []);
  }

  Future<BmPhySupport> getPhySupport() {
    return Future.value(BmPhySupport(le2M: false, leCoded: false));
  }

  Future<List<BmBluetoothDevice>> getSystemDevices(List<String> withServices) {
    return Future.value(const []);
  }

  Future<bool> isSupported() {
    return Future.value(false);
  }

  Future<Uint8List> readCharacteristic(String address, BmCharacteristicRef characteristic) {
    return Future.value(Uint8List(0));
  }

  Future<Uint8List> readDescriptor(String address, BmDescriptorRef descriptor) {
    return Future.value(Uint8List(0));
  }

  Future<int> readRssi(String address) {
    return Future.value(0);
  }

  Future<bool> removeBond(String address) {
    return Future.value(false);
  }

  Future<void> requestConnectionPriority(String address, BmConnectionPriorityEnum connectionPriority) {
    return Future.value();
  }

  Future<int> requestMtu(String address, int mtu) {
    return Future.value(0);
  }

  /// [color] only affects Dart-side log formatting; it does not cross to the
  /// platform.
  Future<void> setLogLevel(LogLevel level, {bool color = true}) {
    return Future.value();
  }

  Future<bool> setNotifyValue(String address, BmCharacteristicRef characteristic, bool forceIndications, bool enable) {
    return Future.value(false);
  }

  Future<void> setOptions(bool showPowerAlert, bool restoreState) {
    return Future.value();
  }

  Future<void> setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions) {
    return Future.value();
  }

  Future<void> startScan(BmScanSettings settings) {
    return Future.value();
  }

  Future<void> stopScan() {
    return Future.value();
  }

  Future<bool> turnOff() {
    return Future.value(false);
  }

  Future<bool> turnOn() {
    return Future.value(true);
  }

  Future<void> writeCharacteristic(
    String address,
    BmCharacteristicRef characteristic,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  ) {
    return Future.value();
  }

  Future<void> writeDescriptor(String address, BmDescriptorRef descriptor, Uint8List value) {
    return Future.value();
  }
}
