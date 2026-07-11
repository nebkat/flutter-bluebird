import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' show Event;

import 'src/html.dart';
import 'src/web_bluetooth.dart';

final class BluebirdWeb extends BluebirdPlatform {
  late final _characteristicValueChangedEventListener = _handleCharacteristicValueChanged.toJS;

  final _devices = <String, BluetoothDevice>{};

  BluetoothRemoteGATTServer _gattForDevice(String address) {
    final device = _devices[address];
    if (device == null) throw Exception('The device "$address" could not be found.');
    final gatt = device.gatt;
    if (gatt == null) throw Exception('The gatt for the device "$address" is null.');
    return gatt;
  }

  // for instanceIds
  final _charCache = <String, Map<Uuid, Map<Uuid, List<BluetoothRemoteGATTCharacteristic>>>>{};

  final _onCharacteristicReceivedController = StreamController<BmCharacteristicData>.broadcast();
  final _onConnectionStateChangedController = StreamController<BmConnectionStateResponse>.broadcast();
  final _onDevicesChangedController = StreamController<List<BluetoothDevice>>.broadcast();
  final _onScanResponseController = StreamController<BmScanResponse>.broadcast();

  BluetoothRemoteGATTCharacteristic _findCharacteristicOrThrow({
    required String address,
    required String identifier,
  }) {
    // final list = _charCache[address]?[serviceUuid]?[charUuid];
    // if (list == null || instanceId < 0 || instanceId >= list.length) {
    //   throw Exception(
    //     'Characteristic not found in cache: service=$serviceUuid char=$charUuid instanceId=$instanceId',
    //   );
    // }
    // return list[instanceId];
    throw UnimplementedError('Characteristic access by identifier is not implemented yet.');
  }

  BluetoothRemoteGATTDescriptor _findDescriptorOrThrow({
    required String address,
    required String identifier,
  }) {
    // final characteristic = _findCharacteristicOrThrow(
    //   address: address,
    //   serviceUuid: serviceUuid,
    //   charUuid: charUuid,
    //   instanceId: instanceId,
    // );
    // return characteristic.getDescriptor(descriptorUuid.toJS).toDart;
    throw UnimplementedError('Descriptor access is not implemented yet.');
  }

