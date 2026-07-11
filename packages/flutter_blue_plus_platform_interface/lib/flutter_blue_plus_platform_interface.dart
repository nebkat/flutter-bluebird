import 'dart:async';

import 'src/bluetooth_msgs.dart';

export 'src/bluetooth_msgs.dart';
export 'src/log_level.dart';
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

  Stream<BmBluetoothAdapterState> get onAdapterStateChanged {
    return Stream.empty();
  }

  Stream<BmBondStateResponse> get onBondStateChanged {
    return Stream.empty();
  }

  Stream<BmCharacteristicData> get onCharacteristicReceived {
    return Stream.empty();
  }

  Stream<BmConnectionStateResponse> get onConnectionStateChanged {
    return Stream.empty();
  }

  Stream<BmDetachedFromEngineResponse> get onDetachedFromEngine {
    return Stream.empty();
  }

  Stream<BmMtuChangedResponse> get onMtuChanged {
    return Stream.empty();
  }

  Stream<BmNameChanged> get onNameChanged {
    return Stream.empty();
  }

  Stream<BmScanResponse> get onScanResponse {
    return Stream.empty();
  }

  Stream<BmBluetoothDevice> get onServicesReset {
    return Stream.empty();
  }

  static final _logsController = StreamController<String>.broadcast();
  static Stream<String> get logs => _logsController.stream;

  static void log(String s) {
    _logsController.add(s);
    // ignore: avoid_print
    print(s);
  }

  Future<bool> clearGattCache(
    BmClearGattCacheRequest request,
  ) {
    return Future.value(false);
  }

  Future<bool> connect(
    BmConnectRequest request,
  ) {
    return Future.value(false);
  }

  Future<BmBondStateResponse> createBond(
    BmCreateBondRequest request,
  ) {
    return Future.value(BmBondStateResponse.empty(request.address));
  }

  Future<void> disconnect(
    BmDisconnectRequest request,
  ) {
    return Future.value();
  }

  Future<BmDiscoverServicesResponse> discoverServices(
    BmDiscoverServicesRequest request,
  ) {
    return Future.value(BmDiscoverServicesResponse.empty());
  }

  Future<BmBluetoothAdapterName> getAdapterName(
    BmBluetoothAdapterNameRequest request,
  ) {
    return Future.value(
      BmBluetoothAdapterName(
        adapterName: '',
      ),
    );
  }

  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) {
    return Future.value(
      BmBluetoothAdapterState(
        adapterState: BmAdapterStateEnum.unknown,
      ),
    );
  }

  Future<BmBondStateResponse> getBondState(
    BmBondStateRequest request,
  ) {
    return Future.value(
      BmBondStateResponse.empty(request.address),
    );
  }

  Future<BmDevicesList> getBondedDevices(
    BmBondedDevicesRequest request,
  ) {
    return Future.value(
      BmDevicesList.empty(),
    );
  }

  Future<BmPhySupport> getPhySupport(
    BmPhySupportRequest request,
  ) {
    return Future.value(
      BmPhySupport.empty(),
    );
  }

  Future<BmDevicesList> getSystemDevices(
    BmSystemDevicesRequest request,
  ) {
    return Future.value(
      BmDevicesList.empty(),
    );
  }

  Future<bool> isSupported(
    BmIsSupportedRequest request,
  ) {
    return Future.value(false);
  }

  Future<BmCharacteristicData> readCharacteristic(
    BmReadCharacteristicRequest request,
  ) {
    return Future.value(BmCharacteristicData.empty(request.address, request.identifier));
  }

  Future<BmDescriptorData> readDescriptor(
    BmReadDescriptorRequest request,
  ) {
    return Future.value(BmDescriptorData.empty(request.address, request.identifier));
  }

  Future<BmReadRssiResult> readRssi(
    BmReadRssiRequest request,
  ) {
    return Future.value(BmReadRssiResult.empty(request.address));
  }

  Future<BmBondStateResponse> removeBond(
    BmRemoveBondRequest request,
  ) {
    return Future.value(BmBondStateResponse.empty(request.address));
  }

  Future<bool> requestConnectionPriority(
    BmConnectionPriorityRequest request,
  ) {
    return Future.value(false);
  }

  Future<BmMtuChangedResponse> requestMtu(
    BmMtuChangeRequest request,
  ) {
    return Future.value(BmMtuChangedResponse.empty(request.address));
  }

  Future<bool> setLogLevel(
    BmSetLogLevelRequest request,
  ) {
    return Future.value(false);
  }

  Future<void> setNotifyValue(
    BmSetNotifyValueRequest request,
  ) {
    return Future.value();
  }

  Future<void> setOptions(
    BmSetOptionsRequest request,
  ) {
    return Future.value();
  }

  Future<bool> setPreferredPhy(
    BmPreferredPhy request,
  ) {
    return Future.value(false);
  }

  Future<bool> startScan(
    BmScanSettings request,
  ) {
    return Future.value(false);
  }

  Future<bool> stopScan(
    BmStopScanRequest request,
  ) {
    return Future.value(false);
  }

  Future<bool> turnOff(
    BmTurnOffRequest request,
  ) {
    return Future.value(false);
  }

  Future<BmTurnOnResponse> turnOn(
    BmTurnOnRequest request,
  ) {
    return Future.value(BmTurnOnResponse(userAccepted: true));
  }

  Future<void> writeCharacteristic(
    BmWriteCharacteristicRequest request,
  ) {
    return Future.value();
  }

  Future<void> writeDescriptor(
    BmWriteDescriptorRequest request,
  ) {
    return Future.value();
  }
}
