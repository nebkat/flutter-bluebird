import 'dart:typed_data';

import 'log_level.dart';
import 'uuid.dart';

enum BmAdapterStateEnum {
  unknown, // 0
  unavailable, // 1
  unauthorized, // 2
  turningOn, // 3
  on, // 4
  turningOff, // 5
  off, // 6
}

class BmBluetoothAdapterState {
  BmAdapterStateEnum adapterState;

  BmBluetoothAdapterState({required this.adapterState});

  Map<dynamic, dynamic> toMap() => {
        'adapter_state': adapterState.index,
      };

  BmBluetoothAdapterState.fromMap(Map<dynamic, dynamic> json)
      : adapterState = BmAdapterStateEnum.values[json['adapter_state']];
}

class BmMsdFilter {
  int manufacturerId;
  List<int>? data;
  List<int>? mask;
  BmMsdFilter(this.manufacturerId, this.data, this.mask);
  Map<dynamic, dynamic> toMap() => {
        'manufacturer_id': manufacturerId,
        'data': data,
        'mask': mask,
      };
}

class BmServiceDataFilter {
  Uuid service;
  List<int> data;
  List<int>? mask;
  BmServiceDataFilter(this.service, this.data, this.mask);
  Map<dynamic, dynamic> toMap() => {
        'service': service.string,
        'data': data,
        'mask': mask,
      };
}

class BmScanSettings {
  final List<Uuid> withServices;
  final List<String> withRemoteIds;
  final List<String> withNames;
  final List<String> withKeywords;
  final List<BmMsdFilter> withMsd;
  final List<BmServiceDataFilter> withServiceData;
  final bool continuousUpdates;
  final int continuousDivisor;
  final bool androidLegacy;
  final int androidScanMode;
  final bool androidUsesFineLocation;
  final List<Uuid> webOptionalServices;

  BmScanSettings({
    required this.withServices,
    required this.withRemoteIds,
    required this.withNames,
    required this.withKeywords,
    required this.withMsd,
    required this.withServiceData,
    required this.continuousUpdates,
    required this.continuousDivisor,
    required this.androidLegacy,
    required this.androidScanMode,
    required this.androidUsesFineLocation,
    required this.webOptionalServices,
  });

  Map<dynamic, dynamic> toMap() => {
        'with_services': withServices.map((s) => s.string).toList(),
        'with_remote_ids': withRemoteIds,
        'with_names': withNames,
        'with_keywords': withKeywords,
        'with_msd': withMsd.map((d) => d.toMap()).toList(),
        'with_service_data': withServiceData.map((d) => d.toMap()).toList(),
        'continuous_updates': continuousUpdates,
        'continuous_divisor': continuousDivisor,
        'android_legacy': androidLegacy,
        'android_scan_mode': androidScanMode,
        'android_uses_fine_location': androidUsesFineLocation,
        'web_optional_services': webOptionalServices.map((s) => s.string).toList(),
      };
}

class BmScanAdvertisement {
  final String address;
  final String? platformName;
  final String? advName;
  final bool connectable;
  final int? txPowerLevel;
  final int? appearance; // not supported on iOS / macOS
  final Map<int, List<int>> manufacturerData;
  final Map<Uuid, List<int>> serviceData;
  final List<Uuid> serviceUuids;
  final int rssi;

  BmScanAdvertisement({
    required this.address,
    required this.platformName,
    required this.advName,
    required this.connectable,
    required this.txPowerLevel,
    required this.appearance,
    required this.manufacturerData,
    required this.serviceData,
    required this.serviceUuids,
    required this.rssi,
  });

  BmScanAdvertisement.fromMap(Map<dynamic, dynamic> json)
      : address = json['remote_id'],
        platformName = json['platform_name'],
        advName = json['adv_name'],
        connectable = json['connectable'] != null ? json['connectable'] != 0 : false,
        txPowerLevel = json['tx_power_level'],
        appearance = json['appearance'],
        manufacturerData =
            json['manufacturer_data']?.map<int, List<int>>((key, value) => MapEntry(key as int, value)) ??
                {}, // TODO: Cast?
        serviceData = json['service_data']?.map<Uuid, List<int>>((key, value) => MapEntry(Uuid(key), value)) ?? {},
        serviceUuids = json['service_uuids']?.map((v) => Uuid(v)).toList() ?? [],
        rssi = json['rssi'] ?? 0;
}

class BmStatus {
  final bool success;
  final int errorCode;
  final String errorString;

  const BmStatus({
    this.success = true,
    this.errorCode = 0,
    this.errorString = "",
  });

  BmStatus.fromMap(Map<dynamic, dynamic> json)
      : success = json['success'] != 0,
        errorCode = json['error_code'] ?? 0,
        errorString = json['error_string'] ?? "";
}

