// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// The per-device FIFO that keeps one GATT operation in flight at a time.

package com.lib.bluebird

import kotlin.time.Duration
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout

/**
 * Runs a device's GATT operations one at a time, in the order they were
 * submitted. Android rejects an operation started while another is pending,
 * so without this, overlapping calls would fail rather than wait their turn.
 *
 * Order is submission order because [Mutex] is fair and host methods reach
 * [submit] synchronously on the main thread, in the order Flutter delivered
 * them.
 */
class GattQueue {
    private val mutex = Mutex()

    /**
     * Runs [block] once every operation submitted before it has finished.
     * Waiting for its turn does not count against [backstop]; running does.
     * Past [backstop] the block is cancelled and fails with the error
     * [onExpired] returns, which is also the hook to tear the link down.
     */
    suspend fun <T> submit(backstop: Duration, onExpired: () -> Throwable, block: suspend () -> T): T =
        mutex.withLock {
            try {
                withTimeout(backstop) { block() }
            } catch (e: TimeoutCancellationException) {
                throw onExpired()
            }
        }
}
