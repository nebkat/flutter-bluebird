// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.bluebird

import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class GattQueueTest {
    private class Expired : Exception()

    private val backstop = 35.seconds

    @Test
    fun runsOperationsOneAtATimeInSubmissionOrder() = runTest {
        val queue = GattQueue()
        val log = mutableListOf<String>()

        (1..3).map { i ->
            async {
                queue.submit(backstop, { Expired() }) {
                    log += "start $i"
                    delay((4 - i).seconds)
                    log += "end $i"
                }
            }
        }.awaitAll()

        assertEquals(listOf("start 1", "end 1", "start 2", "end 2", "start 3", "end 3"), log)
    }

    @Test
    fun aFailedOperationHandsOverToTheNext() = runTest {
        val queue = GattQueue()

        val failing = async { runCatching { queue.submit(backstop, { Expired() }) { error("boom") } } }
        val next = async { queue.submit(backstop, { Expired() }) { 42 } }

        assertTrue(failing.await().exceptionOrNull() is IllegalStateException)
        assertEquals(42, next.await())
    }

    @Test
    fun anOperationPastItsBackstopFailsWithTheExpiryErrorAndHandsOver() = runTest {
        val queue = GattQueue()
        val expired = Expired()
        val never = CompletableDeferred<Unit>()

        val stuck = async { runCatching { queue.submit(backstop, { expired }) { never.await() } } }
        val next = async { queue.submit(backstop, { Expired() }) { currentTime } }

        assertSame(expired, stuck.await().exceptionOrNull())
        assertEquals(backstop.inWholeMilliseconds, next.await())
    }

    @Test
    fun waitingForATurnDoesNotCountAgainstTheBackstop() = runTest {
        val queue = GattQueue()

        val first = async { queue.submit(backstop, { Expired() }) { delay(30.seconds) } }
        val second = async { queue.submit(backstop, { Expired() }) { delay(30.seconds); "done" } }

        first.await()
        assertEquals("done", second.await())
        assertEquals(60.seconds.inWholeMilliseconds, currentTime)
    }

    @Test
    fun expiryIsOnlyConsultedOnExpiry() = runTest {
        val queue = GattQueue()
        var consulted = false

        queue.submit(backstop, { consulted = true; Expired() }) { delay(1.seconds) }

        assertFalse(consulted)
    }

    @Test
    fun anOperationCancelledWhileQueuedNeverRunsAndDoesNotHoldUpTheRest() = runTest {
        val queue = GattQueue()
        val gate = CompletableDeferred<Unit>()
        val ran = mutableListOf<Int>()

        val first = launch { queue.submit(backstop, { Expired() }) { gate.await(); ran += 1 } }
        val second = launch { queue.submit(backstop, { Expired() }) { ran += 2 } }
        val third = async { queue.submit(backstop, { Expired() }) { ran += 3 } }
        runCurrent()

        second.cancel()
        gate.complete(Unit)
        first.join()
        third.await()
        advanceUntilIdle()

        assertEquals(listOf(1, 3), ran)
    }

    @Test
    fun cancellingTheRunningOperationPropagatesRatherThanExpiring() = runTest {
        val queue = GattQueue()
        val never = CompletableDeferred<Unit>()

        val running = launch {
            queue.submit(backstop, { fail("cancellation is not expiry"); Expired() }) { never.await() }
        }
        runCurrent()
        running.cancel()
        running.join()

        assertEquals(1, queue.submit(backstop, { Expired() }) { 1 })
    }
}
