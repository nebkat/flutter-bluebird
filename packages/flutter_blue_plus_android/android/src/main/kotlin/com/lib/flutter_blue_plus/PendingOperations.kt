// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.flutter_blue_plus

import android.os.Handler

/**
 * The snake_case wire form of this error code (crosses the channel as
 * `PlatformException.code`).
 */
val FbpErrorCode.wire: String get() = name.lowercase()

/**
 * Identifies one in-flight request awaiting completion from a native
 * callback (GATT callback, broadcast receiver, activity result, ...).
 */
sealed class OpKey {
    abstract val address: String?

    data class Connect(override val address: String) : OpKey()
    data class Disconnect(override val address: String) : OpKey()
    data class DiscoverServices(override val address: String) : OpKey()
    data class ReadChar(
        override val address: String,
        val svcUuid: String,
        val svcInstance: Int,
        val chrUuid: String,
        val chrInstance: Int,
    ) : OpKey()
    data class WriteChar(
        override val address: String,
        val svcUuid: String,
        val svcInstance: Int,
        val chrUuid: String,
        val chrInstance: Int,
    ) : OpKey()
    data class ReadDesc(
        override val address: String,
        val svcUuid: String,
        val svcInstance: Int,
        val chrUuid: String,
        val chrInstance: Int,
        val descUuid: String,
    ) : OpKey()
    data class WriteDesc(
        override val address: String,
        val svcUuid: String,
        val svcInstance: Int,
        val chrUuid: String,
        val chrInstance: Int,
        val descUuid: String,
    ) : OpKey()
    data class SetNotify(
        override val address: String,
        val svcUuid: String,
        val svcInstance: Int,
        val chrUuid: String,
        val chrInstance: Int,
    ) : OpKey()
    data class Mtu(override val address: String) : OpKey()
    data class Rssi(override val address: String) : OpKey()
    data class Phy(override val address: String) : OpKey()
    data class CreateBond(override val address: String) : OpKey()
    data class RemoveBond(override val address: String) : OpKey()
    data class ClearCache(override val address: String) : OpKey()
    object TurnOn : OpKey() {
        override val address: String? get() = null
    }
}

/**
 * Registry correlating async pigeon completion callbacks with the native
 * callbacks that eventually complete them.
 *
 * All completions are dispatched exactly once, on the main looper.
 */
class PendingOperations(private val mainHandler: Handler) {

    private val ops = HashMap<OpKey, (Result<Any?>) -> Unit>()

    /**
     * Registers [callback] for [key]. If an operation with the same key is
     * already in flight, the NEW callback is failed immediately with
     * "operation_in_progress" and the existing one is left untouched.
     */
    @Suppress("UNCHECKED_CAST")
    fun <T> register(key: OpKey, callback: (Result<T>) -> Unit): Boolean {
        val cb = callback as (Result<Any?>) -> Unit
        val conflict = synchronized(ops) {
            if (ops.containsKey(key)) {
                true
            } else {
                ops[key] = cb
                false
            }
        }
        if (conflict) {
            dispatch(cb, Result.failure(FlutterError(
                FbpErrorCode.OPERATION_IN_PROGRESS.wire,
                "an operation of this type is already in progress for this device", null)))
        }
        return !conflict
    }

    /** Atomic remove-and-return. Guarantees exactly-once completion. */
    fun take(key: OpKey): ((Result<Any?>) -> Unit)? {
        return synchronized(ops) { ops.remove(key) }
    }

    /**
     * Completes the operation for [key] with [result], if one is pending.
     * Returns whether an operation was pending.
     */
    fun complete(key: OpKey, result: Result<Any?>): Boolean {
        val cb = take(key) ?: return false
        dispatch(cb, result)
        return true
    }

    /** Completes the operation for [key] with [value], if one is pending. */
    fun succeed(key: OpKey, value: Any?): Boolean = complete(key, Result.success(value))

    /** Fails the operation for [key] with [error], if one is pending. */
    fun fail(key: OpKey, error: FlutterError): Boolean = complete(key, Result.failure(error))

    /** Fails every pending operation belonging to [address]. */
    fun failAllForDevice(address: String, error: FlutterError) {
        val taken = synchronized(ops) {
            val keys = ops.keys.filter { it.address == address }
            keys.mapNotNull { ops.remove(it) }
        }
        taken.forEach { dispatch(it, Result.failure(error)) }
    }

    /** Fails every pending operation. */
    fun failAll(error: FlutterError) {
        val taken = synchronized(ops) {
            val callbacks = ops.values.toList()
            ops.clear()
            callbacks
        }
        taken.forEach { dispatch(it, Result.failure(error)) }
    }

    /** Drops all pending operations WITHOUT invoking them (hot restart). */
    fun clearAll() {
        synchronized(ops) { ops.clear() }
    }

    private fun dispatch(cb: (Result<Any?>) -> Unit, result: Result<Any?>) {
        mainHandler.post { cb(result) }
    }
}
