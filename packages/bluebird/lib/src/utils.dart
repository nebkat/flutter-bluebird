import 'dart:async';
import 'dart:core';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'bluebird.dart';
import 'bluetooth_device.dart';
// `dart:io` is native-only; the web variant keeps it out of the web/wasm build.
import 'platform_web.dart' if (dart.library.io) 'platform_io.dart';

void ensurePlatform(bool valid, String function) {
  if (valid) return;
  throw BluebirdException(function, BluebirdErrorCode.platform, "Not supported on platform ${System.current}");
}

extension FutureGuards<T> on Future<T> {
  Future<T> bluebirdTimeout(Duration timeout, String function) => this.timeout(
    timeout,
    onTimeout: () =>
        throw BluebirdException(function, BluebirdErrorCode.timeout, "Timed out after ${timeout.inSeconds}s"),
  );

  /// Completes with [error] as soon as [fatal] emits an event matching
  /// [isFatal], unless this future completes first.
  Future<T> failOn<S>(Stream<S> fatal, bool Function(S event) isFatal, BluebirdException Function(S event) error) {
    final completer = Completer<T>();
    final subscription = fatal.listen((event) {
      if (isFatal(event) && !completer.isCompleted) completer.completeError(error(event));
    });
    then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    ).whenComplete(subscription.cancel);
    return completer.future;
  }

  /// Fails with [BluebirdErrorCode.adapterOff] if the adapter leaves the `on`
  /// state mid-flight — off/turningOff, but also unavailable/unauthorized/
  /// unknown. Anything other than `on` means the operation can't complete, so
  /// fail fast rather than hang until the timeout.
  Future<T> bluebirdEnsureAdapterIsOn(String function) => failOn(
    Bluebird.adapterState,
    (s) => s != BluetoothAdapterState.on,
    (s) => BluebirdException(function, BluebirdErrorCode.adapterOff, "Bluetooth adapter is not on (${s.name})"),
  );

  /// Fails with [BluebirdErrorCode.deviceDisconnected] if [device] disconnects mid-flight.
  Future<T> bluebirdEnsureDeviceIsConnected(BluetoothDevice device, String function) => failOn(
    device.connectionState,
    (s) => s == BluetoothConnectionState.disconnected,
    (s) => BluebirdException(function, BluebirdErrorCode.deviceDisconnected, "Device is disconnected"),
  );
}

/// A [Stream] that also exposes its current [value] synchronously.
///
/// Modeled on rxdart's `ValueStream`/`BehaviorSubject`: listening re-emits the
/// current value first (captured at listen time), then every subsequent change.
/// Unlike a plain stream, `.value` reads the latest value without subscribing —
/// which removes the need for a parallel `xNow` getter alongside each stream.
///
/// The change stream is built lazily (on first subscription) and cached, so
/// reading [value] alone never allocates it. This makes `.value` cheap whether
/// or not the owner caches the `ValueStream` in a field.
class ValueStream<T> extends Stream<T> {
  final T Function() _valueFactory;
  final Stream<T> Function() _changesFactory;

  ValueStream._(this._valueFactory, this._changesFactory);

  /// [changes] builds the change stream; it must emit on every change *without*
  /// pre-emitting the current value. It is invoked lazily on first use, so
  /// reading [value] alone never runs it. [value] returns the current value.
  @internal
  factory ValueStream({required T Function() value, required Stream<T> Function() changes}) =>
      ValueStream._(value, changes);

  /// The change stream, built once on first use and reused thereafter.
  late final Stream<T> _changes = _changesFactory();

  /// The current value, read synchronously without subscribing.
  T get value => _valueFactory();

  /// The raw change stream: emits on every change, *without* re-emitting the
  /// current [value] on listen. Use this when you only want deltas; listen to
  /// the [ValueStream] itself (e.g. in a `StreamBuilder`) to get the current
  /// value first, then changes.
  Stream<T> get changes => _changes;

  @override
  bool get isBroadcast => _changes.isBroadcast;

  @override
  StreamSubscription<T> listen(
    void Function(T value)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _changes
        .newStreamWithInitialValue(_valueFactory())
        .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  /// Like [Stream.map], but preserves the [value] view: the result is a
  /// [ValueStream] whose current value is [convert] applied to this one's.
  @override
  ValueStream<S> map<S>(S Function(T event) convert) =>
      ValueStream(value: () => convert(_valueFactory()), changes: () => _changes.map(convert));
}

/// The async sibling of [ValueStream], for a value whose *current* reading is
/// produced asynchronously (e.g. it must be fetched from the platform the first
/// time, because the platform only reports it on demand — never unsolicited).
///
/// Listening awaits the current value, emits it, then streams every subsequent
/// change — so `await stream.first` yields the real current value, not a
/// placeholder. Unlike [ValueStream], [value] is a `Future` (it may fetch), so
/// there is no synchronous `xNow` accessor: use `await stream.value`.
class AsyncValueStream<T> extends Stream<T> {
  final Future<T> Function() _valueFactory;
  final Stream<T> Function() _changesFactory;

  AsyncValueStream._(this._valueFactory, this._changesFactory);

  /// [value] returns the current value, fetching it if not yet known; [changes]
  /// builds the change stream, which must emit on every change *without*
  /// pre-emitting the current value.
  @internal
  factory AsyncValueStream({required Future<T> Function() value, required Stream<T> Function() changes}) =>
      AsyncValueStream._(value, changes);

  /// The change stream, built once on first use and reused thereafter.
  late final Stream<T> _changes = _changesFactory();

  /// The current value, fetched if it is not yet known.
  Future<T> get value => _valueFactory();

  /// The raw change stream: emits on every change, *without* the leading current
  /// value. Use this when you only want deltas; listen to the [AsyncValueStream]
  /// itself to get the current value first, then changes.
  Stream<T> get changes => _changes;

  @override
  bool get isBroadcast => _changes.isBroadcast;

  @override
  StreamSubscription<T> listen(
    void Function(T value)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _emit().listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  Stream<T> _emit() async* {
    yield await _valueFactory();
    yield* _changes;
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

/// The host operating system, used to platform-gate internal calls.
enum System {
  android,
  ios,
  linux,
  macos,
  windows,
  web;

  static System current = currentSystem;

  static bool get isAndroid => current == System.android;
  static bool get isDarwin => current == System.macos || current == System.ios;
}