class BmStopScanRequest {
  BmStopScanRequest();
}

class BmScanResponse extends BmStatus {
  final List<BmScanAdvertisement> advertisements;

  BmScanResponse({
    required super.success,
    required super.errorCode,
    required super.errorString,
    required this.advertisements,
  });

  BmScanResponse.fromMap(super.json)
      : advertisements = json['advertisements']
            .map<BmScanAdvertisement>((v) => BmScanAdvertisement.fromMap(v as Map<dynamic, dynamic>))
            .toList(),
        super.fromMap();
}

class BmConnectRequest {
  String address;

  BmConnectRequest({required this.address});

  Map<dynamic, dynamic> toMap() => {'remote_id': address};
}

class BmBluetoothDevice {
  String address;
  String? platformName;

  BmBluetoothDevice.fromMap(Map<dynamic, dynamic> json)
      : address = json['remote_id'],
        platformName = json['platform_name'];
}

class BmNameChanged {
  final String address;
  final String name;

  BmNameChanged.fromMap(Map<dynamic, dynamic> json)
      : address = json['remote_id'],
        name = json['name'];
}

class BmBluetoothService {
  final Uuid uuid;
  final int index;
  final bool isPrimary;
  List<BmBluetoothCharacteristic> characteristics;
  List<String> includedServices;

  BmBluetoothService({
    required this.uuid,
    required this.index,
    required this.isPrimary,
    required this.characteristics,
    required this.includedServices,
  });

  BmBluetoothService.fromMap(Map<dynamic, dynamic> json)
      : uuid = Uuid(json['uuid']),
        index = json['index'],
        isPrimary = json['primary'] != 0,
        characteristics = (json['characteristics'] as List<dynamic>)
            .map<BmBluetoothCharacteristic>((v) => BmBluetoothCharacteristic.fromMap(v))
            .toList(),
        includedServices = (json['included_services'] as List<dynamic>).map((v) => v as String).toList();
}

class BmBluetoothCharacteristic {
  final Uuid uuid;
  final int index;
  List<BmBluetoothDescriptor> descriptors;
  BmCharacteristicProperties properties;

  BmBluetoothCharacteristic({
    required this.uuid,
    required this.index,
    required this.descriptors,
    required this.properties,
  });

  BmBluetoothCharacteristic.fromMap(Map<dynamic, dynamic> json)
      : uuid = Uuid(json['uuid']),
        index = json['index'],
        descriptors = (json['descriptors'] as List<dynamic>).map((v) => BmBluetoothDescriptor.fromMap(v)).toList(),
        properties = BmCharacteristicProperties.fromMap(json['properties']);
}

class BmBluetoothDescriptor {
  final Uuid uuid;

  BmBluetoothDescriptor({required this.uuid});

  BmBluetoothDescriptor.fromMap(Map<dynamic, dynamic> json) : uuid = Uuid(json['uuid']);
}

class BmCharacteristicProperties {
  bool broadcast;
  bool read;
  bool writeWithoutResponse;
  bool write;
  bool notify;
  bool indicate;
  bool authenticatedSignedWrites;
  bool extendedProperties;
  bool notifyEncryptionRequired;
  bool indicateEncryptionRequired;

  BmCharacteristicProperties({
    required this.broadcast,
    required this.read,
    required this.writeWithoutResponse,
    required this.write,
    required this.notify,
    required this.indicate,
    required this.authenticatedSignedWrites,
    required this.extendedProperties,
    required this.notifyEncryptionRequired,
    required this.indicateEncryptionRequired,
  });

  BmCharacteristicProperties.fromMap(Map<dynamic, dynamic> json)
      : broadcast = json['broadcast'] != 0,
        read = json['read'] != 0,
        writeWithoutResponse = json['write_without_response'] != 0,
        write = json['write'] != 0,
        notify = json['notify'] != 0,
        indicate = json['indicate'] != 0,
        authenticatedSignedWrites = json['authenticated_signed_writes'] != 0,
        extendedProperties = json['extended_properties'] != 0,
        notifyEncryptionRequired = json['notify_encryption_required'] != 0,
        indicateEncryptionRequired = json['indicate_encryption_required'] != 0;
}

class BmDiscoverServicesRequest {
  String address;

  BmDiscoverServicesRequest({
    required this.address,
  });
}

class BmDiscoverServicesResponse {
  final List<BmBluetoothService> services;

  const BmDiscoverServicesResponse({
    required this.services,
  });

  const BmDiscoverServicesResponse.empty() : services = const [];

  BmDiscoverServicesResponse.fromMap(Map<dynamic, dynamic> json)
      : services = (json['services'] as List<dynamic>)
            .map((e) => BmBluetoothService.fromMap(e as Map<dynamic, dynamic>))
            .toList();
}

