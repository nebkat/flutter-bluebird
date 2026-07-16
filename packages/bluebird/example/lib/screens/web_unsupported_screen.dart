// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/material.dart';

/// Shown on web when the browser can't do Web Bluetooth. The plugin reports
/// this as [BluetoothAdapterState.unavailable] — `navigator.bluetooth` is
/// absent (Firefox/Safari, or a Chromium browser with the feature disabled) or
/// blocked (non-HTTPS origin, permissions policy).
class WebUnsupportedScreen extends StatelessWidget {
  const WebUnsupportedScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Center(child: Image.asset('assets/bluebird.png', height: 140)),
                const SizedBox(height: 24),
                Icon(
                  Icons.bluetooth_disabled,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  "Web Bluetooth isn't available here",
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'This demo needs the Web Bluetooth API, which is only supported '
                  'in Chromium-based browsers — Chrome, Edge, or Opera — served '
                  'over HTTPS.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Firefox and Safari do not support it.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
