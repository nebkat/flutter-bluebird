// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// API-level compatibility shims.

package com.lib.bluebird

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothStatusCodes
import android.content.Intent
import android.os.Build
import android.os.Parcelable

val BluetoothGattCharacteristic.canRead: Boolean
    get() = properties and BluetoothGattCharacteristic.PROPERTY_READ != 0
val BluetoothGattCharacteristic.canWrite: Boolean
    get() = properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
val BluetoothGattCharacteristic.canWriteNoResponse: Boolean
    get() = properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
val BluetoothGattCharacteristic.canNotify: Boolean
    get() = properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0
val BluetoothGattCharacteristic.canIndicate: Boolean
    get() = properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0

/**
 * Writes [value] to [c], papering over the API 33 / legacy split.
 * Throws a [FlutterError] if the write could not be started.
 */
@Suppress("DEPRECATION")
fun BluetoothGatt.writeCharacteristicCompat(
    c: BluetoothGattCharacteristic,
    value: ByteArray,
    writeType: Int,
) {
    if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
        val rv = writeCharacteristic(c, value, writeType)
        if (rv != BluetoothStatusCodes.SUCCESS) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire,
                "gatt.writeCharacteristic() returned $rv : ${ErrorStrings.bluetoothStatusString(rv)}", rv)
        }
    } else {
        // set value
        if (!c.setValue(value)) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "characteristic.setValue() returned false", null)
        }

        // write type
        c.writeType = writeType

        // write char
        if (!writeCharacteristic(c)) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.writeCharacteristic() returned false", null)
        }
    }
}

/**
 * Writes [value] to [d], papering over the API 33 / legacy split.
 * Throws a [FlutterError] if the write could not be started.
 * [label] names the descriptor in error messages.
 */
@Suppress("DEPRECATION")
fun BluetoothGatt.writeDescriptorCompat(
    d: BluetoothGattDescriptor,
    value: ByteArray,
    label: String = "descriptor",
) {
    if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
        val rv = writeDescriptor(d, value)
        if (rv != BluetoothStatusCodes.SUCCESS) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire,
                "gatt.writeDescriptor() returned $rv : ${ErrorStrings.bluetoothStatusString(rv)}", rv)
        }
    } else {
        // set value
        if (!d.setValue(value)) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "$label.setValue() returned false", null)
        }

        // write descriptor
        if (!writeDescriptor(d)) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.writeDescriptor() returned false", null)
        }
    }
}

/** Reads a [Parcelable] extra, papering over the API 33 deprecation. */
@Suppress("DEPRECATION")
inline fun <reified T : Parcelable> Intent.getParcelableExtraCompat(key: String): T? =
    if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
        getParcelableExtra(key, T::class.java)
    } else {
        getParcelableExtra(key)
    }
