import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:flutter/material.dart';

import '../utils/assigned_numbers.dart';

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

  // manufacturerData maps a 16-bit company id to its payload; the label appends
  // the SIG company name when the id is a known assigned number
  String getNiceManufacturerData(Map<int, List<int>> data) {
    return data.entries.map((e) => '${AssignedNumbers.companyLabel(e.key)} ${getNiceHexArray(e.value)}').join('\n');
  }

  String getNiceServiceData(Map<Uuid, List<int>> data) {
    return data.entries.map((e) => '${e.key.labelled} ${getNiceHexArray(e.value)}').join('\n');
  }

  // one per line: the assigned names (which for a member UUID is the company
  // that owns it) are long enough that a comma-separated list wraps badly
  String getNiceServiceUuids(List<Uuid> serviceUuids) {
    return serviceUuids.map((uuid) => uuid.labelled).join('\n');
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

  /// Who the advertisement says is behind the device, if anything says so: the
  /// SIG company name for the manufacturer id, otherwise the raw id (so a device
  /// with an unassigned id still shows *something*).
  ///
  /// Failing that — no manufacturer-specific data at all — a proprietary service
  /// UUID stands in: a member-range UUID is allocated to one SIG member, so its
  /// assigned name *is* the company that owns the service.
  String? _manufacturer() {
    final adv = widget.result.advertisementData;
    if (adv.manufacturerData.isNotEmpty) {
      final id = adv.manufacturerData.keys.first; // the expanded row lists all; this is the summary
      return AssignedNumbers.companyName(id) ?? AssignedNumbers.hex16(id);
    }
    for (final uuid in [...adv.serviceUuids, ...adv.serviceData.keys]) {
      if (uuid.assignedRegistry == UuidRegistry.member) return uuid.assignedName;
    }
    return null;
  }

  Widget _buildTitle(BuildContext context) {
    // prefer the platform name, but fall back to the advertised name; most
    // devices advertise no name at all, so show a muted "Unknown" placeholder
    final advertisedName = widget.result.device.platformName.isNotEmpty
        ? widget.result.device.platformName
        : widget.result.advertisementData.advName ?? '';
    final hasName = advertisedName.isNotEmpty;
    final manufacturer = _manufacturer();
    final bodySmall = Theme.of(context).textTheme.bodySmall;

    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                hasName ? advertisedName : 'Unknown',
                overflow: TextOverflow.ellipsis,
                style: hasName ? null : TextStyle(color: Theme.of(context).hintColor, fontStyle: FontStyle.italic),
              ),
            ),
            if (manufacturer != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '· $manufacturer',
                  overflow: TextOverflow.ellipsis,
                  style: bodySmall?.copyWith(color: Theme.of(context).hintColor),
                ),
              ),
            ],
          ],
        ),
        Text(widget.result.device.remoteId, style: bodySmall),
      ],
    );
  }

  Widget _buildConnectButton(BuildContext context) {
    final onPressed = widget.result.advertisementData.connectable ? widget.onTap : null;
    // primary filled to connect; outlined (lighter) to open once connected
    return isConnected
        ? OutlinedButton(onPressed: onPressed, child: const Text('OPEN'))
        : FilledButton(onPressed: onPressed, child: const Text('CONNECT'));
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
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodySmall, softWrap: true)),
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
        if (adv.advName?.isNotEmpty ?? false) _buildAdvRow(context, 'Name', adv.advName!),
        if (adv.txPowerLevel != null) _buildAdvRow(context, 'Tx Power Level', '${adv.txPowerLevel} dBm'),
        if ((adv.appearance ?? 0) > 0)
          _buildAdvRow(context, 'Appearance', AssignedNumbers.appearanceLabel(adv.appearance!)),
        if (adv.manufacturerData.isNotEmpty)
          _buildAdvRow(context, 'Manufacturer Data', getNiceManufacturerData(adv.manufacturerData)),
        if (adv.serviceUuids.isNotEmpty) _buildAdvRow(context, 'Service UUIDs', getNiceServiceUuids(adv.serviceUuids)),
        if (adv.serviceData.isNotEmpty) _buildAdvRow(context, 'Service Data', getNiceServiceData(adv.serviceData)),
      ],
    );
  }
}
