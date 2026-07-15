import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:flutter/material.dart';

class ScanResultTile extends StatefulWidget {
  const ScanResultTile({Key? key, required this.result, this.onTap}) : super(key: key);

  final ScanResult result;
  final VoidCallback? onTap;

  @override
  State<ScanResultTile> createState() => _ScanResultTileState();
}

class _ScanResultTileState extends State<ScanResultTile> {
  late StreamSubscription<BluetoothConnectionState> _connectionStateSubscription;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription = widget.result.device.connectionState.listen((state) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    super.dispose();
  }

  String getNiceHexArray(List<int> bytes) {
    return '[${bytes.map((i) => i.toRadixString(16).padLeft(2, '0')).join(' ')}]'.toUpperCase();
  }

  String _hex16(int id) => '0x${id.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  // manufacturerData maps a 16-bit company id to its payload
  String getNiceManufacturerData(Map<int, List<int>> data) {
    return data.entries.map((e) => '${_hex16(e.key)} ${getNiceHexArray(e.value)}').join('\n');
  }

  String getNiceServiceData(Map<Uuid, List<int>> data) {
    return data.entries.map((v) => '${v.key} ${getNiceHexArray(v.value)}').join('\n').toUpperCase();
  }

  String getNiceServiceUuids(List<Uuid> serviceUuids) {
    return serviceUuids.join(', ').toUpperCase();
  }

  bool get isConnected => widget.result.device.isConnected;

  Widget _buildSignal(BuildContext context) {
    final rssi = widget.result.rssi;
    // map a rough usable range (~-100 dBm weak .. -40 dBm strong) to 0..1
    final strength = ((rssi + 100) / 60).clamp(0.0, 1.0);
    final color = strength > 0.6
        ? Colors.green
        : strength > 0.3
        ? Colors.orange
        : Colors.red;
    return SizedBox(
      width: 42,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$rssi', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: strength,
              minHeight: 5,
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    // prefer the platform name, but fall back to the advertised name,
    // so un-connected devices still show a name in the list
    final name = widget.result.device.platformName.isNotEmpty
        ? widget.result.device.platformName
        : widget.result.advertisementData.advName;
    if (name.isNotEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(name, overflow: TextOverflow.ellipsis),
          Text(widget.result.device.remoteId, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    } else {
      return Text(widget.result.device.remoteId);
    }
  }

  Widget _buildConnectButton(BuildContext context) {
    return ElevatedButton(
      child: isConnected ? const Text('OPEN') : const Text('CONNECT'),
      style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
      onPressed: (widget.result.advertisementData.connectable) ? widget.onTap : null,
    );
  }

  Widget _buildAdvRow(BuildContext context, String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // fixed-width label column so all values align
          SizedBox(width: 120.0, child: Text(title, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(width: 12.0),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.apply(color: Colors.black),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var adv = widget.result.advertisementData;
    return ExpansionTile(
      title: _buildTitle(context),
      leading: _buildSignal(context),
      trailing: _buildConnectButton(context),
      children: <Widget>[
        _buildAdvRow(context, 'Remote ID', widget.result.device.remoteId),
        _buildAdvRow(context, 'RSSI', '${widget.result.rssi} dBm'),
        _buildAdvRow(context, 'Connectable', adv.connectable ? 'Yes' : 'No'),
        if (adv.advName.isNotEmpty) _buildAdvRow(context, 'Name', adv.advName),
        if (adv.txPowerLevel != null) _buildAdvRow(context, 'Tx Power Level', '${adv.txPowerLevel} dBm'),
        if ((adv.appearance ?? 0) > 0) _buildAdvRow(context, 'Appearance', '0x${adv.appearance!.toRadixString(16)}'),
        if (adv.manufacturerData.isNotEmpty)
          _buildAdvRow(context, 'Manufacturer Data', getNiceManufacturerData(adv.manufacturerData)),
        if (adv.serviceUuids.isNotEmpty) _buildAdvRow(context, 'Service UUIDs', getNiceServiceUuids(adv.serviceUuids)),
        if (adv.serviceData.isNotEmpty) _buildAdvRow(context, 'Service Data', getNiceServiceData(adv.serviceData)),
      ],
    );
  }
}
