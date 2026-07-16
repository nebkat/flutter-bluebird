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
import 'screens/web_unsupported_screen.dart';
import 'utils/snackbar.dart';

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
        final Widget screen;
        if (adapterState == BluetoothAdapterState.on) {
          screen = kIsWeb ? const WebScanScreen() : const ScanScreen();
        } else if (kIsWeb && adapterState == BluetoothAdapterState.unavailable) {
          // On web `unavailable` means the browser can't do Web Bluetooth, not
          // that an adapter is switched off - send them to the right message
          screen = const WebUnsupportedScreen();
        } else {
          screen = BluetoothOffScreen(adapterState: adapterState);
        }

        return MaterialApp(
          title: 'bluebird',
          theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
          ),
          // follow the OS light/dark setting
          themeMode: ThemeMode.system,
          scaffoldMessengerKey: Snackbar.messengerKey,
          home: screen,
        );
      },
    );
  }
}
