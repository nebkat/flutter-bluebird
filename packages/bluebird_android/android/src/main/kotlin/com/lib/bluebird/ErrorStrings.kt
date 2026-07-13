// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Human-readable names for GATT/HCI/scan status codes (BLE spec tables).

package com.lib.bluebird

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback

object ErrorStrings {

    fun connectionStateString(cs: Int): String = when (cs) {
        BluetoothProfile.STATE_DISCONNECTED -> "disconnected"
        BluetoothProfile.STATE_CONNECTING -> "connecting"
        BluetoothProfile.STATE_CONNECTED -> "connected"
        BluetoothProfile.STATE_DISCONNECTING -> "disconnecting"
        else -> "UNKNOWN_CONNECTION_STATE ($cs)"
    }

    fun adapterStateString(state: Int): String = when (state) {
        BluetoothAdapter.STATE_OFF -> "off"
        BluetoothAdapter.STATE_ON -> "on"
        BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
        BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
        else -> "UNKNOWN_ADAPTER_STATE ($state)"
    }

    fun bondStateString(bs: Int): String = when (bs) {
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_BONDED -> "bonded"
        BluetoothDevice.BOND_NONE -> "bond-none"
        else -> "UNKNOWN_BOND_STATE ($bs)"
    }

    // Defined in the Bluetooth Standard
    fun gattErrorString(value: Int): String = when (value) {
        BluetoothGatt.GATT_SUCCESS -> "GATT_SUCCESS" // 0
        0x01 -> "GATT_INVALID_HANDLE" // 1
        BluetoothGatt.GATT_READ_NOT_PERMITTED -> "GATT_READ_NOT_PERMITTED" // 2
        BluetoothGatt.GATT_WRITE_NOT_PERMITTED -> "GATT_WRITE_NOT_PERMITTED" // 3
        0x04 -> "GATT_INVALID_PDU" // 4
        BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION -> "GATT_INSUFFICIENT_AUTHENTICATION" // 5
        BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED -> "GATT_REQUEST_NOT_SUPPORTED" // 6
        BluetoothGatt.GATT_INVALID_OFFSET -> "GATT_INVALID_OFFSET" // 7
        BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION -> "GATT_INSUFFICIENT_AUTHORIZATION" // 8
        0x09 -> "GATT_PREPARE_QUEUE_FULL" // 9
        0x0a -> "GATT_ATTR_NOT_FOUND" // 10
        0x0b -> "GATT_ATTR_NOT_LONG" // 11
        0x0c -> "GATT_INSUFFICIENT_KEY_SIZE" // 12
        BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH -> "GATT_INVALID_ATTRIBUTE_LENGTH" // 13
        0x0e -> "GATT_UNLIKELY" // 14
        BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION -> "GATT_INSUFFICIENT_ENCRYPTION" // 15
        0x10 -> "GATT_UNSUPPORTED_GROUP" // 16
        0x11 -> "GATT_INSUFFICIENT_RESOURCES" // 17
        0x80 -> "GATT_NO_RESOURCES" // 128
        0x81 -> "GATT_INTERNAL_ERROR" // 129
        0x82 -> "GATT_WRONG_STATE" // 130
        0x83 -> "GATT_DB_FULL" // 131
        0x84 -> "GATT_BUSY" // 132
        0x85 -> "GATT_ERROR" // 133
        0x86 -> "GATT_CMD_STARTED" // 134
        0x87 -> "GATT_ILLEGAL_PARAMETER" // 135
        0x88 -> "GATT_PENDING" // 136
        0x89 -> "GATT_AUTH_FAIL" // 137
        0x8a -> "GATT_MORE" // 138
        0x8b -> "GATT_INVALID_CFG" // 139
        0x8c -> "GATT_SERVICE_STARTED" // 140
        0x8d -> "GATT_ENCRYPTED_NO_MITM" // 141
        0x8e -> "GATT_NOT_ENCRYPTED" // 142
        BluetoothGatt.GATT_CONNECTION_CONGESTED -> "GATT_CONNECTION_CONGESTED" // 143
        BluetoothGatt.GATT_FAILURE -> "GATT_FAILURE" // 257
        else -> "UNKNOWN_GATT_ERROR ($value)"
    }