class BmBluetoothAdapterNameRequest {
  BmBluetoothAdapterNameRequest();
}

class BmBluetoothAdapterName {
  String adapterName;

  BmBluetoothAdapterName({required this.adapterName});
}

class BmBluetoothAdapterStateRequest {
  BmBluetoothAdapterStateRequest();
}

class BmReadCharacteristicRequest {
  final String address;
  final String identifier;

  BmReadCharacteristicRequest({
    required this.address,
    required this.identifier,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'identifier': identifier,
      };
}

class BmCharacteristicData {
  final String address;
  final String identifier;
  final List<int> value;

  const BmCharacteristicData({
    required this.address,
    required this.identifier,
    required this.value,
  });

  const BmCharacteristicData.empty(this.address, this.identifier) : value = const [];

  BmCharacteristicData.fromMap(Map<String, dynamic> json)
      : address = json['remote_id'],
        identifier = json['identifier'],
        value = json['value'];
}

class BmReadDescriptorRequest {
  final String address;
  final String identifier;

  BmReadDescriptorRequest({
    required this.address,
    required this.identifier,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'identifier': identifier,
      };
}

enum BmWriteType {
  withResponse,
  withoutResponse,
}

class BmWriteCharacteristicRequest {
  final String address;
  final String identifier;
  final BmWriteType writeType;
  final bool allowLongWrite;
  final List<int> value;

  BmWriteCharacteristicRequest({
    required this.address,
    required this.identifier,
    required this.writeType,
    required this.allowLongWrite,
    required this.value,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'identifier': identifier,
        'write_type': writeType.index,
        'allow_long_write': allowLongWrite,
        'value': value,
      };
}

class BmWriteDescriptorRequest {
  final String address;
  final String identifier;
  final List<int> value;

  BmWriteDescriptorRequest({
    required this.address,
    required this.identifier,
    required this.value,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'identifier': identifier,
        'value': value,
      };
}

class BmDescriptorData {
  final String address;
  final String identifier;
  final List<int> value;

  const BmDescriptorData({
    required this.address,
    required this.identifier,
    required this.value,
  });

  const BmDescriptorData.empty(this.address, this.identifier) : value = const [];

  BmDescriptorData.fromMap(Map<String, dynamic> json)
      : address = json['remote_id'],
        identifier = json['identifier'],
        value = json['value'];
}

class BmIsSupportedRequest {
  BmIsSupportedRequest();
}

class BmSetNotifyValueRequest {
  final String address;
  final String identifier;
  final bool forceIndications;
  final bool enable;

  BmSetNotifyValueRequest({
    required this.address,
    required this.identifier,
    required this.forceIndications,
    required this.enable,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'identifier': identifier,
        'force_indications': forceIndications,
        'enable': enable,
      };
}

enum BmConnectionStateEnum {
  disconnected, // 0
  connected, // 1
}

class BmConnectionStateResponse {
  final String address;
  final BmConnectionStateEnum connectionState;
  final int? disconnectReasonCode;
  final String? disconnectReasonString;

  BmConnectionStateResponse({
    required this.address,
    required this.connectionState,
    this.disconnectReasonCode,
    this.disconnectReasonString,
  });

  BmConnectionStateResponse.fromMap(Map<dynamic, dynamic> json)
      : address = json['remote_id'],
        connectionState = BmConnectionStateEnum.values[json['connection_state'] as int],
        disconnectReasonCode = json['disconnect_reason_code'],
        disconnectReasonString = json['disconnect_reason_string'];
}

class BmBondedDevicesRequest {
  BmBondedDevicesRequest();
}

class BmSystemDevicesRequest {
  final List<Uuid> withServices;

  BmSystemDevicesRequest({
    required this.withServices,
  });

  Map<dynamic, dynamic> toMap() => {'with_services': withServices};
}

class BmDevicesList {
  final List<BmBluetoothDevice> devices;

  const BmDevicesList.empty() : devices = const [];
  BmDevicesList.fromMap(Map<dynamic, dynamic> json) : devices = json['devices'].map(BmBluetoothDevice.fromMap).toList();
}

class BmMtuChangeRequest {
  final String address;
  final int mtu;

  BmMtuChangeRequest({required this.address, required this.mtu});

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'mtu': mtu,
      };
}

class BmMtuChangedResponse extends BmStatus {
  final String address;
  final int mtu;

  const BmMtuChangedResponse({
    required this.address,
    required this.mtu,
  });

  const BmMtuChangedResponse.empty(this.address) : mtu = 0;

  BmMtuChangedResponse.fromMap(super.json)
      : address = json['remote_id'],
        mtu = json['mtu'],
        super.fromMap();
}

class BmClearGattCacheRequest {
  String address;

