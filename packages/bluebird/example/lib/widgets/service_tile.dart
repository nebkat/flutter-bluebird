import 'package:flutter/material.dart';
import 'package:bluebird/bluebird.dart';

import "../utils/assigned_numbers.dart";

import "characteristic_tile.dart";

class ServiceTile extends StatelessWidget {
  final BluetoothService service;
  final List<CharacteristicTile> characteristicTiles;

  const ServiceTile({Key? key, required this.service, required this.characteristicTiles}) : super(key: key);

  Widget buildUuid(BuildContext context) {
    return Text(service.uuid.hex, style: Theme.of(context).textTheme.bodySmall);
  }

  @override
  Widget build(BuildContext context) {
    // show the SIG assigned name if the uuid is in the registry, else a generic
    // label — a vendor service has no name we could know
    final name = service.uuid.assignedName ?? 'Unknown Service';
    return characteristicTiles.isNotEmpty
        ? ExpansionTile(
            title: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[Text(name), buildUuid(context)],
            ),
            children: characteristicTiles,
          )
        : ListTile(title: Text(name), subtitle: buildUuid(context));
  }
}