    fun bluetoothStatusString(value: Int): String = when (value) {
        BluetoothStatusCodes.ERROR_BLUETOOTH_NOT_ALLOWED -> "ERROR_BLUETOOTH_NOT_ALLOWED"
        BluetoothStatusCodes.ERROR_BLUETOOTH_NOT_ENABLED -> "ERROR_BLUETOOTH_NOT_ENABLED"
        BluetoothStatusCodes.ERROR_DEVICE_NOT_BONDED -> "ERROR_DEVICE_NOT_BONDED"
        BluetoothStatusCodes.ERROR_GATT_WRITE_NOT_ALLOWED -> "ERROR_GATT_WRITE_NOT_ALLOWED"
        BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY -> "ERROR_GATT_WRITE_REQUEST_BUSY"
        BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION -> "ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION"
        BluetoothStatusCodes.ERROR_PROFILE_SERVICE_NOT_BOUND -> "ERROR_PROFILE_SERVICE_NOT_BOUND"
        BluetoothStatusCodes.ERROR_UNKNOWN -> "ERROR_UNKNOWN"
        BluetoothStatusCodes.FEATURE_NOT_SUPPORTED -> "FEATURE_NOT_SUPPORTED"
        BluetoothStatusCodes.FEATURE_SUPPORTED -> "FEATURE_SUPPORTED"
        BluetoothStatusCodes.SUCCESS -> "SUCCESS"
        else -> "UNKNOWN_BLE_ERROR ($value)"
    }

