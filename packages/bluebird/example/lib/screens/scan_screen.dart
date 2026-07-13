import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bluebird/bluebird.dart';

import 'device_screen.dart';
import '../utils/snackbar.dart';
import '../widgets/system_device_tile.dart';
import '../widgets/scan_result_tile.dart';
import '../utils/extra.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({Key? key}) : super(key: key);

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<BluetoothDevice> _systemDevices = [];
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;

  /// The active scan; cancelling it stops scanning.
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  Timer? _scanTimeout;
  late StreamSubscription<bool> _isScanningSubscription;

  @override
  void initState() {
    super.initState();

    _isScanningSubscription = Bluebird.isScanning.listen((state) {
      _isScanning = state;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _scanTimeout?.cancel();
    _scanSubscription?.cancel();
    _isScanningSubscription.cancel();
    super.dispose();
  }

  /// Starts a scan for [timeout], accumulating results into [_scanResults].
  void _startScan({Duration timeout = const Duration(seconds: 15)}) {
    _scanSubscription?.cancel();
    _scanResults = [];
    _scanSubscription = Bluebird.scan().accumulate().listen((results) {
      _scanResults = results;
      if (mounted) setState(() {});
    }, onError: (e) {
      Snackbar.show(ABC.b, prettyException("Scan Error:", e), success: false);
    });
    _scanTimeout?.cancel();
    _scanTimeout = Timer(timeout, () => _scanSubscription?.cancel());
  }

  Future onScanPressed() async {
    try {
      // `withServices` is required on iOS for privacy purposes, ignored on android.
      var withServices = [Uuid("180f")]; // Battery Level Service
      _systemDevices = await Bluebird.systemDevices(withServices);
    } catch (e) {
      Snackbar.show(ABC.b, prettyException("System Devices Error:", e), success: false);
      print(e);
    }
    try {
      _startScan();
    } catch (e) {
      Snackbar.show(ABC.b, prettyException("Start Scan Error:", e), success: false);
      print(e);
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future onStopPressed() async {
    try {
      await _scanSubscription?.cancel();
    } catch (e) {
      Snackbar.show(ABC.b, prettyException("Stop Scan Error:", e), success: false);
      print(e);
    }
  }

  Future onConnectPressed(BluetoothDevice device) async {
    try {
      await device.connectAndUpdateStream();
    } catch (e) {
      // connection failed — surface the error and stay on the scan page
      Snackbar.show(ABC.c, prettyException("Connect Error:", e), success: false);
      return;
    }
    if (!mounted) return;
    MaterialPageRoute route = MaterialPageRoute(
        builder: (context) => DeviceScreen(device: device), settings: RouteSettings(name: '/DeviceScreen'));
    Navigator.of(context).push(route);
  }

  Future onRefresh() {
    if (_isScanning == false) {
      _startScan();
    }
    if (mounted) {
      setState(() {});
    }
    return Future.delayed(Duration(milliseconds: 500));
  }

  Widget buildScanButton(BuildContext context) {
    final scanning = Bluebird.isScanning.value;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        icon: Icon(scanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(scanning ? 'Stop' : 'Scan'),
        style: scanning ? FilledButton.styleFrom(backgroundColor: Colors.red) : null,
        onPressed: scanning ? onStopPressed : onScanPressed,
      ),
    );
  }

  List<Widget> _buildSystemDeviceTiles(BuildContext context) {
    return _systemDevices
        .map(
          (d) => SystemDeviceTile(
            device: d,
            onOpen: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => DeviceScreen(device: d),
                settings: RouteSettings(name: '/DeviceScreen'),
              ),
            ),
            onConnect: () => onConnectPressed(d),
          ),
        )
        .toList();
  }

  List<Widget> _buildScanResultTiles(BuildContext context) {
    return _scanResults
        .map(
          (r) => ScanResultTile(
            result: r,
            onTap: () => onConnectPressed(r.device),
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: Snackbar.snackBarKeyB,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bluebird'),
        ),
        body: RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            children: <Widget>[
              ..._buildSystemDeviceTiles(context),
              ..._buildScanResultTiles(context),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: buildScanButton(context),
          ),
        ),
      ),
    );
  }
}
