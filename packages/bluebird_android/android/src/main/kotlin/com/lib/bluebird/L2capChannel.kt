// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// L2CAP connection-oriented channels: the data plane that carries channel bytes
// both ways over a dedicated binary BasicMessageChannel, kept off the pigeon
// host API and the shared event stream.
//
// Wire format on the "bluebird/l2cap" channel (see pigeons/messages.dart):
//   [channelId: int64 big-endian][type: uint8][payload]
//     type 0 = data   (either direction; the message reply gates flow control)
//     type 1 = ready  (Dart→native: start forwarding inbound bytes)
//
// Each message's reply is the backpressure signal. Inbound: the reader reads one
// chunk from the socket, sends it, and waits for Dart's reply before reading the
// next — a slow consumer stops draining L2CAP credits and flow-controls the
// peer. Outbound: a write frame's reply fires only once the bytes were handed to
// the socket's (blocking) output stream, so the Dart write future resolves with
// real backpressure.

package com.lib.bluebird

import android.bluetooth.BluetoothSocket
import android.os.Handler
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

private const val TYPE_DATA: Byte = 0
private const val TYPE_READY: Byte = 1

/** int64 channelId + uint8 type. */
private const val HEADER_LEN = 9

/** Inbound read chunk. Kept comfortably above a typical L2CAP MTU. */
private const val READ_CHUNK = 8192

/** Builds a `[channelId][type][payload]` frame as a direct buffer for Flutter. */
private fun frame(channelId: Long, type: Byte, data: ByteArray, len: Int): ByteBuffer =
    ByteBuffer.allocateDirect(HEADER_LEN + len).order(ByteOrder.BIG_ENDIAN).apply {
        putLong(channelId)
        put(type)
        put(data, 0, len)
        // Do NOT rewind/flip: Flutter's Android messenger transmits bytes
        // [0, position), treating the buffer's position as the length. The puts
        // above leave position at the end of the frame (= its length); rewinding
        // to 0 would send a zero-length message.
    }

/**
 * Owns the single "bluebird/l2cap" data channel and the map of open channels.
 * Created on engine attach; [detach] tears everything down.
 */
class L2capManager(
    messenger: BinaryMessenger,
    private val mainHandler: Handler,
    private val log: (LogLevel, String) -> Unit,
    private val emitEvent: (BmEvent) -> Unit,
) {
    companion object {
        const val CHANNEL_NAME = "bluebird/l2cap"
    }

    private val dataChannel = BasicMessageChannel(messenger, CHANNEL_NAME, BinaryCodec.INSTANCE)
    private val channels = ConcurrentHashMap<Long, L2capChannel>()
    private val nextId = AtomicLong(1)

    fun start() {
        dataChannel.setMessageHandler { message, reply -> onMessage(message, reply) }
    }

    /** Engine detach: stop handling and drop every channel silently (Dart is gone). */
    fun detach() {
        dataChannel.setMessageHandler(null)
        closeAll()
    }

    /**
     * Registers a freshly-connected [socket] and returns its channel id. The
     * reader does not start until Dart sends a `ready` frame, so no inbound
     * bytes are forwarded before the app has wired its handler for the id.
     */
    fun register(address: String, socket: BluetoothSocket): Long {
        val id = nextId.getAndIncrement()
        channels[id] = L2capChannel(id, address, socket, mainHandler, dataChannel) { cause ->
            // Unsolicited close (peer/EOF/IO). `remove` is the arbiter: if a
            // solicited close or device teardown already removed the channel,
            // it also owns the notification, so we stay silent.
            if (channels.remove(id) != null) emitClosed(id, address, cause)
        }
        return id
    }

    /** Solicited close (the app called closeL2capChannel): tear down, no event. */
    fun closeSolicited(channelId: Long) {
        channels.remove(channelId)?.close()
    }

    /** Closes every channel of [address] on disconnect, notifying the app. */
    fun closeForDevice(address: String) {
        for (channel in channels.values.filter { it.address == address }) {
            if (channels.remove(channel.channelId) != null) {
                channel.close()
                emitClosed(channel.channelId, address, deviceDisconnectedError())
            }
        }
    }

    /** Drops every channel without notifying (hot restart / detach). */
    fun closeAll() {
        val all = channels.values.toList()
        channels.clear()
        all.forEach { it.close() }
    }

    private fun emitClosed(channelId: Long, address: String, cause: FlutterError?) {
        emitEvent(
            BmL2capChannelClosedEvent(
                channelId = channelId,
                address = address,
                errorCode = cause?.code,
                errorString = cause?.message,
            ),
        )
    }

    private fun deviceDisconnectedError() =
        FlutterError(BluebirdErrorCode.DEVICE_DISCONNECTED.wire, "device is disconnected", null)

    private fun onMessage(message: ByteBuffer?, reply: BasicMessageChannel.Reply<ByteBuffer>) {
        if (message == null || message.remaining() < HEADER_LEN) {
            reply.reply(null)
            return
        }
        message.order(ByteOrder.BIG_ENDIAN)
        val channelId = message.getLong()
        val type = message.get()
        val payload = ByteArray(message.remaining())
        message.get(payload)

        val channel = channels[channelId]
        if (channel == null) {
            log(LogLevel.WARNING, "l2cap: message for unknown channel $channelId")
            reply.reply(null)
            return
        }
        when (type) {
            TYPE_READY -> {
                channel.startReading()
                reply.reply(null)
            }
            TYPE_DATA -> channel.enqueueWrite(payload) { reply.reply(null) }
            else -> reply.reply(null)
        }
    }
}

