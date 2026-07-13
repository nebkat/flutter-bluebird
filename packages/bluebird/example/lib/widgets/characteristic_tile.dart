import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:bluebird/bluebird.dart';

import "../utils/snackbar.dart";

import "descriptor_tile.dart";

/// Well-known characteristics whose value is a human-readable UTF-8 string
/// (the Device Information Service strings, plus Device Name).
final _textCharacteristics = <Uuid>{
  Uuids.characteristic.deviceName,
  Uuids.characteristic.modelNumber,
  Uuids.characteristic.serialNumber,
  Uuids.characteristic.firmwareRevision,
  Uuids.characteristic.hardwareRevision,
  Uuids.characteristic.softwareRevision,
  Uuids.characteristic.manufacturerName,
};

class CharacteristicTile extends StatefulWidget {
  final BluetoothCharacteristic characteristic;
  final List<DescriptorTile> descriptorTiles;

  const CharacteristicTile({Key? key, required this.characteristic, required this.descriptorTiles}) : super(key: key);

  @override
  State<CharacteristicTile> createState() => _CharacteristicTileState();
}

class _CharacteristicTileState extends State<CharacteristicTile> {
  List<int> _value = [];

  // the human-readable name from the 0x2901 descriptor, if any
  String? _name;

  // non-null while subscribed to notify/indicate
  StreamSubscription<List<int>>? _notifySubscription;

  bool get _isNotifying => _notifySubscription != null;

  @override
  void initState() {
    super.initState();
    _readName();
  }

  @override
  void dispose() {
    _notifySubscription?.cancel();
    super.dispose();
  }

  BluetoothCharacteristic get c => widget.characteristic;

  /// Reads the Characteristic User Description (0x2901), if present, to show a
  /// friendly name in place of the bare UUID. Best-effort — ignored on failure.
  Future<void> _readName() async {
    final descriptor = c.descriptors.where((d) => d.uuid == Uuids.descriptor.characteristicUserDescription).firstOrNull;
    if (descriptor == null) return;
    try {
      final name = utf8.decode(await descriptor.read()).trim();
      if (mounted && name.isNotEmpty) setState(() => _name = name);
    } catch (_) {
      // not readable — leave the UUID as the title
    }
  }

  void _setValue(List<int> value) {
    if (!mounted) return;
    setState(() => _value = value);
  }

  List<int> _getRandomBytes() {
    final math = Random();
    return [math.nextInt(255), math.nextInt(255), math.nextInt(255), math.nextInt(255)];
  }

  Future onReadPressed() async {
    try {
      _setValue(await c.read());
      Snackbar.show(ABC.c, "Read: Success", success: true);
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Read Error:", e), success: false);
      print(e);
    }
  }

  Future onWritePressed() async {
    try {
      await c.write(_getRandomBytes(), withoutResponse: c.properties.writeWithoutResponse);
      Snackbar.show(ABC.c, "Write: Success", success: true);
      if (c.properties.read) {
        _setValue(await c.read());
      }
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Write Error:", e), success: false);
      print(e);
    }
  }

  Future onSubscribePressed() async {
    try {
      if (_isNotifying) {
        await _notifySubscription!.cancel(); // cancelling disables notify
        _notifySubscription = null;
        Snackbar.show(ABC.c, "Unsubscribe: Success", success: true);
      } else {
        // listening enables notify/indicate; each value updates the display.
        // onError surfaces a failed setNotifyValue (e.g. the peripheral rejects
        // the CCCD write) instead of letting it escape as an unhandled error.
        _notifySubscription = c.notifications.listen(
          _setValue,
          onError: (e) => Snackbar.show(ABC.c, prettyException("Subscribe Error:", e), success: false),
        );
        Snackbar.show(ABC.c, "Subscribe: Success", success: true);
      }
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Subscribe Error:", e), success: false);
      print(e);
    }
  }

  Widget buildUuid(BuildContext context) {
    String uuid = '0x${widget.characteristic.uuid.string.toUpperCase()}';
    return Text(uuid, style: TextStyle(fontSize: 13));
  }

  Widget buildValue(BuildContext context) {
    String data = _value.toString();
    // render known string characteristics (device info, name) as text
    if (_value.isNotEmpty && _textCharacteristics.contains(c.uuid)) {
      try {
        data = '"${utf8.decode(_value)}"';
      } catch (_) {
        // not valid UTF-8 — fall back to the byte view
      }
    }
    return Text(data, style: TextStyle(fontSize: 13, color: Colors.grey));
  }

  Widget buildReadButton(BuildContext context) {
    return TextButton(
        child: Text("Read"),
        onPressed: () async {
          await onReadPressed();
          if (mounted) {
            setState(() {});
          }
        });
  }

  Widget buildWriteButton(BuildContext context) {
    bool withoutResp = widget.characteristic.properties.writeWithoutResponse;
    return TextButton(
        child: Text(withoutResp ? "WriteNoResp" : "Write"),
        onPressed: () async {
          await onWritePressed();
          if (mounted) {
            setState(() {});
          }
        });
  }

  Widget buildSubscribeButton(BuildContext context) {
    return TextButton(
        child: Text(_isNotifying ? "Unsubscribe" : "Subscribe"),
        onPressed: () async {
          await onSubscribePressed();
          if (mounted) {
            setState(() {});
          }
        });
  }

  Widget buildButtonRow(BuildContext context) {
    bool read = widget.characteristic.properties.read;
    bool write = widget.characteristic.properties.write;
    bool notify = widget.characteristic.properties.notify;
    bool indicate = widget.characteristic.properties.indicate;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (read) buildReadButton(context),
        if (write) buildWriteButton(context),
        if (notify || indicate) buildSubscribeButton(context),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: ListTile(
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // the device's own 0x2901 name, else the well-known assigned name
            Text(_name ?? c.uuid.name ?? 'Characteristic'),
            buildUuid(context),
            buildValue(context),
          ],
        ),
        subtitle: buildButtonRow(context),
        contentPadding: const EdgeInsets.all(0.0),
      ),
      children: widget.descriptorTiles,
    );
  }
}
