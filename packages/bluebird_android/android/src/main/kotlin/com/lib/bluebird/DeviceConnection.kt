// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.bluebird

import android.bluetooth.BluetoothGatt

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

    /** 23 is the minimum MTU, as per the BLE spec. */
    var mtu: Int = 23

    val isConnected: Boolean get() = state == State.CONNECTED
    val isConnecting: Boolean get() = state == State.CONNECTING
}
