import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

final class FlutterBluePlusAndroid extends FlutterBluePlusPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_blue_plus/methods');

  var _didRestart = false;
  var _logLevel = LogLevel.none;
  var _logColor = true;

  final _onAdapterStateChangedController = StreamController<BmBluetoothAdapterState>.broadcast();
  final _onBondStateChangedController = StreamController<BmBondStateResponse>.broadcast();
  final _onCharacteristicReceivedController = StreamController<BmCharacteristicData>.broadcast();
  final _onConnectionStateChangedController = StreamController<BmConnectionStateResponse>.broadcast();
  final _onDetachedFromEngineController = StreamController<BmDetachedFromEngineResponse>.broadcast();
  final _onMtuChangedController = StreamController<BmMtuChangedResponse>.broadcast();
  final _onNameChangedController = StreamController<BmNameChanged>.broadcast();
  final _onScanResponseController = StreamController<BmScanResponse>.broadcast();
  final _onServicesResetController = StreamController<BmBluetoothDevice>.broadcast();

  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged {
    return _onAdapterStateChangedController.stream;
  }

  @override
  Stream<BmBondStateResponse> get onBondStateChanged {
    return _onBondStateChangedController.stream;
  }

  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived {
    return _onCharacteristicReceivedController.stream;
  }

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged {
    return _onConnectionStateChangedController.stream;
  }

  @override
  Stream<BmDetachedFromEngineResponse> get onDetachedFromEngine {
    return _onDetachedFromEngineController.stream;
  }

  @override
  Stream<BmMtuChangedResponse> get onMtuChanged {
    return _onMtuChangedController.stream;
  }

  @override
  Stream<BmNameChanged> get onNameChanged {
    return _onNameChangedController.stream;
  }

  @override
  Stream<BmScanResponse> get onScanResponse {
    return _onScanResponseController.stream;
  }

  @override
  Stream<BmBluetoothDevice> get onServicesReset {
    return _onServicesResetController.stream;
  }

  static void registerWith() {
    FlutterBluePlusPlatform.instance = FlutterBluePlusAndroid();
  }

  @override
  Future<bool> clearGattCache(
    BmClearGattCacheRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'clearGattCache',
        request.address,
      );

  @override
  Future<bool> connect(
    BmConnectRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'connect',
        request.toMap(),
      );

  @override
  Future<BmBondStateResponse> createBond(
    BmCreateBondRequest request,
  ) async =>
      await _callAndroidMethod<BmBondStateResponse>(
        'createBond',
        request.toMap(),
      );

  @override
  Future<bool> disconnect(
    BmDisconnectRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'disconnect',
        request.address,
      );

  @override
  Future<BmDiscoverServicesResponse> discoverServices(
    BmDiscoverServicesRequest request,
  ) async =>
      await _callAndroidMethod<BmDiscoverServicesResponse>(
        'discoverServices',
        request.address,
      );

  @override
  Future<BmBluetoothAdapterName> getAdapterName(
    BmBluetoothAdapterNameRequest request,
  ) async =>
      BmBluetoothAdapterName(
        adapterName: await _callAndroidMethod(
          'getAdapterName',
        ),
      );

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async =>
      BmBluetoothAdapterState.fromMap(
        await _callAndroidMethod(
          'getAdapterState',
        ),
      );

  @override
  Future<BmBondStateResponse> getBondState(
    BmBondStateRequest request,
  ) async =>
      BmBondStateResponse.fromMap(
        await _callAndroidMethod(
          'getBondState',
          request.address,
        ),
      );

  @override
  Future<BmDevicesList> getBondedDevices(
    BmBondedDevicesRequest request,
  ) async =>
      BmDevicesList.fromMap(
        await _callAndroidMethod(
          'getBondedDevices',
        ),
      );

  @override
  Future<BmPhySupport> getPhySupport(
    BmPhySupportRequest request,
  ) async =>
      BmPhySupport.fromMap(
        await _callAndroidMethod(
          'getPhySupport',
        ),
      );

  @override
  Future<BmDevicesList> getSystemDevices(
    BmSystemDevicesRequest request,
  ) async =>
      BmDevicesList.fromMap(
        await _callAndroidMethod(
          'getSystemDevices',
        ),
      );

  @override
  Future<bool> isSupported(
    BmIsSupportedRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'isSupported',
      ) ==
      true;

  @override
  Future<BmCharacteristicData> readCharacteristic(
    BmReadCharacteristicRequest request,
  ) async =>
      await _callAndroidMethod<BmCharacteristicData>(
        'readCharacteristic',
        request.toMap(),
      );

  @override
  Future<BmDescriptorData> readDescriptor(
    BmReadDescriptorRequest request,
  ) async =>
      await _callAndroidMethod<BmDescriptorData>(
        'readDescriptor',
        request.toMap(),
      );

  @override
  Future<BmReadRssiResult> readRssi(
    BmReadRssiRequest request,
  ) async =>
      await _callAndroidMethod<BmReadRssiResult>(
        'readRssi',
        request.address,
      );

  @override
  Future<BmBondStateResponse> removeBond(
    BmRemoveBondRequest request,
  ) async =>
      await _callAndroidMethod<BmBondStateResponse>(
        'removeBond',
        request.address,
      );

  @override
  Future<bool> requestConnectionPriority(
    BmConnectionPriorityRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'requestConnectionPriority',
        request.toMap(),
      );

  @override
  Future<BmMtuChangedResponse> requestMtu(
    BmMtuChangeRequest request,
  ) async =>
      await _callAndroidMethod<BmMtuChangedResponse>(
        'requestMtu',
        request.toMap(),
      );

  @override
  Future<bool> setLogLevel(
    BmSetLogLevelRequest request,
  ) async {
    _logLevel = request.level;
    _logColor = request.color;

    return await _callAndroidMethod<bool>(
      'setLogLevel',
      request.level.index,
    );
  }

  @override
  Future<bool> setNotifyValue(
    BmSetNotifyValueRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'setNotifyValue',
        request.toMap(),
      );

  @override
  Future<bool> setOptions(
    BmSetOptionsRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'setOptions',
        request.toMap(),
      ) ==
      true;

  @override
  Future<bool> setPreferredPhy(
    BmPreferredPhy request,
  ) async =>
      await _callAndroidMethod<bool>(
        'setPreferredPhy',
        request.toMap(),
      );

  @override
  Future<bool> startScan(
    BmScanSettings request,
  ) async =>
      await _callAndroidMethod<bool>(
        'startScan',
        request.toMap(),
      );

  @override
  Future<bool> stopScan(
    BmStopScanRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'stopScan',
      );

  @override
  Future<bool> turnOff(
    BmTurnOffRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'turnOff',
      );

  @override
  Future<BmTurnOnResponse> turnOn(
    BmTurnOnRequest request,
  ) async =>
      await _callAndroidMethod<BmTurnOnResponse>('turnOn');

  @override
  Future<bool> writeCharacteristic(
    BmWriteCharacteristicRequest request,
  ) async =>
      await _callAndroidMethod<bool>(
        'writeCharacteristic',
        request.toMap(),
      );

  @override
  Future<void> writeDescriptor(
    BmWriteDescriptorRequest request,
  ) async =>
      await _callAndroidMethod<void>(
        'writeDescriptor',
        request.toMap(),
      );

  Future<T> _callAndroidMethod<T>(
    String method, [
    dynamic arguments,
  ]) async {
    // restart platform
    if (!_didRestart && method != "setLogLevel") {
      await _flutterRestart();
    }

    // set platform method handler
    methodChannel.setMethodCallHandler(_methodCallHandler);

    // log args
    if (_logLevel == LogLevel.verbose) {
      var func = '<$method>';
      var args = arguments.toString();
      func = _logColor ? '\x1B[1;30m$func\x1B[0m' : func;
      args = _logColor ? '\x1B[1;35m$args\x1B[0m' : args;
      FlutterBluePlusPlatform.log('[FBP] $func args: $args');
    }

    // invoke
    final out = await methodChannel.invokeMethod<T>(method, arguments);

    // log result
    if (_logLevel == LogLevel.verbose) {
      var func = '($method)';
      var result = out.toString();
      func = _logColor ? '\x1B[1;30m$func\x1B[0m' : func;
      result = _logColor ? '\x1B[1;33m$result\x1B[0m' : result;
      FlutterBluePlusPlatform.log('[FBP] $func result: $result');
    }

    return out!;
  }

  Future<void> _flutterRestart() async {
    // wait for all devices to disconnect
    if ((await methodChannel.invokeMethod('flutterRestart')) != 0) {
      await Future.delayed(Duration(milliseconds: 50));
      while ((await methodChannel.invokeMethod('connectedCount')) != 0) {
        await Future.delayed(Duration(milliseconds: 50));
      }
    }
    _didRestart = true;
  }

  Future<void> _methodCallHandler(
    MethodCall call,
  ) async {
    // log result
    if (_logLevel == LogLevel.verbose) {
      var func = '[[ ${call.method} ]]';
      var result = switch (call.method) {
        'OnDiscoveredServices' => _prettyPrint(call.arguments),
        _ => call.arguments.toString(),
      };
      func = _logColor ? '\x1B[1;30m$func\x1B[0m' : func;
      result = _logColor ? '\x1B[1;33m$result\x1B[0m' : result;
      FlutterBluePlusPlatform.log('[FBP] $func result: $result');
    }

    // handle method call
    switch (call.method) {
      case 'OnAdapterStateChanged':
        return _onAdapterStateChangedController.add(
          BmBluetoothAdapterState.fromMap(
            call.arguments,
          ),
        );
      case 'OnBondStateChanged':
        return _onBondStateChangedController.add(
          BmBondStateResponse.fromMap(
            call.arguments,
          ),
        );
      case 'OnCharacteristicReceived':
        return _onCharacteristicReceivedController.add(
          BmCharacteristicData.fromMap(
            call.arguments,
          ),
        );
      case 'OnConnectionStateChanged':
        return _onConnectionStateChangedController.add(
          BmConnectionStateResponse.fromMap(
            call.arguments,
          ),
        );
      case 'OnDescriptorRead':
        return _onDescriptorReadController.add(
          BmDescriptorData.fromMap(
            call.arguments,
          ),
        );
      case 'OnDescriptorWritten':
        return _onDescriptorWrittenController.add(
          BmDescriptorData.fromMap(
            call.arguments,
          ),
        );
      case 'OnDetachedFromEngine':
        return _onDetachedFromEngineController.add(
          BmDetachedFromEngineResponse(),
        );
      case 'OnMtuChanged':
        return _onMtuChangedController.add(
          BmMtuChangedResponse.fromMap(
            call.arguments,
          ),
        );
      case 'OnNameChanged':
        return _onNameChangedController.add(
          BmNameChanged.fromMap(
            call.arguments,
          ),
        );
      case 'OnScanResponse':
        return _onScanResponseController.add(
          BmScanResponse.fromMap(
            call.arguments,
          ),
        );
      case 'OnServicesReset':
        return _onServicesResetController.add(
          BmBluetoothDevice.fromMap(
            call.arguments,
          ),
        );
    }
  }

  String _prettyPrint(
    dynamic data,
  ) {
    if (data is Map || data is List) {
      return JsonEncoder.withIndent('  ').convert(data);
    } else {
      return data.toString();
    }
  }
}