    fun scanFailedString(value: Int): String = when (value) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "SCAN_FAILED_ALREADY_STARTED"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "SCAN_FAILED_APPLICATION_REGISTRATION_FAILED"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "SCAN_FAILED_FEATURE_UNSUPPORTED"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "SCAN_FAILED_INTERNAL_ERROR"
        ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES"
        ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY -> "SCAN_FAILED_SCANNING_TOO_FREQUENTLY"
        else -> "UNKNOWN_SCAN_ERROR ($value)"
    }

    // Defined in the Bluetooth Standard, Volume 1, Part F, 1.3 HCI Error Code, pages 364-377.
    // See https://www.bluetooth.org/docman/handlers/downloaddoc.ashx?doc_id=478726,
    // For Android specific errors, see https://developer.android.com/reference/android/bluetooth/BluetoothGatt#constants_1
    fun hciStatusString(value: Int): String = when (value) {
        0x00 -> "SUCCESS"
        0x01 -> "UNKNOWN_COMMAND" // The controller does not understand the HCI Command Packet OpCode that the Host sent.
        0x02 -> "UNKNOWN_CONNECTION_IDENTIFIER" // The connection identifier used is unknown
        0x03 -> "HARDWARE_FAILURE" // A hardware failure has occurred
        0x04 -> "PAGE_TIMEOUT" // a page timed out because of the Page Timeout configuration parameter.
        0x05 -> "AUTHENTICATION_FAILURE" // Pairing or authentication failed. This could be due to an incorrect PIN or Link Key.
        0x06 -> "PIN_OR_KEY_MISSING" // Pairing failed because of a missing PIN
        0x07 -> "MEMORY_FULL" // The Controller has run out of memory to store new parameters.
        0x08 -> "LINK_SUPERVISION_TIMEOUT" // The link supervision timeout has expired for a given connection.
        0x09 -> "CONNECTION_LIMIT_EXCEEDED" // The Controller is already at its limit of the number of connections it can support.
        0x0A -> "MAX_NUM_OF_CONNECTIONS_EXCEEDED" // The Controller has reached the limit of connections
        0x0B -> "CONNECTION_ALREADY_EXISTS" // A connection to this device already exists
        0x0C -> "COMMAND_DISALLOWED" // The command requested cannot be executed by the Controller at this time.
        0x0D -> "CONNECTION_REJECTED_LIMITED_RESOURCES" // A connection was rejected due to limited resources.
        0x0E -> "CONNECTION_REJECTED_SECURITY_REASONS" // A connection was rejected due to security, e.g. auth or pairing.
        0x0F -> "CONNECTION_REJECTED_UNACCEPTABLE_MAC_ADDRESS" // connection rejected, this device does not accept the BD_ADDR
        0x10 -> "CONNECTION_ACCEPT_TIMEOUT_EXCEEDED" // Connection Accept Timeout exceeded for this connection attempt.
        0x11 -> "UNSUPPORTED_PARAMETER_VALUE" // A feature or parameter value in the HCI command is not supported.
        0x12 -> "INVALID_COMMAND_PARAMETERS" // At least one of the HCI command parameters is invalid.
        0x13 -> "REMOTE_USER_TERMINATED_CONNECTION" // The user on the remote device terminated the connection.
        0x14 -> "REMOTE_DEVICE_TERMINATED_CONNECTION_LOW_RESOURCES" // remote device terminated connection due to low resources.
        0x15 -> "REMOTE_DEVICE_TERMINATED_CONNECTION_POWER_OFF" // The remote device terminated the connection due to power off
        0x16 -> "CONNECTION_TERMINATED_BY_LOCAL_HOST" // The local device terminated the connection.
        0x17 -> "REPEATED_ATTEMPTS" // The Controller is disallowing auth because of too quick attempts.
        0x18 -> "PAIRING_NOT_ALLOWED" // The device does not allow pairing
        0x19 -> "UNKNOWN_LMP_PDU" // The Controller has received an unknown LMP OpCode.
        0x1A -> "UNSUPPORTED_REMOTE_FEATURE" // The remote device does not support feature for the issued command or LMP PDU.
        0x1B -> "SCO_OFFSET_REJECTED" // The offset requested in the LMP_SCO_link_req PDU has been rejected.
        0x1C -> "SCO_INTERVAL_REJECTED" // The interval requested in the LMP_SCO_link_req PDU has been rejected.
        0x1D -> "SCO_AIR_MODE_REJECTED" // The air mode requested in the LMP_SCO_link_req PDU has been rejected.
        0x1E -> "INVALID_LMP_OR_LL_PARAMETERS" // Some LMP PDU / LL Control PDU parameters were invalid.
        0x1F -> "UNSPECIFIED" // No other error code specified is appropriate to use
        0x20 -> "UNSUPPORTED_LMP_OR_LL_PARAMETER_VALUE" // An LMP PDU or an LL Control PDU contains a value that is not supported
        0x21 -> "ROLE_CHANGE_NOT_ALLOWED" // a Controller will not allow a role change at this time.
        0x22 -> "LMP_OR_LL_RESPONSE_TIMEOUT" // An LMP transaction failed to respond within the LMP response timeout
        0x23 -> "LMP_OR_LL_ERROR_TRANS_COLLISION" // An LMP transaction or LL procedure has collided with the same transaction
        0x24 -> "LMP_PDU_NOT_ALLOWED" // A Controller sent an LMP PDU with an OpCode that was not allowed.
        0x25 -> "ENCRYPTION_MODE_NOT_ACCEPTABLE" // The requested encryption mode is not acceptable at this time.
        0x26 -> "LINK_KEY_CANNOT_BE_EXCHANGED" // A link key cannot be changed because a fixed unit key is being used.
        0x27 -> "REQUESTED_QOS_NOT_SUPPORTED" // The requested Quality of Service is not supported.
        0x28 -> "INSTANT_PASSED" // The LMP PDU or LL PDU instant has already passed
        0x29 -> "PAIRING_WITH_UNIT_KEY_NOT_SUPPORTED" // It was not possible to pair as a unit key is not supported.
        0x2A -> "DIFFERENT_TRANSACTION_COLLISION" // An LMP transaction or LL Procedure collides with an ongoing transaction.
        0x2B -> "UNDEFINED_0x2B" // Undefined error code
        0x2C -> "QOS_UNACCEPTABLE_PARAMETER" // The quality of service parameters could not be accepted at this time.
        0x2D -> "QOS_REJECTED" // The specified quality of service parameters cannot be accepted. negotiation should be terminated
        0x2E -> "CHANNEL_CLASSIFICATION_NOT_SUPPORTED" // The Controller cannot perform channel assessment. not supported.
        0x2F -> "INSUFFICIENT_SECURITY" // The HCI command or LMP PDU sent is only possible on an encrypted link.
        0x30 -> "PARAMETER_OUT_OF_RANGE" // A parameter in the HCI command is outside of valid range
        0x31 -> "UNDEFINED_0x31" // Undefined error
        0x32 -> "ROLE_SWITCH_PENDING" // A Role Switch is pending, so the HCI command or LMP PDU is rejected
        0x33 -> "UNDEFINED_0x33" // Undefined error
        0x34 -> "RESERVED_SLOT_VIOLATION" // Synchronous negotiation terminated with negotiation state set to Reserved Slot Violation.
        0x35 -> "ROLE_SWITCH_FAILED" // A role switch was attempted but it failed and the original piconet structure is restored.
        0x36 -> "INQUIRY_RESPONSE_TOO_LARGE" // The extended inquiry response is too large to fit in packet supported by Controller.
        0x37 -> "SECURE_SIMPLE_PAIRING_NOT_SUPPORTED" // Host does not support Secure Simple Pairing, but receiving Link Manager does.
        0x38 -> "HOST_BUSY_PAIRING" // The Host is busy with another pairing operation. The receiving device should retry later.
        0x39 -> "CONNECTION_REJECTED_NO_SUITABLE_CHANNEL" // Controller could not calculate an appropriate value for Channel selection.
        0x3A -> "CONTROLLER_BUSY" // The Controller was busy and unable to process the request.
        0x3B -> "UNACCEPTABLE_CONNECTION_PARAMETERS" // The remote device terminated connection, unacceptable connection parameters.
        0x3C -> "ADVERTISING_TIMEOUT" // Advertising completed. Or for directed advertising, no connection was created.
        0x3D -> "CONNECTION_TERMINATED_MIC_FAILURE" // Connection terminated because Message Integrity Check failed on received packet.
        0x3E -> "CONNECTION_FAILED_ESTABLISHMENT" // The LL initiated a connection but the connection has failed to be established.
        0x3F -> "MAC_CONNECTION_FAILED" // The MAC of the 802.11 AMP was requested to connect to a peer, but the connection failed.
        0x40 -> "COARSE_CLOCK_ADJUSTMENT_REJECTED" // The master is unable to make a coarse adjustment to the piconet clock.
        0x41 -> "TYPE0_SUBMAP_NOT_DEFINED" // The LMP PDU is rejected because the Type 0 submap is not currently defined.
        0x42 -> "UNKNOWN_ADVERTISING_IDENTIFIER" // A command was sent from the Host but the Advertising or Sync handle does not exist.
        0x43 -> "LIMIT_REACHED" // The number of operations requested has been reached and has indicated the completion of the activity
        0x44 -> "OPERATION_CANCELLED_BY_HOST" // A request to the Controller issued by the Host and still pending was successfully canceled.
        0x45 -> "PACKET_TOO_LONG" // An attempt was made to send or receive a packet that exceeds the maximum allowed packet length.
        0x85 -> "ANDROID_SPECIFIC_ERROR" // Additional Android specific errors
        0x8f -> "GATT_CONNECTION_CONGESTED" // A remote device connection is congested.
        0x93 -> "GATT_CONNECTION_TIMEOUT" // GATT connection timed out, likely due to the remote device being out of range or not advertising as connectable.
        0x101 -> "FAILURE_REGISTERING_CLIENT" // max of 30 clients has been reached.
        else -> "UNKNOWN_HCI_ERROR ($value)"
    }
}
