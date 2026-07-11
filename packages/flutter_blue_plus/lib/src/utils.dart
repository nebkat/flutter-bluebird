import 'dart:async';
import 'dart:core';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_device.dart';
import 'bluetooth_utils.dart';
import 'flutter_blue_plus.dart';

List<int> hexDecode(String hex) {
  List<int> numbers = [];
  for (int i = 0; i < hex.length; i += 2) {
    String hexPart = hex.substring(i, i + 2);
    int num = int.parse(hexPart, radix: 16);
    numbers.add(num);
  }
  return numbers;
}

void ensurePlatform(bool valid, String function) {
  if (valid) return;
  throw FlutterBluePlusException(
    function,
    FbpErrorCode.platform,
    "Not supported on platform ${System.current}",
  );
}

extension FutureTimeout<T> on Future<T> {
  Future<T> fbpTimeout(Duration timeout, String function) {
    return this.timeout(timeout, onTimeout: () {
      throw FlutterBluePlusException(
        function,
        FbpErrorCode.timeout,
        "Timed out after ${timeout.inSeconds}s",
      );
    });
  }

  Future<T> fbpEnsureDeviceIsConnected(BluetoothDevice device, String function) {
    // Create a completer to represent the result of this extended Future.
    var completer = Completer<T>();

    // disconnection listener.
    var subscription = device.connectionState.listen((event) {
      if (event == BluetoothConnectionState.disconnected) {
        if (!completer.isCompleted) {
          completer.completeError(
            FlutterBluePlusException(function, FbpErrorCode.deviceDisconnected, "Device is disconnected"),
          );
        }
      }
    });

    // When the original future completes
    // complete our completer and cancel the subscription.
    then((value) {
      if (!completer.isCompleted) {
        subscription.cancel();
        completer.complete(value);
      }
    }).catchError((error) {
      if (!completer.isCompleted) {
        subscription.cancel();
        completer.completeError(error);
      }
    });

    return completer.future;
  }

  Future<T> fbpEnsureAdapterIsOn(String function) {
    // Create a completer to represent the result of this extended Future.
    var completer = Completer<T>();

    // disconnection listener.
    var subscription = FlutterBluePlus.adapterState.listen((event) {
      if (event == BluetoothAdapterState.off || event == BluetoothAdapterState.turningOff) {
        if (!completer.isCompleted) {
          completer.completeError(FlutterBluePlusException(
            function,
            FbpErrorCode.adapterOff,
            "Bluetooth adapter is off",
          ));
        }
      }
    });

    // When the original future completes
    // complete our completer and cancel the subscription.
    then((value) {
      if (!completer.isCompleted) {
        subscription.cancel();
        completer.complete(value);
      }
    }).catchError((error) {
      if (!completer.isCompleted) {
        subscription.cancel();
        completer.completeError(error);
      }
    });

    return completer.future;
  }
}

// This is a reimplementation of BehaviorSubject from RxDart library.
// It is essentially a stream but:
//  1. we cache the latestValue of the stream
//  2. the "latestValue" is re-emitted whenever the stream is listened to
class StreamControllerReEmit<T> {
  T latestValue;

  final StreamController<T> _controller = StreamController<T>.broadcast();

  StreamControllerReEmit({required T initialValue}) : latestValue = initialValue;

  Stream<T> get stream {
    if (latestValue != null) {
      return _controller.stream.newStreamWithInitialValue(latestValue!);
    } else {
      return _controller.stream;
    }
  }

  T get value => latestValue;

  void add(T newValue) {
    latestValue = newValue;
    _controller.add(newValue);
  }

  void addError(Object error) {
    _controller.addError(error);
  }

  void listen(Function(T) onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    onData(latestValue);
    _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  Future<void> close() {
    return _controller.close();
  }
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

// Helper for 'newStreamWithInitialValue' method for streams.
class _NewStreamWithInitialValueTransformer<T> extends StreamTransformerBase<T, T> {
  /// the initial value to push to the new stream
  final T initialValue;

  /// controller for the new stream
  late StreamController<T> controller;

  /// subscription to the original stream
  late StreamSubscription<T> subscription;

  /// new stream listener count
  var listenerCount = 0;

  _NewStreamWithInitialValueTransformer(this.initialValue);

  @override
  Stream<T> bind(Stream<T> stream) {
    if (stream.isBroadcast) {
      return _bind(stream, broadcast: true);
    } else {
      return _bind(stream);
    }
  }

  Stream<T> _bind(Stream<T> stream, {bool broadcast = false}) {
    /////////////////////////////////////////
    /// Original Stream Subscription Callbacks
    ///

    /// When the original stream emits data, forward it to our new stream
    void onData(T data) {
      controller.add(data);
    }

    /// When the original stream is done, close our new stream
    void onDone() {
      controller.close();
    }

    /// When the original stream has an error, forward it to our new stream
    void onError(Object error) {
      controller.addError(error);
    }

    /// When a client listens to our new stream, emit the
    /// initial value and subscribe to original stream if needed
    void onListen() {
      // Emit the initial value to our new stream
      controller.add(initialValue);

      // listen to the original stream, if needed
      if (listenerCount == 0) {
        subscription = stream.listen(
          onData,
          onError: onError,
          onDone: onDone,
        );
      }

      // count listeners of the new stream
      listenerCount++;
    }

    //////////////////////////////////////
    ///  New Stream Controller Callbacks
    ///

    /// (Single Subscription Only) When a client pauses
    /// the new stream, pause the original stream
    void onPause() {
      subscription.pause();
    }

    /// (Single Subscription Only) When a client resumes
    /// the new stream, resume the original stream
    void onResume() {
      subscription.resume();
    }

    /// Called when a client cancels their
    /// subscription to the new stream,
    void onCancel() {
      // count listeners of the new stream
      listenerCount--;

      // when there are no more listeners of the new stream,
      // cancel the subscription to the original stream,
      // and close the new stream controller
      if (listenerCount == 0) {
        subscription.cancel();
        controller.close();
      }
    }

    //////////////////////////////////////
    /// Return New Stream
    ///

    // create a new stream controller
    if (broadcast) {
      controller = StreamController<T>.broadcast(
        onListen: onListen,
        onCancel: onCancel,
      );
    } else {
      controller = StreamController<T>(
        onListen: onListen,
        onPause: onPause,
        onResume: onResume,
        onCancel: onCancel,
      );
    }

    return controller.stream;
  }
}

extension StreamNewStreamWithInitialValue<T> on Stream<T> {
  Stream<T> newStreamWithInitialValue(T initialValue) {
    return transform(_NewStreamWithInitialValueTransformer(initialValue));
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
