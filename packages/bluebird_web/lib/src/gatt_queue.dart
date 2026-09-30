import 'package:flutter/services.dart' show PlatformException;

/// Runs each device's GATT operations one at a time, in the order they were
/// submitted: Web Bluetooth rejects an operation started while another on the
/// same device is pending ("GATT operation already in progress").
class GattQueue {
  /// The last operation submitted per device, which the next one waits on.
  final _tails = <String, Future<void>>{};

  /// Bumped on every disconnect, so an operation can tell it was queued on a
  /// connection that has since gone.
  final _connections = <String, int>{};

  Future<T> run<T>(String address, Future<T> Function() operation) {
    final connection = _connections[address] ?? 0;
    final result = (_tails[address] ?? Future<void>.value()).then((_) {
      if ((_connections[address] ?? 0) != connection) {
        throw PlatformException(code: 'device_disconnected', message: 'device is disconnected');
      }
      return operation();
    });
    _tails[address] = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Fails every operation still waiting on [address] when its turn comes. The
  /// one running, if any, keeps the queue until it settles, so the next
  /// connection's operations never overlap it.
  void disconnected(String address) => _connections[address] = (_connections[address] ?? 0) + 1;
}
