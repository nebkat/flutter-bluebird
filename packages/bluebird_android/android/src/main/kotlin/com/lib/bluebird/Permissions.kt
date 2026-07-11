// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.bluebird

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Port of the Java plugin's ensurePermissions / askPermission /
 * onRequestPermissionsResult chain.
 */
class Permissions {

    private val operations = HashMap<Int, (granted: Boolean, permission: String?) -> Unit>()
    private var lastEventId = 1452

    /**
     * Ensures that all [permissions] are granted, requesting any missing ones,
     * then invokes [operation] with the overall result. If a permission was
     * denied, the denied permission's name is passed along.
     */
    fun ensurePermissions(
        context: Context?,
        activity: Activity?,
        permissions: List<String>,
        operation: (granted: Boolean, permission: String?) -> Unit,
    ) {
        // check that we have a context
        if (context == null) {
            operation(false, "Application Context is null")
            return
        }

        // Filter out permissions that are already granted
        val permissionsNeeded = permissions.filter { permission ->
            ContextCompat.checkSelfPermission(context, permission) != PackageManager.PERMISSION_GRANTED
        }

        // If all permissions are granted, proceed with the operation
        if (permissionsNeeded.isEmpty()) {
            operation(true, null)
            return
        }

        // cannot prompt without an activity
        if (activity == null) {
            operation(false, permissionsNeeded.first())
            return
        }

        // Store the operation with the current request code
        operations[lastEventId] = operation

        ActivityCompat.requestPermissions(activity, permissionsNeeded.toTypedArray(), lastEventId)

        lastEventId++
    }

    /** Routes activity permission results back to the stored operation. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        val operation = operations.remove(requestCode) // also cleans up to prevent leaks

        if (operation != null && grantResults.isNotEmpty()) {
            for (i in grantResults.indices) {
                if (grantResults[i] != PackageManager.PERMISSION_GRANTED) {
                    operation(false, permissions[i]) // permission denied
                    return true
                }
            }
            operation(true, null) // permission granted
            return true
        }
        return false
    }
}
