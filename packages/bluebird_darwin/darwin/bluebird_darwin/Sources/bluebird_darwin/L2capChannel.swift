// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// L2CAP connection-oriented channels: the data plane that carries channel bytes
// both ways over a dedicated binary FlutterBasicMessageChannel, kept off the
// pigeon host API and the shared event stream.
//
// Wire format on the "bluebird/l2cap" channel (see pigeons/messages.dart):
//   [channelId: int64 big-endian][type: uint8][payload]
//     type 0 = data   (either direction; the message reply gates flow control)
//     type 1 = ready  (Dart→native: start forwarding inbound bytes)
//
// Everything here runs on the main thread — CBL2CAPChannel's streams are
// scheduled on the main run loop and pigeon messages arrive on main — so no
// locking is needed, matching the rest of the darwin plugin.

import CoreBluetooth
import Foundation

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

let kL2capDataChannelName = "bluebird/l2cap"

private let kTypeData: UInt8 = 0
private let kTypeReady: UInt8 = 1
private let kHeaderLen = 9  // int64 channelId + uint8 type
private let kReadChunk = 8192

/// One open L2CAP channel: pumps its CBL2CAPChannel's input/output streams to
/// and from the Dart data channel. Teardown is idempotent — the first of
/// {solicited close, peer/EOF, stream error} wins, and only an unsolicited
/// termination invokes `onUnsolicitedClose`.
final class L2capChannel: NSObject, StreamDelegate {
  let channelId: Int64
  let address: String

  /// CoreBluetooth closes the L2CAP channel if its `CBL2CAPChannel` is
  /// deallocated, so we must hold a strong reference for the channel's lifetime
  /// (keeping only its streams is not enough).
  private let channel: CBL2CAPChannel

  private let input: InputStream
  private let output: OutputStream
  private let dataChannel: FlutterBasicMessageChannel
  private let onUnsolicitedClose: (PigeonError?) -> Void

  private var closed = false
  private var readerStarted = false

  /// Inbound backpressure: at most one chunk is in flight to Dart at a time;
  /// the next read waits for the reply, which stops draining L2CAP credits.
  private var awaitingInboundReply = false

  /// Outbound queue: each chunk is written as the output stream frees space,
  /// and its `ack` (the Dart write's reply) fires once fully written.
  private struct WriteJob {
    let data: Data
    var offset: Int
    let ack: () -> Void
  }
  private var writeQueue: [WriteJob] = []

  init(
    channelId: Int64,
    address: String,
    channel: CBL2CAPChannel,
    dataChannel: FlutterBasicMessageChannel,
    onUnsolicitedClose: @escaping (PigeonError?) -> Void
  ) {
    self.channelId = channelId
    self.address = address
    self.channel = channel
    self.input = channel.inputStream
    self.output = channel.outputStream
    self.dataChannel = dataChannel
    self.onUnsolicitedClose = onUnsolicitedClose
    super.init()

    // Open the output stream now so writes can start; the input stream is
    // opened only on `ready`, so no inbound bytes are forwarded before the
    // app has wired its handler for this channelId.
    output.delegate = self
    output.schedule(in: .main, forMode: .common)
    output.open()
  }

  /// Starts the inbound reader (idempotent; invoked on the `ready` frame).
  func startReading() {
    guard !closed, !readerStarted else { return }
    readerStarted = true
    input.delegate = self
    input.schedule(in: .main, forMode: .common)
    input.open()
    drainInbound()
  }

  /// Enqueues an outbound chunk; `ack` fires once it has been written.
  func enqueueWrite(_ data: Data, ack: @escaping () -> Void) {
    if closed {
      ack()  // never leave a Flutter reply dangling
      return
    }
    writeQueue.append(WriteJob(data: data, offset: 0, ack: ack))
    drainOutbound()
  }

  /// Solicited/external close: tear down without notifying the app.
  func close() {
    guard !closed else { return }
    closed = true
    teardown()
  }

