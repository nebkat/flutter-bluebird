// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Bluetooth UUID value type: canonical equality via java.util.UUID, shortest-form rendering for the wire and logs.

package com.lib.bluebird

import java.util.UUID

@JvmInline
value class Uuid(val value: UUID) {
    /** 128-bit lowercase form. */
    val str128: String get() = value.toString().lowercase()

    /** Shortest form: 16/32-bit when on the Bluetooth base uuid, else 128-bit. */
    val str: String
        get() = str128.let {
            when {
                it.startsWith("0000") && it.endsWith(BASE_SUFFIX) -> it.substring(4, 8)
                it.endsWith(BASE_SUFFIX) -> it.substring(0, 8)
                else -> it
            }
        }

    override fun toString(): String = str

    companion object {
        private const val BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb"

        /** Parses 16-bit ("2902"), 32-bit, or full 128-bit string forms. */
        fun parse(s: String): Uuid = Uuid(UUID.fromString(when (s.length) {
            4 -> "0000$s$BASE_SUFFIX"
            8 -> "$s$BASE_SUFFIX"
            else -> s
        }))
    }
}
