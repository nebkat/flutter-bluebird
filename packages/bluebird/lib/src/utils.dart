import 'dart:async';
import 'dart:core';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluetooth_device.dart';
import 'bluetooth_utils.dart';
import 'bluebird.dart';

void ensurePlatform(bool valid, String function) {
  if (valid) return;
  throw BluebirdException(
    function,
    BluebirdErrorCode.platform,
    "Not supported on platform ${System.current}",
  );
}

extension FutureGuards<T> on Future<T> {
  Future<T> bluebirdTimeout(Duration timeout, String function) => this.timeout(timeout,
      onTimeout: () =>
          throw BluebirdException(function, BluebirdErrorCode.timeout, "Timed out after ${timeout.inSeconds}s"));

  /// Completes with [error] as soon as [fatal] emits an event matching
  /// [isFatal], unless this future completes first.
  Future<T> failOn<S>(Stream<S> fatal, bool Function(S event) isFatal, BluebirdException Function() error) {
    final completer = Completer<T>();
    final subscription = fatal.listen((event) {
      if (isFatal(event) && !completer.isCompleted) completer.completeError(error());
    });
    then((value) {
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }).whenComplete(subscription.cancel);
    return completer.future;
  }

  /// Fails with [BluebirdErrorCode.adapterOff] if the adapter turns off mid-flight.
  Future<T> bluebirdEnsureAdapterIsOn(String function) => failOn(
      Bluebird.adapterState,
      (s) => s == BluetoothAdapterState.off || s == BluetoothAdapterState.turningOff,
      () => BluebirdException(function, BluebirdErrorCode.adapterOff, "Bluetooth adapter is off"));

  /// Fails with [BluebirdErrorCode.deviceDisconnected] if [device] disconnects mid-flight.
  Future<T> bluebirdEnsureDeviceIsConnected(BluetoothDevice device, String function) => failOn(
      device.connectionState,
      (s) => s == BluetoothConnectionState.disconnected,
      () => BluebirdException(function, BluebirdErrorCode.deviceDisconnected, "Device is disconnected"));
}

// This is a reimplementation of BehaviorSubject from RxDart library.
// It is essentially a stream but:
//  1. we cache the latestValue of the stream
//  2. the "latestValue" is re-emitted whenever the stream is listened to
class StreamControllerReEmit<T> {
  T latestValue;

  final StreamController<T> _controller = StreamController<T>.broadcast();

  StreamControllerReEmit({required T initialValue}) : latestValue = initialValue;

  Stream<T> get stream => _controller.stream.newStreamWithInitialValue(latestValue);

  T get value => latestValue;

  void add(T newValue) {
    latestValue = newValue;
    _controller.add(newValue);
  }

  void addError(Object error) => _controller.addError(error);

  Future<void> close() => _controller.close();
}

extension StreamExtensions<T> on Stream<T> {
  /// See https://api.flutter.dev/flutter/package-async_async/StreamExtensions/listenAndBuffer.html
  Stream<T> listenAndBuffer() {
    final controller = StreamController<T>(sync: true);
    final subscription = listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
    return controller.stream;
  }
}

extension StreamNewStreamWithInitialValue<T> on Stream<T> {
  /// This stream with [initialValue] emitted first, to every listener.
  /// Broadcast-ness is preserved; the source is only subscribed while the
  /// returned stream has listeners.
  Stream<T> newStreamWithInitialValue(T initialValue) {
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    var listeners = 0;

    void onListen() {
      controller.add(initialValue);
      if (listeners++ == 0) {
        subscription = listen(controller.add, onError: controller.addError, onDone: controller.close);
      }
    }

    void onCancel() {
      if (--listeners == 0) {
        subscription?.cancel();
        controller.close();
      }
    }

    controller = isBroadcast
        ? StreamController<T>.broadcast(onListen: onListen, onCancel: onCancel)
        : StreamController<T>(
            onListen: onListen,
            onPause: () => subscription?.pause(),
            onResume: () => subscription?.resume(),
            onCancel: onCancel,
          );
    return controller.stream;
  }
}

// dart is single threaded, but still has task switching.
// this mutex lets a single task through at a time.
class Mutex {
  static final global = Mutex();
  static final scan = Mutex();
  static final disconnect = Mutex();
  static final platform = Mutex();

  final StreamController _controller = StreamController.broadcast();
  int execute = 0;
  int issued = 0;

  Future<void> take() async {
    int mine = issued;
    issued++;
    // tasks are executed in the same order they call take()
    while (mine != execute) {
      await _controller.stream.first; // wait
    }
  }

  void give() {
    execute++;
    _controller.add(null); // release waiting tasks
  }

  Future<T> protect<T>(FutureOr<T> Function() f) async {
    await take();
    try {
      // must await: `return f()` would run `finally` (releasing the mutex)
      // before the returned future completes
      return await f();
    } finally {
      give();
    }
  }
}

enum System {
  android,
  ios,
  linux,
  macos,
  windows,
  web;

  static System current = kIsWeb
      ? System.web
      : switch (Platform.operatingSystem) {
          'android' => System.android,
          'ios' => System.ios,
          'linux' => System.linux,
          'macos' => System.macos,
          'windows' => System.windows,
          _ => throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}'),
        };

  static bool get isWeb => current == System.web;
  static bool get isAndroid => current == System.android;
  static bool get isIOS => current == System.ios;
  static bool get isLinux => current == System.linux;
  static bool get isMacOS => current == System.macos;
  static bool get isWindows => current == System.windows;

  static bool get isDarwin => current == System.macos || current == System.ios;
  static bool get isMobile => current == System.android || current == System.ios;
  static bool get isDesktop => current == System.linux || current == System.macos || current == System.windows;
}