  int _instanceId(String devId, Uuid serviceUuid, BluetoothRemoteGATTCharacteristic target) {
    final list = _charCache[devId]?[serviceUuid]?[Uuid(target.uuid)];
    if (list == null) return 0;
    final idx = list.indexWhere((c) => identical(c, target));
    return idx >= 0 ? idx : 0;
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
  Stream<BmScanResponse> get onScanResponse {
    return _onScanResponseController.stream;
  }

  static void registerWith(Registrar registrar) {
    BluebirdPlatform.instance = BluebirdWeb();
  }

  @override
  Future<bool> connect(
    BmConnectRequest request,
  ) async {
    final gatt = _gattForDevice(request.address);
    await gatt.connect().toDart;

    _onConnectionStateChangedController.add(
      BmConnectionStateResponse(
        address: request.address,
        connectionState: BmConnectionStateEnum.connected,
        disconnectReasonCode: null,
        disconnectReasonString: null,
      ),
    );

    return true;
  }

  @override
  Future<void> disconnect(
    BmDisconnectRequest request,
  ) async {
    final gatt = _gattForDevice(request.address);
    gatt.disconnect();

    // drop cache for this device to avoid stale entries
    _charCache.remove(request.address);

    _onConnectionStateChangedController.add(
      BmConnectionStateResponse(
        address: request.address,
        connectionState: BmConnectionStateEnum.disconnected,
        disconnectReasonCode: null,
        disconnectReasonString: null,
      ),
    );
  }

  @override
  Future<BmDiscoverServicesResponse> discoverServices(
    BmDiscoverServicesRequest request,
  ) async {
    final gatt = _gattForDevice(request.address);
    final services = <BmBluetoothService>[];

    // ensure dev map exists
    final devMap = _charCache.putIfAbsent(request.address, () {
      return <Uuid, Map<Uuid, List<BluetoothRemoteGATTCharacteristic>>>{};
    });

    // Enumerate services and characteristics; build cache synchronously from discovery results
    final primaryServices = (await gatt.getPrimaryServices().toDart).toDart;
    for (final s in primaryServices) {
      final characteristics = <BmBluetoothCharacteristic>[];

      // reset/ensure service map
      final charsByUuid = devMap.putIfAbsent(Uuid(s.uuid), () {
        return <Uuid, List<BluetoothRemoteGATTCharacteristic>>{};
      });

      // pull all chars and cache them grouped by char.uuid (order matters and defines instanceId)
      final chars = (await s.getCharacteristics().toDart).toDart;

      // rebuild for this service
      charsByUuid
        ..clear()
        ..addAll(<Uuid, List<BluetoothRemoteGATTCharacteristic>>{});
      for (final c in chars) {
        (charsByUuid[Uuid(c.uuid)] ??= <BluetoothRemoteGATTCharacteristic>[]).add(c);
      }

      for (final c in chars) {
        final descriptors = <BmBluetoothDescriptor>[];

        try {
          final descs = (await c.getDescriptors().toDart).toDart;
          for (final d in descs) {
            descriptors.add(
              BmBluetoothDescriptor(uuid: Uuid(d.uuid)),
            );
          }
        } catch (e) {
          // ignore errors when getting characteristics descriptors
        }

        characteristics.add(
          BmBluetoothCharacteristic(
            uuid: Uuid(c.uuid),
            index: _instanceId(request.address, Uuid(s.uuid), c),
            descriptors: descriptors,
            properties: BmCharacteristicProperties(
              broadcast: c.properties.broadcast,
              read: c.properties.read,
              writeWithoutResponse: c.properties.writeWithoutResponse,
              write: c.properties.write,
              notify: c.properties.notify,
              indicate: c.properties.indicate,
              authenticatedSignedWrites: c.properties.authenticatedSignedWrites,
              extendedProperties: false,
              notifyEncryptionRequired: false,
              indicateEncryptionRequired: false,
            ),
          ),
        );
      }

      services.add(
        BmBluetoothService(
          uuid: Uuid(s.uuid),
          index: 0, // TODO
          isPrimary: s.isPrimary,
          characteristics: characteristics,
          includedServices: [], // TODO
        ),
      );
    }

    return BmDiscoverServicesResponse(services: services);
  }

  @override
  Future<bool> isSupported(
    BmIsSupportedRequest request,
  ) async {
    try {
      return (await window.navigator.bluetooth.getAvailability().toDart).toDart;
    } catch (e) {
      return false; // https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API#browser_compatibility
    }
  }

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) {
    return isSupported(BmIsSupportedRequest()).then(
      (supported) => BmBluetoothAdapterState(
        adapterState: supported ? BmAdapterStateEnum.on : BmAdapterStateEnum.unknown,
      ),
    );
  }

  @override
  Future<BmCharacteristicData> readCharacteristic(
    BmReadCharacteristicRequest request,
  ) async {
    final characteristic = _findCharacteristicOrThrow(address: request.address, identifier: request.identifier);

    final value = (await characteristic.readValue().toDart).toDart;
    return BmCharacteristicData(
      address: request.address,
      identifier: request.identifier,
      value: value.buffer.asUint8List(),
    );
  }

  @override
  Future<BmDescriptorData> readDescriptor(
    BmReadDescriptorRequest request,
  ) async {
    final descriptor = _findDescriptorOrThrow(address: request.address, identifier: request.identifier);

    final value = (await descriptor.readValue().toDart).toDart;
    return BmDescriptorData(
      address: request.address,
      identifier: request.identifier,
      value: value.buffer.asUint8List(),
    );
  }

