// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io' show Platform;

import 'utils.dart' show System;

System get currentSystem {
  if (Platform.isAndroid) return System.android;
  if (Platform.isIOS) return System.ios;
  if (Platform.isMacOS) return System.macos;
  if (Platform.isLinux) return System.linux;
  if (Platform.isWindows) return System.windows;
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}
