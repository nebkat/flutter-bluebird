import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bluebird/bluebird.dart';

class Snackbar {
  /// The app's single messenger. Wire it into the root:
  /// `MaterialApp(scaffoldMessengerKey: Snackbar.messengerKey, ...)`.
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static void show(String msg, {required bool success}) {
    final snackBar = SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.blue : Colors.red,
    );
    messengerKey.currentState
      ?..removeCurrentSnackBar()
      ..showSnackBar(snackBar);
  }
}

String prettyException(String prefix, dynamic e) {
  if (e is BluebirdException) {
    return "$prefix ${e.description}${e.details != null ? ' [${e.details}]' : ''}";
  } else if (e is PlatformException) {
    return "$prefix ${e.message}";
  }
  return prefix + e.toString();
}
