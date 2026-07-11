// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.bluebird

import android.bluetooth.BluetoothGatt
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation

/** Uniquely identifies one characteristic within a device's GATT database. */
data class CharKey(
    val svcUuid: String,
    val svcInstance: Int,
    val chrUuid: String,
    val chrInstance: Int,
)

/**
 * Identifies which GATT operation is in flight on a device, so callbacks
 * can be matched to the operation they complete (e.g. an unsolicited
 * onMtuChanged must not resume a pending read). The device address is
 * implicit: the op lives on the [DeviceConnection] that started it.
 */
sealed class GattOp {
    data class ReadChar(val key: CharKey) : GattOp()
    data class WriteChar(val key: CharKey) : GattOp()
    data class SetNotify(val key: CharKey) : GattOp()
    data class ReadDesc(val key: CharKey, val descUuid: String) : GattOp()
    data class WriteDesc(val key: CharKey, val descUuid: String) : GattOp()
    data object DiscoverServices : GattOp()
    data object Mtu : GattOp()
    data object Rssi : GattOp()
    data object Phy : GattOp()
}

/** One in-flight GATT operation awaiting its BluetoothGattCallback. */
class PendingGatt(val kind: GattOp, val cont: CancellableContinuation<Any?>)

/**
 * Per-device connection state, replacing the Java plugin's cluster of
 * ConcurrentHashMap fields (mConnectedDevices, mCurrentlyConnectingDevices,
 * mMtu).
 */
class DeviceConnection(
    val address: String,
    var gatt: BluetoothGatt,
) {
    enum class State { CONNECTING, CONNECTED }

    var state: State = State.CONNECTING

    /**
     * 23 is the minimum MTU, as per the BLE spec.
     * Volatile: written from GATT binder threads, read from the main thread.
     */
    @Volatile
    var mtu: Int = 23

    val isConnected: Boolean get() = state == State.CONNECTED
    val isConnecting: Boolean get() = state == State.CONNECTING

    // One continuation slot per concurrency class. Android allows only one
    // in-flight GATT op per device (starting a second while one is pending
    // returns false) and the Dart layer additionally serializes globally,
    // so a single gatt slot suffices; `kind` is kept so callbacks can be
    // matched (e.g. an unsolicited onMtuChanged must not resume a pending
    // read).
    //
    // All slots are mutated under the plugin's stateLock: callbacks arrive
    // on binder threads.
    var pendingConnect: CancellableContinuation<Unit>? = null
    var pendingDisconnect: CancellableContinuation<Unit>? = null
    var pendingGatt: PendingGatt? = null
    var pendingBond: CancellableContinuation<Boolean>? = null

    /**
     * Fails the gatt & bond slots, e.g. when the device disconnects.
     * pendingConnect/pendingDisconnect are completed separately by
     * onConnectionStateChange. Caller must hold the plugin's stateLock.
     */
    fun failAllPending(error: FlutterError) {
        pendingGatt?.let { pendingGatt = null; it.cont.resumeWithException(error) }
        pendingBond?.let { pendingBond = null; it.resumeWithException(error) }
    }
}
