// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import Foundation

/// Runs a device's GATT operations one at a time, in the order they were
/// submitted. CoreBluetooth correlates delegate callbacks by attribute only,
/// so two operations in flight on one attribute could not be told apart.
///
/// Order is submission order because host methods arrive on the main actor in
/// the order Flutter delivered them, and each reaches `submit` before its
/// first suspension.
final class GattQueue {
  private var running = false
  private var waiting: [CheckedContinuation<Void, Error>] = []

  /// Runs `body` once every operation submitted before it has finished.
  /// Waiting for its turn does not count against `backstop`; running does.
  /// Past `backstop`, `onExpired` is called and must make `body` finish,
  /// typically by failing the continuation it is suspended on.
  @MainActor
  func submit<T>(
    backstop: TimeInterval,
    onExpired: @escaping @MainActor () -> Void,
    _ body: @MainActor () async throws -> T
  ) async throws -> T {
    try await acquire()
    defer { release() }

    let watchdog = Task { @MainActor in
      try await Task.sleep(nanoseconds: UInt64(backstop * 1_000_000_000))
      onExpired()
    }
    defer { watchdog.cancel() }

    return try await body()
  }

  /// Fails every operation still waiting for its turn with `error`.
  func failWaiting(_ error: Error) {
    let waiters = waiting
    waiting.removeAll()
    waiters.forEach { $0.resume(throwing: error) }
  }

  @MainActor
  private func acquire() async throws {
    guard running else {
      running = true
      return
    }
    try await withCheckedThrowingContinuation { waiting.append($0) }
  }

  private func release() {
    if waiting.isEmpty {
      running = false
    } else {
      // hands the turn straight over, so `running` stays set
      waiting.removeFirst().resume()
    }
  }
}
