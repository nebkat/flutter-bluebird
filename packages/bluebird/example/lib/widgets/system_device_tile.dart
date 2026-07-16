import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:flutter/material.dart';

class SystemDeviceTile extends StatefulWidget {
  final BluetoothDevice device;
  final VoidCallback onOpen;
  final VoidCallback onConnect;

  const SystemDeviceTile({
    required this.device,
    required this.onOpen,
    required this.onConnect,
    Key? key,
  }) : super(key: key);

  @override
  State<SystemDeviceTile> createState() => _SystemDeviceTileState();
}

class _SystemDeviceTileState extends State<SystemDeviceTile> {
  late StreamSubscription<BluetoothConnectionState>
  _connectionStateSubscription;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription = widget.device.connectionState.listen((
      state,
    ) {
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

  bool get isConnected => widget.device.isConnected;

  Widget _buildField(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120.0,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 12.0),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // An ExpansionTile (like ScanResultTile) so the row is hoverable and can
    // reveal the few fields a system device has.
    return ExpansionTile(
      // same 42px width as ScanResultTile's RSSI widget, so the columns align;
      // a system device has no advertisement/RSSI, so show a "system" icon instead
      leading: SizedBox(
        width: 42,
        child: Center(
          child: Tooltip(
            message:
                'System device (connected via the OS, not discovered by scanning)',
            child: const Icon(Icons.settings_bluetooth),
          ),
        ),
      ),
      title: Text(widget.device.platformName),
      subtitle: Text(widget.device.remoteId),
      // tonal connect (lesser than a scanned device's primary), outlined open
      trailing: isConnected
          ? OutlinedButton(onPressed: widget.onOpen, child: const Text('OPEN'))
          : FilledButton.tonal(
              onPressed: widget.onConnect,
              child: const Text('CONNECT'),
            ),
      children: <Widget>[
        _buildField(context, 'Remote ID', widget.device.remoteId),
        if (widget.device.platformName.isNotEmpty)
          _buildField(context, 'Name', widget.device.platformName),
        _buildField(
          context,
          'Status',
          isConnected ? 'Connected' : 'Not connected to this app',
        ),
        if (isConnected)
          _buildField(context, 'MTU', '${widget.device.mtu.value} bytes'),
        _buildField(
          context,
          'Note',
          'System device — connected via the OS, so it has no advertisement/RSSI data.',
        ),
      ],
    );
  }
}