  // MARK: - StreamDelegate

  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .hasBytesAvailable:
      drainInbound()
    case .hasSpaceAvailable:
      drainOutbound()
    case .endEncountered:
      fail(nil)  // clean peer close
    case .errorOccurred:
      fail(streamError(aStream.streamError))
    default:
      break
    }
  }

  // MARK: - Pumps

  private func drainInbound() {
    guard readerStarted, !closed, !awaitingInboundReply, input.hasBytesAvailable else { return }

    var buffer = [UInt8](repeating: 0, count: kReadChunk)
    let n = input.read(&buffer, maxLength: kReadChunk)
    if n < 0 {
      fail(streamError(input.streamError))
      return
    }
    if n == 0 { return }

    awaitingInboundReply = true
    let frame = makeFrame(type: kTypeData, payload: Data(buffer[0..<n]))
    dataChannel.sendMessage(frame) { [weak self] _ in
      guard let self = self, !self.closed else { return }
      self.awaitingInboundReply = false
      self.drainInbound()  // more may have arrived while we waited
    }
  }

  private func drainOutbound() {
    guard !closed else { return }
    while !writeQueue.isEmpty, output.hasSpaceAvailable {
      var job = writeQueue[0]
      let remaining = job.data.count - job.offset
      let written = job.data.withUnsafeBytes { raw -> Int in
        let base = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: job.offset)
        return output.write(base, maxLength: remaining)
      }
      if written < 0 {
        fail(streamError(output.streamError))
        return
      }
      if written == 0 { break }  // no space; wait for .hasSpaceAvailable

      job.offset += written
      if job.offset >= job.data.count {
        writeQueue.removeFirst()
        job.ack()
      } else {
        writeQueue[0] = job
      }
    }
  }

  // MARK: - Teardown

  /// Unsolicited termination from the pumps; notifies the app once.
  private func fail(_ cause: PigeonError?) {
    guard !closed else { return }
    closed = true
    teardown()
    onUnsolicitedClose(cause)
  }

  private func teardown() {
    input.close()
    output.close()
    input.remove(from: .main, forMode: .common)
    output.remove(from: .main, forMode: .common)
    input.delegate = nil
    output.delegate = nil

    // ack any queued writes so their Dart replies don't dangle
    let pending = writeQueue
    writeQueue.removeAll()
    pending.forEach { $0.ack() }
  }

  private func makeFrame(type: UInt8, payload: Data) -> Data {
    var frame = Data(capacity: kHeaderLen + payload.count)
    var bigEndianId = channelId.bigEndian
    withUnsafeBytes(of: &bigEndianId) { frame.append(contentsOf: $0) }
    frame.append(type)
    frame.append(payload)
    return frame
  }

  private func streamError(_ error: Error?) -> PigeonError {
    let message = error?.localizedDescription ?? "l2cap stream error"
    return PigeonError(code: BluebirdErrorCode.darwinError.wire, message: message, details: nil)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Manager: the single data channel + the map of open channels. Stored state
// lives on BluebirdPlugin (extensions cannot add stored properties).
// ─────────────────────────────────────────────────────────────────────────────

extension BluebirdPlugin {

  /// Wires the shared "bluebird/l2cap" data channel. Called from `register`.
  func setUpL2capDataChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterBasicMessageChannel(
      name: kL2capDataChannelName, binaryMessenger: messenger,
      codec: FlutterBinaryCodec.sharedInstance())
    l2capDataChannel = channel
    channel.setMessageHandler { [weak self] message, reply in
      self?.handleL2capMessage(message, reply: reply)
    }
  }

  /// Registers a freshly-opened CoreBluetooth channel and returns its id.
  func registerL2capChannel(_ address: String, _ cbChannel: CBL2CAPChannel) -> Int64 {
    let id = nextL2capId
    nextL2capId += 1

    guard let dataChannel = l2capDataChannel else { return id }  // detached
    let channel = L2capChannel(
      channelId: id, address: address, channel: cbChannel, dataChannel: dataChannel
    ) { [weak self] cause in
      // Unsolicited close. `removeValue` is the arbiter: if a solicited close or
      // device teardown already removed it, that path owns the notification.
      guard let self = self else { return }
      if self.l2capChannels.removeValue(forKey: id) != nil {
        self.emitL2capClosed(id, address, cause)
      }
    }
    l2capChannels[id] = channel
    return id
  }

  /// Solicited close (the app called closeL2capChannel): tear down, no event.
  func closeL2capSolicited(_ channelId: Int64) {
    l2capChannels.removeValue(forKey: channelId)?.close()
  }

  /// Closes every channel of `address` on disconnect, notifying the app.
  func closeL2capForDevice(_ address: String) {
    for (id, channel) in l2capChannels where channel.address == address {
      if l2capChannels.removeValue(forKey: id) != nil {
        channel.close()
        emitL2capClosed(id, address, deviceDisconnectedError())
      }
    }
  }

  /// Drops every channel without notifying (hot restart / detach).
  func closeAllL2cap() {
    let all = l2capChannels
    l2capChannels.removeAll()
    all.values.forEach { $0.close() }
  }

  private func emitL2capClosed(_ channelId: Int64, _ address: String, _ cause: PigeonError?) {
    sink?.success(
      BmL2capChannelClosedEvent(
        channelId: channelId, address: address,
        errorCode: cause?.code, errorString: cause?.message))
  }

  private func handleL2capMessage(_ message: Any?, reply: @escaping FlutterReply) {
    guard let data = message as? Data, data.count >= kHeaderLen else {
      reply(nil)
      return
    }

    var channelId: Int64 = 0
    for i in 0..<8 {
      channelId = (channelId << 8) | Int64(data[data.startIndex + i])
    }
    let type = data[data.startIndex + 8]
    let payload =
      data.count > kHeaderLen
      ? data.subdata(in: (data.startIndex + kHeaderLen)..<data.endIndex) : Data()

    guard let channel = l2capChannels[channelId] else {
      log(.warning, "l2cap: message for unknown channel \(channelId)")
      reply(nil)
      return
    }

    switch type {
    case kTypeReady:
      channel.startReading()
      reply(nil)
    case kTypeData:
      channel.enqueueWrite(payload) { reply(nil) }
    default:
      reply(nil)
    }
  }
}
