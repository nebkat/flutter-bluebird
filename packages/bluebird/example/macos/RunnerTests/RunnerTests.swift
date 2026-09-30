import Cocoa
import FlutterMacOS
import XCTest

@testable import bluebird_darwin

@MainActor
class GattQueueTests: XCTestCase {
  private struct Expired: Error {}
  private struct Boom: Error {}

  private let backstop: TimeInterval = 5

  private func sleep(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  func testRunsOperationsOneAtATimeInSubmissionOrder() async throws {
    let queue = GattQueue()
    var log: [String] = []

    let tasks = (1...3).map { i in
      Task { @MainActor in
        try await queue.submit(backstop: backstop, onExpired: {}) {
          log.append("start \(i)")
          try await sleep(Double(4 - i) * 0.02)
          log.append("end \(i)")
        }
      }
    }
    for task in tasks { try await task.value }

    XCTAssertEqual(log, ["start 1", "end 1", "start 2", "end 2", "start 3", "end 3"])
  }

  func testAFailedOperationHandsOverToTheNext() async throws {
    let queue = GattQueue()

    let failing = Task { @MainActor in
      try await queue.submit(backstop: backstop, onExpired: {}) { throw Boom() }
    }
    let next = Task { @MainActor in
      try await queue.submit(backstop: backstop, onExpired: {}) { 42 }
    }

    do {
      try await failing.value
      XCTFail("expected the operation to fail")
    } catch is Boom {}
    let value = try await next.value
    XCTAssertEqual(value, 42)
  }

  func testAnOperationPastItsBackstopIsExpiredAndHandsOver() async throws {
    let queue = GattQueue()
    var parked: CheckedContinuation<Void, Error>?

    let stuck = Task { @MainActor in
      try await queue.submit(
        backstop: 0.05, onExpired: { parked?.resume(throwing: Expired()) }
      ) {
        try await withCheckedThrowingContinuation { parked = $0 }
      }
    }
    let next = Task { @MainActor in
      try await queue.submit(backstop: backstop, onExpired: {}) { "next" }
    }

    do {
      try await stuck.value
      XCTFail("expected the operation to expire")
    } catch is Expired {}
    let value = try await next.value
    XCTAssertEqual(value, "next")
  }

  func testWaitingForATurnDoesNotCountAgainstTheBackstop() async throws {
    let queue = GattQueue()
    var expired = false

    let first = Task { @MainActor in
      try await queue.submit(backstop: 0.3, onExpired: { expired = true }) { try await sleep(0.2) }
    }
    let second = Task { @MainActor in
      try await queue.submit(backstop: 0.3, onExpired: { expired = true }) { try await sleep(0.2) }
    }
    try await first.value
    try await second.value
    try await sleep(0.2)

    XCTAssertFalse(expired)
  }

  func testFailWaitingFailsTheQueuedButNotTheRunning() async throws {
    let queue = GattQueue()
    var gate: CheckedContinuation<Void, Error>?
    var ran: [Int] = []

    let running = Task { @MainActor in
      try await queue.submit(backstop: backstop, onExpired: {}) {
        try await withCheckedThrowingContinuation { gate = $0 }
        ran.append(1)
      }
    }
    let queued = Task { @MainActor in
      try await queue.submit(backstop: backstop, onExpired: {}) { ran.append(2) }
    }
    try await sleep(0.05)

    queue.failWaiting(Boom())
    gate?.resume()

    try await running.value
    do {
      try await queued.value
      XCTFail("expected the queued operation to fail")
    } catch is Boom {}
    XCTAssertEqual(ran, [1])

    let after = try await queue.submit(backstop: backstop, onExpired: {}) { 3 }
    XCTAssertEqual(after, 3)
  }
}