/**
 * One open L2CAP socket with its reader and writer pumps. Blocking socket I/O
 * runs on [Dispatchers.IO]; all Flutter channel traffic is posted to the main
 * thread. Teardown is idempotent — the first of {solicited close, peer/EOF, I/O
 * error} to flip [closed] wins, and only an unsolicited termination invokes
 * [onUnsolicitedClose].
 */
class L2capChannel(
    val channelId: Long,
    val address: String,
    private val socket: BluetoothSocket,
    private val mainHandler: Handler,
    private val dataChannel: BasicMessageChannel<ByteBuffer>,
    private val onUnsolicitedClose: (FlutterError?) -> Unit,
) {
    private class WriteJob(val data: ByteArray, val ack: () -> Unit)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val input = socket.inputStream
    private val output = socket.outputStream
    private val writeQueue = Channel<WriteJob>(Channel.UNLIMITED)
    private val closed = AtomicBoolean(false)
    private val readerStarted = AtomicBoolean(false)

    init {
        // Writer pump: drains the queue in order, acking each job on the main
        // thread only after its bytes reached the (blocking) output stream.
        scope.launch {
            for (job in writeQueue) {
                try {
                    output.write(job.data)
                    output.flush()
                } catch (e: Throwable) {
                    fail(ioError(e))
                }
                mainHandler.post { job.ack() }
            }
        }
    }

    /** Enqueues an outbound chunk; [ack] fires once it has been written. */
    fun enqueueWrite(data: ByteArray, ack: () -> Unit) {
        if (closed.get()) {
            mainHandler.post(ack) // never leave a Flutter reply dangling
            return
        }
        writeQueue.trySend(WriteJob(data, ack))
    }

    /** Starts the inbound reader (idempotent; invoked on the `ready` frame). */
    fun startReading() {
        if (closed.get() || !readerStarted.compareAndSet(false, true)) return
        scope.launch {
            val buf = ByteArray(READ_CHUNK)
            try {
                while (true) {
                    val n = input.read(buf) // blocking
                    if (n < 0) break // EOF: peer closed the channel
                    if (n > 0) sendChunk(buf, n) // suspends on Dart's reply
                }
                fail(null) // clean peer close
            } catch (e: Throwable) {
                fail(ioError(e))
            }
        }
    }

    private suspend fun sendChunk(buf: ByteArray, len: Int) =
        suspendCancellableCoroutine { cont ->
            val f = frame(channelId, TYPE_DATA, buf, len)
            mainHandler.post { dataChannel.send(f) { cont.resume(Unit) } }
        }

    /** Solicited/external close: tear down without notifying the app. */
    fun close() {
        if (closed.compareAndSet(false, true)) teardown()
    }

    /** Unsolicited termination from the pumps; notifies the app once. */
    private fun fail(cause: FlutterError?) {
        if (closed.compareAndSet(false, true)) {
            teardown()
            onUnsolicitedClose(cause)
        }
    }

    private fun teardown() {
        try {
            socket.close() // unblocks the reader's input.read()
        } catch (_: Throwable) {
        }
        scope.cancel()
        // Ack any queued-but-unsent writes so their Dart replies don't dangle
        // (the reply is what completes the Dart write future).
        writeQueue.close()
        while (true) {
            val job = writeQueue.tryReceive().getOrNull() ?: break
            mainHandler.post { job.ack() }
        }
    }

    private fun ioError(e: Throwable): FlutterError =
        FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, e.toString(), null)
}