  @override
  Future<bool> setNotifyValue(
    BmSetNotifyValueRequest request,
  ) async {
    final characteristic = _findCharacteristicOrThrow(address: request.address, identifier: request.identifier);

    if (request.enable) {
      characteristic.addEventListener('characteristicvaluechanged', _characteristicValueChangedEventListener);
      await characteristic.startNotifications().toDart;
    } else {
      await characteristic.stopNotifications().toDart;
      characteristic.removeEventListener('characteristicvaluechanged', _characteristicValueChangedEventListener);
    }

    return true;
  }

  @override
  Future<bool> startScan(
    BmScanSettings request,
  ) async {
    final filters = <BluetoothLEScanFilterInit>[
      // Services
      for (final service in request.withServices)
        BluetoothLEScanFilterInit(
          services: [
            service.string128.toJS,
          ].toJS,
        ),

      // Names
      for (final name in request.withNames)
        BluetoothLEScanFilterInit(
          name: name,
        ),

      // Manufacturer data
      for (final manufacturerData in request.withMsd)
        BluetoothLEScanFilterInit(
          manufacturerData: [
            BluetoothManufacturerDataFilterInit(
              companyIdentifier: manufacturerData.manufacturerId,
            ),
          ].toJS,
        ),

      // Service data
      for (final serviceData in request.withServiceData)
        BluetoothLEScanFilterInit(
          serviceData: [
            BluetoothServiceDataFilterInit(
              service: serviceData.service.string128.toJS,
            ),
          ].toJS,
        )
    ];

    final RequestDeviceOptions options;

    if (filters.isNotEmpty) {
      options = RequestDeviceOptions(
        filters: filters.toJS,
        optionalServices: request.webOptionalServices.map((e) => e.string128.toJS).toList().toJS,
      );
    } else {
      // https://developer.mozilla.org/en-US/docs/Web/API/Bluetooth/requestDevice#acceptalldevices
      options = RequestDeviceOptions(
        acceptAllDevices: true,
        optionalServices: request.webOptionalServices.map((e) => e.string128.toJS).toList().toJS,
      );
    }

    final device = await window.navigator.bluetooth.requestDevice(options).toDart;

    _devices[device.address] = device;
    _onDevicesChangedController.add([..._devices.values]);

    _onScanResponseController.add(
      BmScanResponse(
        advertisements: [
          BmScanAdvertisement(
            address: device.address,
            platformName: device.name,
            advName: null,
            connectable: true,
            txPowerLevel: null,
            appearance: null,
            manufacturerData: {},
            serviceData: {},
            serviceUuids: [],
            rssi: 0,
          ),
        ],
        success: true,
        errorCode: 0,
        errorString: '',
      ),
    );

    return true;
  }

  @override
  Future<void> writeCharacteristic(
    BmWriteCharacteristicRequest request,
  ) async {
    final characteristic = _findCharacteristicOrThrow(address: request.address, identifier: request.identifier);

    if (request.writeType == BmWriteType.withResponse) {
      await characteristic.writeValueWithResponse(Uint8List.fromList(request.value).toJS).toDart;
    } else {
      await characteristic.writeValueWithoutResponse(Uint8List.fromList(request.value).toJS).toDart;
    }
  }

  @override
  Future<void> writeDescriptor(
    BmWriteDescriptorRequest request,
  ) async {
    final descriptor = _findDescriptorOrThrow(address: request.address, identifier: request.identifier);
    await descriptor.writeValue(Uint8List.fromList(request.value).toJS).toDart;
  }

  void _handleCharacteristicValueChanged(
    Event event,
  ) {
    final characteristic = event.target as BluetoothRemoteGATTCharacteristic;

    final address = characteristic.service.device.address;

    _onCharacteristicReceivedController.add(
      BmCharacteristicData(
        address: address,
        identifier: '', // TODO
        value: characteristic.value?.toDart.buffer.asUint8List() ?? [],
      ),
    );
  }
}

extension on BluetoothDevice {
  String get address {
    return id;
  }
}
