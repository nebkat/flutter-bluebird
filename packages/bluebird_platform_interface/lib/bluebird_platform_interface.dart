import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'src/l2cap_data_channel.dart';
import 'src/messages.g.dart';

export 'src/messages.g.dart';
export 'src/uuid.dart';

/// The interface that implementations of bluebird must implement.
abstract base class BluebirdPlatform {
  static BluebirdPlatform? _instance;

  /// The default instance of [BluebirdPlatform] to use. Throws an [UnsupportedError] if bluebird is unsupported on this platform.
  static BluebirdPlatform get instance {
    final instance = _instance;

    if (instance != null) {
      return instance;
    } else {
      throw UnsupportedError('bluebird is unsupported on this platform');
    }
  }

  /// Platform-specific plugins should set this with their own platform-specific class that extends [BluebirdPlatform] when they register themselves.
  static set instance(BluebirdPlatform instance) {
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

  Stream<BmScanAdvertisementEvent> get onScanAdvertisement => _eventsOf();

  Stream<BmScanFailedEvent> get onScanFailed => _eventsOf();

  Stream<BmServicesResetEvent> get onServicesReset => _eventsOf();

  /// Unsolicited L2CAP channel closes (peer close, disconnect, or I/O error).
  Stream<BmL2capChannelClosedEvent> get onL2capChannelClosed => _eventsOf();

  /// The single logger for every Bluebird log — the platform method-channel
  /// tracing emitted from this layer *and* the higher-level events from
  /// `package:bluebird` (which re-exposes this as `Bluebird.logger`).
  ///
  /// [Logger.detached], i.e. not wired to the root logger hierarchy, so it is
  /// entirely yours to configure and nothing is printed unless you ask:
  /// ```dart
  /// Bluebird.logger.onRecord.listen((r) => debugPrint('${r.level.name}: ${r.message}'));
  /// Bluebird.logger.level = Level.FINEST; // to also see platform-channel tracing
  /// ```
  ///
  /// Defaults to [Level.INFO], so `FINE`/`FINEST` diagnostics (including the
  /// platform-channel call tracer) are off until you lower the level.
  static final Logger logger = Logger.detached('bluebird')..level = Level.INFO;

  Future<void> clearGattCache(String address) => throw UnimplementedError('$runtimeType.clearGattCache');

  Future<void> connect(String address) => throw UnimplementedError('$runtimeType.connect');

  Future<bool> createBond(String address, Uint8List? pin) => throw UnimplementedError('$runtimeType.createBond');

  Future<void> disconnect(String address) => throw UnimplementedError('$runtimeType.disconnect');

  Future<List<BmBluetoothService>> discoverServices(String address) {
    return Future.value(const []);
  }

  Future<String> getAdapterName() => throw UnimplementedError('$runtimeType.getAdapterName');

  Future<BluetoothAdapterState> getAdapterState() => throw UnimplementedError('$runtimeType.getAdapterState');

  Future<BluetoothBondState> getBondState(String address) => throw UnimplementedError('$runtimeType.getBondState');

  Future<List<BmBluetoothDevice>> getBondedDevices() {
    return Future.value(const []);
  }

  Future<BmPhySupport> getPhySupport() => throw UnimplementedError('$runtimeType.getPhySupport');

  Future<List<BmBluetoothDevice>> getSystemDevices(List<String> withServices) {
    return Future.value(const []);
  }

  Future<bool> isSupported() => throw UnimplementedError('$runtimeType.isSupported');

  Future<Uint8List> readCharacteristic(String address, BmCharacteristicRef characteristic) =>
      throw UnimplementedError('$runtimeType.readCharacteristic');

  Future<Uint8List> readDescriptor(String address, BmDescriptorRef descriptor) =>
      throw UnimplementedError('$runtimeType.readDescriptor');

  Future<int> readRssi(String address) => throw UnimplementedError('$runtimeType.readRssi');

  Future<bool> removeBond(String address) => throw UnimplementedError('$runtimeType.removeBond');

  Future<void> requestConnectionPriority(String address, ConnectionPriority connectionPriority) =>
      throw UnimplementedError('$runtimeType.requestConnectionPriority');

  Future<int> requestMtu(String address, int mtu) => throw UnimplementedError('$runtimeType.requestMtu');

  Future<void> setLogLevel(LogLevel level) {
    return Future.value();
  }

  Future<bool> setNotifyValue(String address, BmCharacteristicRef characteristic, bool enable) =>
      throw UnimplementedError('$runtimeType.setNotifyValue');

  Future<void> setOptions(bool showPowerAlert, bool restoreState) =>
      throw UnimplementedError('$runtimeType.setOptions');

  Future<void> setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions) =>
      throw UnimplementedError('$runtimeType.setPreferredPhy');

  Future<void> startScan(BmScanSettings settings) => throw UnimplementedError('$runtimeType.startScan');

  Future<void> stopScan() => throw UnimplementedError('$runtimeType.stopScan');

  Future<bool> turnOff() => throw UnimplementedError('$runtimeType.turnOff');

  Future<bool> turnOn() => throw UnimplementedError('$runtimeType.turnOn');

  Future<void> writeCharacteristic(
    String address,
    BmCharacteristicRef characteristic,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  ) => throw UnimplementedError('$runtimeType.writeCharacteristic');

  Future<void> writeDescriptor(String address, BmDescriptorRef descriptor, Uint8List value) =>
      throw UnimplementedError('$runtimeType.writeDescriptor');

  /// Opens an L2CAP connection-oriented channel to [psm], returning the
  /// native-assigned channel id. Data flows on the dedicated `bluebird/l2cap`
  /// binary channel — see [l2capInput] / [l2capWrite] and
  /// [BmL2capChannelClosedEvent].
  Future<int> openL2capChannel(String address, int psm, bool secure) =>
      throw UnimplementedError('$runtimeType.openL2capChannel');

  Future<void> closeL2capChannel(int channelId) => throw UnimplementedError('$runtimeType.closeL2capChannel');

  /// The dedicated L2CAP data channel, shared across platforms (the wire
  /// protocol is identical). Lazily created; unused on platforms without L2CAP.
  late final L2capDataChannel _l2capData = L2capDataChannel();

  /// Inbound bytes for an open L2CAP channel (see [openL2capChannel]). Pausing
  /// the subscription backpressures the peer; the stream closes with the channel.
  Stream<Uint8List> l2capInput(int channelId) => _l2capData.input(channelId);

  /// Writes [data] to an open L2CAP channel; completes once the native side has
  /// accepted the bytes (backpressure).
  Future<void> l2capWrite(int channelId, Uint8List data) => _l2capData.write(channelId, data);

  /// Drops local data-channel state for a closed L2CAP channel.
  void l2capDetach(int channelId) => _l2capData.detach(channelId);
}
