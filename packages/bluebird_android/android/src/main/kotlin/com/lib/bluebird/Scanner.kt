// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// The scanning feature: settings, dedupe/keyword/divisor filtering, scan callback.

package com.lib.bluebird

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import java.util.concurrent.ConcurrentHashMap

/**
 * Owns all scan state: the native [ScanCallback], the settings of the
 * current scan, and the dedupe/divisor bookkeeping applied to results.
 */
class Scanner(
    private val log: (LogLevel, String) -> Unit,
    private val emitEvent: (BmEvent) -> Unit,
) {
    /** Settings of the current scan; applied by the callback. */
    private var scanSettings: BmScanSettings? = null

    private val advSeen = ConcurrentHashMap<String, String>()
    private val scanCounts = ConcurrentHashMap<String, Int>()

    private var isScanning = false

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            log(LogLevel.VERBOSE, "onScanResult")

            val settings = scanSettings ?: return

            val device = result.device
            val remoteId = device.address
            val scanRecord = result.scanRecord
            val advHex = Proto.bytesToHex(scanRecord?.bytes)

            // filter duplicates
            if (!settings.continuousUpdates) {
                val isDuplicate = advSeen[remoteId] == advHex
                advSeen[remoteId] = advHex // remember
                if (isDuplicate) {
                    return
                }
            }

            // filter keywords
            val name = scanRecord?.deviceName
            if (!filterKeywords(settings.withKeywords, name)) {
                return
            }

            // filter divisor
            if (settings.continuousUpdates) {
                val count = scanCountIncrement(remoteId)
                val divisor = settings.continuousDivisor.toInt()
                if (divisor > 1 && (count % divisor) != 0) {
                    return
                }
            }

            emitEvent(BmScanAdvertisementsEvent(listOf(Proto.bmScanAdvertisement(device, result))))
        }

        override fun onBatchScanResults(results: List<ScanResult>) {
            for (result in results) {
                onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, result)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            log(LogLevel.ERROR, "onScanFailed: ${ErrorStrings.scanFailedString(errorCode)}")

            emitEvent(BmScanFailedEvent(errorCode.toLong(), ErrorStrings.scanFailedString(errorCode)))
        }
    }

    fun start(scanner: BluetoothLeScanner, settings: BmScanSettings) {
        val filters = Proto.scanFilters(settings)
        val scanSettingsNative = Proto.scanSettings(settings)

        // remember for later
        scanSettings = settings

        // clear seen devices
        advSeen.clear()
        scanCounts.clear()

        scanner.startScan(filters, scanSettingsNative, scanCallback)

        isScanning = true
    }

    /** Stops the scan if one is running; no-op otherwise. */
    fun stop(scanner: BluetoothLeScanner?, reason: String) {
        if (scanner != null && isScanning) {
            log(LogLevel.DEBUG, "calling stopScan ($reason)")
            scanner.stopScan(scanCallback)
            isScanning = false
        }
    }

    private fun filterKeywords(keywords: List<String>, target: String?): Boolean {
        if (keywords.isEmpty()) {
            return true
        }
        if (target == null) {
            return false
        }
        return keywords.any { target.contains(it) }
    }

    private fun scanCountIncrement(remoteId: String): Int {
        val count = scanCounts[remoteId] ?: 0
        scanCounts[remoteId] = count + 1
        return count
    }
}
