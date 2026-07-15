// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:bluebird/bluebird.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'screens/bluetooth_off_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/web_scan_screen.dart';

void main() {
  // TODO Bluebird.setLogLevel(LogLevel.verbose, color: true);
  runApp(const BluebirdApp());
}

class BluebirdApp extends StatelessWidget {
  const BluebirdApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // adapterState emits its current value first, then changes, so StreamBuilder
    // tracks it without any StatefulWidget boilerplate; initialData just covers
    // the frame before that first value arrives.
    return StreamBuilder<BluetoothAdapterState>(
      stream: Bluebird.adapterState,
      initialData: BluetoothAdapterState.unknown,
      builder: (context, snapshot) {
        final adapterState = snapshot.data ?? BluetoothAdapterState.unknown;
        final Widget screen = adapterState == BluetoothAdapterState.on
            ? (kIsWeb ? const WebScanScreen() : const ScanScreen())
            : BluetoothOffScreen(adapterState: adapterState);

        return MaterialApp(color: Colors.lightBlue, home: screen);
      },
    );
  }
}
