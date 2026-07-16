import 'dart:async';
import 'dart:io';

import 'package:bluebird/bluebird.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/extra.dart';
import '../utils/snackbar.dart';
import '../widgets/characteristic_tile.dart';
import '../widgets/descriptor_tile.dart';
import '../widgets/service_tile.dart';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;

  const DeviceScreen({Key? key, required this.device}) : super(key: key);

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  int? _rssi;
  int? _mtuSize;
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> get _services => widget.device.services;
  bool _isDiscoveringServices = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;

  late StreamSubscription<BluetoothConnectionState> _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;
  late StreamSubscription<bool> _isDisconnectingSubscription;
  late StreamSubscription<int> _mtuSubscription;
  late StreamSubscription<BluetoothAdapterState> _adapterStateSubscription;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription = widget.device.connectionState.listen((state) async {
      _connectionState = state;
      // web can't read RSSI after connecting, so don't try
      if (!kIsWeb && state == BluetoothConnectionState.connected && _rssi == null) {
        _rssi = await widget.device.readRssi();
      }
      if (mounted) {
        setState(() {});
      }
    });

    _mtuSubscription = widget.device.mtu.listen((value) {
      _mtuSize = value;
      if (mounted) {
        setState(() {});
      }
    });

    _isConnectingSubscription = widget.device.isConnecting.listen((value) {
      _isConnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    _isDisconnectingSubscription = widget.device.isDisconnecting.listen((value) {
      _isDisconnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    // this screen requires Bluetooth; dismiss it if the adapter is turned off
    _adapterStateSubscription = Bluebird.adapterState.listen((state) {
      if (state != BluetoothAdapterState.on && mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _mtuSubscription.cancel();
    _isConnectingSubscription.cancel();
    _isDisconnectingSubscription.cancel();
    _adapterStateSubscription.cancel();
    super.dispose();
  }

  bool get isConnected {
    return _connectionState == BluetoothConnectionState.connected;
  }

  Future onConnectPressed() async {
    try {
      await widget.device.connectAndUpdateStream();
      Snackbar.show("Connect: Success", success: true);
    } catch (e) {
      if (e is BluebirdException && e.code == BluebirdErrorCode.userCanceled.index) {
        // ignore connections canceled by the user
      } else {
        Snackbar.show(prettyException("Connect Error:", e), success: false);
        print(e);
      }
    }
  }

  Future onCancelPressed() async {
    try {
      await widget.device.disconnectAndUpdateStream(queue: false);
      Snackbar.show("Cancel: Success", success: true);
    } catch (e) {
      Snackbar.show(prettyException("Cancel Error:", e), success: false);
      print(e);
    }
  }

  Future onDisconnectPressed() async {
    try {
      await widget.device.disconnectAndUpdateStream();
      Snackbar.show("Disconnect: Success", success: true);
    } catch (e) {
      Snackbar.show(prettyException("Disconnect Error:", e), success: false);
      print(e);
    }
  }

  Future onDiscoverServicesPressed() async {
    if (mounted) {
      setState(() {
        _isDiscoveringServices = true;
      });
    }
    try {
      await widget.device.discoverServices();
      Snackbar.show("Discover services: Success", success: true);
    } catch (e) {
      Snackbar.show(prettyException("Discover services: Error:", e), success: false);
      print(e);
    }
    if (mounted) {
      setState(() {
        _isDiscoveringServices = false;
      });
    }
  }

  Future onRequestMtuPressed() async {
    try {
      await widget.device.requestMtu(223, predelay: Duration.zero);
      Snackbar.show("Request Mtu: Success", success: true);
    } catch (e) {
      Snackbar.show(prettyException("Change Mtu Error:", e), success: false);
      print(e);
    }
  }

  List<Widget> _buildServiceTiles(BuildContext context, BluetoothDevice d) {
    return _services
        .map(
          (s) => ServiceTile(
            service: s,
            characteristicTiles: s.characteristics.map((c) => _buildCharacteristicTile(c)).toList(),
          ),
        )
        .toList();
  }

  CharacteristicTile _buildCharacteristicTile(BluetoothCharacteristic c) {
    return CharacteristicTile(
      characteristic: c,
      descriptorTiles: c.descriptors.map((d) => DescriptorTile(descriptor: d)).toList(),
    );
  }

  // Same signal presentation as the scan page: a dBm reading over a colored
  // strength bar. When not connected there's no live RSSI, so show an empty
  // grey bar and a "disconnected" icon.
  Widget _buildRssiBar(BuildContext context) {
    final rssi = _rssi;
    final live = isConnected && rssi != null;
    final strength = live ? ((rssi + 100) / 60).clamp(0.0, 1.0) : 0.0;
    final color = !live
        ? Colors.grey
        : strength > 0.6
        ? Colors.green
        : strength > 0.3
        ? Colors.orange
        : Colors.red;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: isConnected ? Colors.blue : Colors.grey,
        ),
        // web can't read RSSI post-connection, so show only the icon there
        if (!kIsWeb) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // only show a reading while connected; otherwise just the bar
                if (live) ...[
                  Text('$rssi dBm', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 4),
                ],
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: strength,
                    minHeight: 6,
                    backgroundColor: Colors.grey.shade300,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          _buildRssiBar(context),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.device.remoteId, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  isConnected ? 'Connected' : 'Disconnected',
                  style: TextStyle(color: isConnected ? Colors.green : Colors.grey, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final busy = _isConnecting || _isDisconnecting;
    Widget spinner() => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              icon: busy ? spinner() : Icon(isConnected ? Icons.link_off : Icons.link),
              label: Text(_isConnecting ? 'Cancel' : (isConnected ? 'Disconnect' : 'Connect')),
              // destructive: error colors keep the label readable in light/dark
              style: isConnected
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              onPressed: _isConnecting ? onCancelPressed : (isConnected ? onDisconnectPressed : onConnectPressed),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: _isDiscoveringServices ? spinner() : const Icon(Icons.search),
              label: const Text('Get Services'),
              onPressed: (isConnected && !_isDiscoveringServices) ? onDiscoverServicesPressed : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildMtuTile(BuildContext context) {
    return ListTile(
      title: const Text('MTU Size'),
      subtitle: Text('$_mtuSize bytes'),
      // requestMtu is only supported on Android; other platforms
      // negotiate the MTU automatically
      trailing: (!kIsWeb && Platform.isAndroid)
          ? IconButton(icon: const Icon(Icons.edit), onPressed: onRequestMtuPressed)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.device.platformName.isNotEmpty ? widget.device.platformName : 'Unknown';
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(context),
            const SizedBox(height: 8),
            _buildActions(context),
            const Divider(height: 24),
            buildMtuTile(context),
            ..._buildServiceTiles(context, widget.device),
          ],
        ),
      ),
    );
  }
}