  BmClearGattCacheRequest({
    required this.address,
  });
}

class BmReadRssiRequest {
  String address;

  BmReadRssiRequest({
    required this.address,
  });
}

class BmReadRssiResult extends BmStatus {
  final String address;
  final int rssi;

  const BmReadRssiResult({
    required this.address,
    required this.rssi,
    required super.success,
    required super.errorCode,
    required super.errorString,
  });

  const BmReadRssiResult.empty(this.address) : rssi = 0;

  BmReadRssiResult.fromMap(super.json)
      : address = json['remote_id'],
        rssi = json['rssi'],
        super.fromMap();
}

class BmSetLogLevelRequest {
  LogLevel level;
  bool color;

  BmSetLogLevelRequest({
    this.level = LogLevel.none,
    this.color = true,
  });
}

class BmSetOptionsRequest {
  bool showPowerAlert;
  bool restoreState;

  BmSetOptionsRequest({
    required this.showPowerAlert,
    required this.restoreState,
  });

  Map<dynamic, dynamic> toMap() => {
        'show_power_alert': showPowerAlert,
        'restore_state': restoreState,
      };
}

enum BmConnectionPriorityEnum {
  balanced, // 0
  high, // 1
  lowPower, // 2
}

class BmConnectionPriorityRequest {
  final String address;
  final BmConnectionPriorityEnum connectionPriority;

  BmConnectionPriorityRequest({
    required this.address,
    required this.connectionPriority,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'connection_priority': connectionPriority.index,
      };
}

class BmPreferredPhy {
  final String address;
  final int txPhy;
  final int rxPhy;
  final int phyOptions;

  BmPreferredPhy({
    required this.address,
    required this.txPhy,
    required this.rxPhy,
    required this.phyOptions,
  });

  Map<dynamic, dynamic> toMap() => {
        'remote_id': address,
        'tx_phy': txPhy,
        'rx_phy': rxPhy,
        'phy_options': phyOptions,
      };

  BmPreferredPhy.fromMap(Map<dynamic, dynamic> json)
      : address = json['remote_id'],
        txPhy = json['tx_phy'],
        rxPhy = json['rx_phy'],
        phyOptions = json['phy_options'];
}

class BmPhySupportRequest {
  BmPhySupportRequest();
}

class BmPhySupport {
  /// High speed (PHY 2M)
  final bool le2M;

  /// Long range (PHY codec)
  final bool leCoded;

  BmPhySupport.empty()
      : le2M = false,
        leCoded = false;

  BmPhySupport.fromMap(Map<dynamic, dynamic> json)
      : le2M = json['le_2M'],
        leCoded = json['le_coded'];
}

class BmCreateBondRequest {
  String address;
  Uint8List? pin;

  BmCreateBondRequest({
    required this.address,
    required this.pin,
  });

  Map<dynamic, dynamic> toMap() {
    final Map<dynamic, dynamic> data = {};
    data['address'] = address;
    data['pin'] = pin;
    return data;
  }
}

class BmRemoveBondRequest {
  String address;

  BmRemoveBondRequest({
    required this.address,
  });
}

enum BmBondStateEnum {
  none, // 0
  bonding, // 1
  bonded, // 2
}

class BmBondStateRequest {
  String address;

  BmBondStateRequest({
    required this.address,
  });
}

class BmBondStateResponse {
  final String address;
  final BmBondStateEnum bondState;
  final BmBondStateEnum? prevState;

  BmBondStateResponse({
    required this.address,
    required this.bondState,
    this.prevState,
  });

  const BmBondStateResponse.empty(this.address)
      : bondState = BmBondStateEnum.none,
        prevState = null;

  BmBondStateResponse.fromMap(Map<dynamic, dynamic> json)
      : address = json['remote_id'],
        bondState = BmBondStateEnum.values[json['bond_state']],
        prevState = json['prev_state'] != null ? BmBondStateEnum.values[json['prev_state']] : null;
}

class BmDisconnectRequest {
  String address;

  BmDisconnectRequest({
    required this.address,
  });
}

class BmTurnOffRequest {
  BmTurnOffRequest();
}

class BmTurnOnRequest {
  BmTurnOnRequest();
}

// BmTurnOnResponse
class BmTurnOnResponse {
  final bool userAccepted;

  const BmTurnOnResponse({required this.userAccepted});

  BmTurnOnResponse.fromMap(Map<dynamic, dynamic> json) : userAccepted = json['user_accepted'] != 0;
}

class BmDetachedFromEngineResponse {
  BmDetachedFromEngineResponse();
}

// random number defined by flutter blue plus.
// Ideally it should not conflict with iOS or Android error codes.
int bmUserCanceledErrorCode = 23789258;
