// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.bluebird

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

class BluebirdPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener,
    BluebirdHostApi {

    companion object {
        private const val TAG = "[Bluebird-Android]"
        private const val CCCD = "2902"
        private const val ENABLE_BLUETOOTH_REQUEST_CODE = 13106

        // random number defined by bluebird.
        private const val USER_CANCELED_ERROR_CODE = 23789258L
    }

    private var logLevel = LogLevel.DEBUG

    private var context: Context? = null
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var isScanning = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private val permissions = Permissions()

    /** Runs the pigeon host methods; recreated on every engine attach. */
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // Prevents GATT callback threads & the platform thread from mutating
    // connection state concurrently (was mMethodCallMutex in the Java plugin).
    private val stateLock = Any()

    private val connections = ConcurrentHashMap<String, DeviceConnection>()

    // In-flight ops that cannot live on a DeviceConnection slot:
    //  - pendingTurnOn: the single system "enable Bluetooth" dialog;
    //    resumed by onActivityResult. Not tied to any device.
    //  - pendingRemoveBond: removeBond is the one op that legally runs
    //    without a connection (bonds outlive connections), so it is keyed
    //    by address here; resumed by the bond state receiver.
    // Both are mutated under stateLock, like the DeviceConnection slots.
    private var pendingTurnOn: CancellableContinuation<Boolean>? = null
    private val pendingRemoveBond = HashMap<String, CancellableContinuation<Boolean>>()

    private val bondingDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val bondingPins = ConcurrentHashMap<String, ByteArray>()
    private val advSeen = ConcurrentHashMap<String, String>()
    private val scanCounts = ConcurrentHashMap<String, Int>()
    private var scanSettings: BmScanSettings? = null

    private var sink: PigeonEventSink<BmEvent>? = null

    private val streamHandler = object : NativeEventsStreamHandler() {
        override fun onListen(p0: Any?, sink: PigeonEventSink<BmEvent>) {
            this@BluebirdPlugin.sink = sink
        }

        override fun onCancel(p0: Any?) {
            this@BluebirdPlugin.sink = null
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // helpers

    private fun log(level: LogLevel, message: String) {
        if (level.raw > logLevel.raw) {
            return
        }
        when (level) {
            LogLevel.WARNING -> Log.w(TAG, "[Bluebird] $message")
            LogLevel.ERROR -> Log.e(TAG, "[Bluebird] $message")
            else -> Log.d(TAG, "[Bluebird] $message")
        }
    }

    /** Emits [event] on the main thread. */
    private fun emitEvent(event: BmEvent) {
        mainHandler.post {
            val s = sink
            if (s != null) {
                s.success(event)
            } else {
                log(LogLevel.WARNING, "emitEvent: no event sink attached: $event")
            }
        }
    }

    /**
     * Runs [block] and completes [callback] at the end — errors become
     * Result.failure, cancellation (hot restart/detach) drops the callback
     * without invoking it.
     */
    private fun <T> launch(callback: (Result<T>) -> Unit, block: suspend () -> T) {
        scope.launch {
            val result = try {
                Result.success(block())
            } catch (e: CancellationException) {
                return@launch
            } catch (e: FlutterError) {
                Result.failure(e)
            } catch (e: Throwable) {
                Result.failure(FlutterError(BluebirdErrorCode.PLATFORM.wire, e.toString(), null))
            }
            callback(result)
        }
    }

    /** Lazily initializes and returns the adapter, mirroring the Java plugin. */
    private fun adapter(): BluetoothAdapter? {
        if (bluetoothAdapter == null) {
            log(LogLevel.DEBUG, "initializing BluetoothAdapter")
            bluetoothManager = context?.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
            bluetoothAdapter = bluetoothManager?.adapter
        }
        return bluetoothAdapter
    }

    private fun bluetoothUnavailable() =
        FlutterError(BluebirdErrorCode.UNSUPPORTED.wire, "the device does not support bluetooth", null)

    private fun requireAdapter(): BluetoothAdapter = adapter() ?: throw bluetoothUnavailable()

    private fun isAdapterOn(): Boolean {
        // get adapterState, if we have permission
        return try {
            adapter()?.state == BluetoothAdapter.STATE_ON
        } catch (e: Exception) {
            false
        }
    }

    private fun requireAdapterOn() {
        if (!isAdapterOn()) {
            throw FlutterError(BluebirdErrorCode.ADAPTER_OFF.wire, "Bluetooth must be turned on", null)
        }
    }

    private fun notConnected() = FlutterError(BluebirdErrorCode.NOT_CONNECTED.wire, "device is not connected", null)

    private fun requireConnected(address: String): DeviceConnection =
        connections[address]?.takeIf { it.isConnected } ?: throw notConnected()

    private fun operationInProgress() = FlutterError(
        BluebirdErrorCode.OPERATION_IN_PROGRESS.wire,
        "an operation of this type is already in progress for this device", null)

    /////////////////////////////////////////////////////////////////////////////
    // pending-operation slots
    //
    // Bridges Android's callback-style APIs into suspend functions: one
    // continuation slot per concurrency class, resumed by the GATT
    // callbacks, broadcast receivers, or activity results. Slots are
    // mutated under stateLock (callbacks arrive on binder threads);
    // resuming from them is safe because continuations resume on the
    // plugin's Main dispatcher.

    /**
     * Registers the continuation in the slot exposed by [get]/[set] (under
     * [stateLock]), runs [start], then suspends until a callback resumes it.
     * Fails immediately with operation_in_progress if the slot is occupied.
     * If [start] throws, the slot is rolled back and the error propagates.
     */
    private suspend fun <T> awaitSlot(
        get: () -> CancellableContinuation<T>?,
        set: (CancellableContinuation<T>?) -> Unit,
        start: () -> Unit,
    ): T = suspendCancellableCoroutine { cont ->
        val conflict = synchronized(stateLock) {
            if (get() != null) {
                true
            } else {
                set(cont)
                false
            }
        }
        if (conflict) {
            cont.resumeWithException(operationInProgress())
            return@suspendCancellableCoroutine
        }
        cont.invokeOnCancellation {
            synchronized(stateLock) {
                if (get() === cont) set(null)
            }
        }
        try {
            start()
        } catch (e: Throwable) {
            // roll back the slot, only if it is still ours
            val ours = synchronized(stateLock) {
                if (get() === cont) {
                    set(null)
                    true
                } else {
                    false
                }
            }
            if (ours) cont.resumeWithException(e)
        }
    }

    /** Suspends until the device's single in-flight GATT op slot is resumed by its callback. */
    @Suppress("UNCHECKED_CAST")
    private suspend fun <T> DeviceConnection.awaitGatt(kind: GattOp, start: () -> Unit): T =
        awaitSlot<Any?>(
            get = { pendingGatt?.cont },
            set = { pendingGatt = it?.let { cont -> PendingGatt(kind, cont) } },
            start = start,
        ) as T

    private suspend fun DeviceConnection.awaitDisconnect(start: () -> Unit): Unit =
        awaitSlot({ pendingDisconnect }, { pendingDisconnect = it }, start)

    private suspend fun DeviceConnection.awaitBond(start: () -> Unit): Boolean =
        awaitSlot({ pendingBond }, { pendingBond = it }, start)

    private suspend fun awaitTurnOn(start: () -> Unit): Boolean =
        awaitSlot({ pendingTurnOn }, { pendingTurnOn = it }, start)

    private suspend fun awaitRemoveBond(address: String, start: () -> Unit): Boolean =
        awaitSlot(
            get = { pendingRemoveBond[address] },
            set = { if (it != null) pendingRemoveBond[address] = it else pendingRemoveBond.remove(address) },
            start = start,
        )

    /** Atomically takes the device's pending GATT op, if [expected] matches its kind. */
    private fun takePendingGatt(gatt: BluetoothGatt, expected: (GattOp) -> Boolean): PendingGatt? =
        synchronized(stateLock) {
            val conn = connections[gatt.device.address] ?: return@synchronized null
            conn.pendingGatt?.takeIf { expected(it.kind) }?.also { conn.pendingGatt = null }
        }

    /** Atomically takes the device's pending createBond continuation, if any. */
    private fun takePendingBond(address: String): CancellableContinuation<Boolean>? =
        synchronized(stateLock) {
            connections[address]?.let { c -> c.pendingBond?.also { c.pendingBond = null } }
        }

    /** Removes and returns every in-flight continuation, emptying all slots. */
    private fun takeAllPending(): List<CancellableContinuation<*>> = synchronized(stateLock) {
        buildList {
            for (conn in connections.values) {
                conn.pendingConnect?.let { add(it) }
                conn.pendingConnect = null
                conn.pendingDisconnect?.let { add(it) }
                conn.pendingDisconnect = null
                conn.pendingGatt?.let { add(it.cont) }
                conn.pendingGatt = null
                conn.pendingBond?.let { add(it) }
                conn.pendingBond = null
            }
            addAll(pendingRemoveBond.values)
            pendingRemoveBond.clear()
            pendingTurnOn?.let { add(it) }
            pendingTurnOn = null
        }
    }

    /** Fails every in-flight operation, e.g. when the adapter turns off. */
    private fun failAllPending(error: FlutterError) {
        takeAllPending().forEach { it.resumeWithException(error) }
    }

    /** Cancels everything WITHOUT invoking callbacks (hot restart / detach). */
    private fun cancelAllPending() {
        takeAllPending().forEach { it.cancel() }
    }

    private fun invalidIdentifier(detail: String) =
        FlutterError(BluebirdErrorCode.INVALID_IDENTIFIER.wire, "could not locate attribute: $detail", null)

    private fun resolveCharacteristicOrThrow(
        gatt: BluetoothGatt,
        ref: BmCharacteristicRef,
    ): BluetoothGattCharacteristic =
        Proto.resolveCharacteristic(gatt, ref) ?: throw invalidIdentifier(ref.toString())

    private fun resolveDescriptorOrThrow(gatt: BluetoothGatt, ref: BmDescriptorRef): BluetoothGattDescriptor =
        Proto.resolveDescriptor(gatt, ref) ?: throw invalidIdentifier(ref.toString())

    private fun gattError(status: Int, message: String? = null) =
        FlutterError(BluebirdErrorCode.GATT_ERROR.wire, message ?: Proto.gattErrorString(status), status)

    /** Suspends until all [perms] are granted or denied: (granted, deniedPerm). */
    private suspend fun awaitPermissions(perms: List<String>): Pair<Boolean, String?> =
        suspendCancellableCoroutine { cont ->
            permissions.ensurePermissions(context, activityBinding?.activity, perms) { granted, perm ->
                cont.resume(granted to perm)
            }
        }

    /** Suspends until all [perms] are granted, else throws PERMISSION_DENIED with [message]. */
    private suspend fun requirePermissions(perms: List<String>, message: (String?) -> String) {
        val (granted, perm) = awaitPermissions(perms)
        if (!granted) {
            throw FlutterError(BluebirdErrorCode.PERMISSION_DENIED.wire, message(perm), null)
        }
    }

    private fun connectPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) { // Android 12 (October 2021)
            listOf(Manifest.permission.BLUETOOTH_CONNECT)
        } else { // Android 11 (September 2020) and below
            listOf(Manifest.permission.BLUETOOTH)
        }

    // for highest reliability, it is recommended to not do
    // anything while the device is busy bonding.
    private suspend fun waitIfBonding() {
        if (bondingDevices.isNotEmpty()) {
            log(LogLevel.DEBUG, "waiting for bonding to complete...")
            delay(50)
            log(LogLevel.DEBUG, "bonding completed")
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

    private fun getMaxPayload(remoteId: String, writeType: Int, allowLongWrite: Boolean): Int {
        // 512 comes from the BLE spec. Characteristics should not be longer
        // than 512. Android also enforces this as the maximum in internal code.
        val maxAttrLen = 512

        // if no response, or allowLongWrite is not allowed, we can only write up to MTU-3.
        // This is the same limitation as iOS, and ensures transfer reliability.
        return if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE || !allowLongWrite) {
            val mtu = connections[remoteId]?.mtu ?: 23 // 23 is the minimum MTU, as per the BLE spec
            minOf(mtu - 3, maxAttrLen)
        } else {
            // if withResponse and allowLongWrite is allowed,
            // android will auto split up to the maxAttrLen.
            maxAttrLen
        }
    }

    private fun disconnectAllDevices(func: String) {
        log(LogLevel.DEBUG, "disconnectAllDevices($func)")

        // request disconnections
        for (conn in connections.values.toList()) {
            if (!conn.isConnected) {
                continue
            }
            if (func == "adapterTurnOff") {
                // Note:
                //  - calling `disconnect` and `close` after the adapter
                //    is turned off is not necessary. It is implied.
                //    Calling them leads to a `DeadObjectException`.
                //  - But, we must make sure the disconnect callback is called.
                //    It's surprising but android does not invoke this callback itself.
                gattCallback.onConnectionStateChange(conn.gatt, 0, BluetoothProfile.STATE_DISCONNECTED)
            } else {
                // disconnect
                log(LogLevel.DEBUG, "calling disconnect: ${conn.address}")
                conn.gatt.disconnect()

                // it is important to close after disconnection, otherwise we will
                // quickly run out of bluetooth resources, preventing new connections
                log(LogLevel.DEBUG, "calling close: ${conn.address}")
                conn.gatt.close()
            }
        }

        connections.clear()
        bondingDevices.clear()
        bondingPins.clear()
    }

    private fun stopScanInternal(reason: String) {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner != null && isScanning) {
            log(LogLevel.DEBUG, "calling stopScan ($reason)")
            scanner.stopScan(scanCallback)
            isScanning = false
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        log(LogLevel.DEBUG, "onAttachedToEngine")

        pluginBinding = binding
        context = binding.applicationContext

        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        BluebirdHostApi.setUp(binding.binaryMessenger, this)
        NativeEventsStreamHandler.register(binding.binaryMessenger, streamHandler)

        context?.registerReceiver(adapterStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        context?.registerReceiver(pairRequestReceiver, IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST))
        context?.registerReceiver(bondStateReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        log(LogLevel.DEBUG, "onDetachedFromEngine")

        // dart-side state is gone; notify listeners & close the stream
        sink?.success(BmDetachedFromEngineEvent())
        sink?.endOfStream()
        sink = null

        // drop in-flight operations WITHOUT invoking their callbacks:
        // cancelAllPending resumes nothing; scope.cancel then kills the
        // launched coroutines so no pigeon callback is ever invoked.
        cancelAllPending()
        scope.cancel()

        // stop scanning
        stopScanInternal("onDetachedFromEngine")

        synchronized(stateLock) {
            disconnectAllDevices("onDetachedFromEngine")
        }

        context?.unregisterReceiver(bondStateReceiver)
        context?.unregisterReceiver(pairRequestReceiver)
        context?.unregisterReceiver(adapterStateReceiver)
        context = null

        BluebirdHostApi.setUp(binding.binaryMessenger, null)
        pluginBinding = null

        bluetoothAdapter = null
        bluetoothManager = null
    }

    /////////////////////////////////////////////////////////////////////////////
    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        log(LogLevel.DEBUG, "onAttachedToActivity")
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        log(LogLevel.DEBUG, "onDetachedFromActivityForConfigChanges")
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        log(LogLevel.DEBUG, "onReattachedToActivityForConfigChanges")
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        log(LogLevel.DEBUG, "onDetachedFromActivity")
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    /////////////////////////////////////////////////////////////////////////////
    // activity results

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ): Boolean {
        return this.permissions.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == ENABLE_BLUETOOTH_REQUEST_CODE) {
            synchronized(stateLock) { pendingTurnOn?.also { pendingTurnOn = null } }
                ?.resume(resultCode == Activity.RESULT_OK)
            return true
        }
        return false // did not handle anything
    }

    /////////////////////////////////////////////////////////////////////////////
    // BluebirdHostApi

    override fun flutterRestart(): Long {
        log(LogLevel.DEBUG, "flutterRestart")

        // no adapter?
        val a = adapter() ?: return 0 // no work to do

        // stop scanning
        stopScanInternal("flutterRestart")

        // drop in-flight operations without invoking their callbacks.
        // Must run before disconnectAllDevices clears the connections map,
        // because the pending continuations live on DeviceConnection slots.
        cancelAllPending()

        // all dart state is reset after flutter restart
        // (i.e. Hot Restart) so also reset native state
        synchronized(stateLock) {
            disconnectAllDevices("flutterRestart")
        }

        log(LogLevel.DEBUG, "connectedPeripherals: ${connections.size}")
        return connections.size.toLong()
    }

    override fun connectedCount(): Long {
        val count = connections.values.count { it.isConnected }
        log(LogLevel.DEBUG, "connectedPeripherals: $count")
        if (count == 0) {
            log(LogLevel.DEBUG, "Hot Restart: complete")
        }
        return count.toLong()
    }

    override fun setLogLevel(level: LogLevel) {
        logLevel = level
    }

    override fun setOptions(showPowerAlert: Boolean, restoreState: Boolean) {
        // Currently ignored on Android
    }

    override fun isSupported(): Boolean {
        return adapter() != null
    }

    override fun getAdapterName(callback: (Result<String>) -> Unit) = launch(callback) {
        awaitPermissions(connectPermissions()) // proceed even if denied

        try {
            adapter()?.name
        } catch (e: SecurityException) {
            null
        } ?: ""
    }

    override fun getAdapterState(): BmAdapterStateEnum {
        val state = try {
            adapter()?.state ?: -1
        } catch (e: Exception) {
            -1
        }
        return Proto.bmAdapterStateEnum(state)
    }

    override fun turnOn(callback: (Result<Boolean>) -> Unit) = launch(callback) {
        val a = requireAdapter()
        requirePermissions(connectPermissions()) { perm -> "Permission $perm required to turn Bluetooth on" }

        if (a.isEnabled) {
            return@launch true // no work to do
        }

        val binding = activityBinding
            ?: throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "no foreground activity available to request Bluetooth enable", null)

        // completes via onActivityResult
        awaitTurnOn {
            val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            binding.activity.startActivityForResult(enableBtIntent, ENABLE_BLUETOOTH_REQUEST_CODE)
        }
    }

    @Suppress("DEPRECATION")
    override fun turnOff(callback: (Result<Boolean>) -> Unit) = launch(callback) {
        val a = requireAdapter()

        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "turnOff is not supported on Android 13 (API 33) and above", null)
        }

        if (!a.isEnabled) {
            return@launch false // no work to do
        }

        a.disable()
    }

    override fun startScan(settings: BmScanSettings, callback: (Result<Unit>) -> Unit) = launch(callback) {
        val a = requireAdapter()

        val perms = buildList {
            if (Build.VERSION.SDK_INT >= 31) { // Android 12 (October 2021)
                add(Manifest.permission.BLUETOOTH_SCAN)
                if (settings.androidUsesFineLocation) {
                    add(Manifest.permission.ACCESS_FINE_LOCATION)
                }
                // it is unclear why this is needed, but some phones throw a
                // SecurityException AdapterService getRemoteName, without it
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else { // Android 11 (September 2020) and below
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }

        requirePermissions(perms) { perm -> "Permission $perm required to scan devices" }

        // check adapter
        requireAdapterOn()

        // get scanner
        val scanner = a.bluetoothLeScanner
            ?: throw FlutterError(BluebirdErrorCode.ADAPTER_OFF.wire,
                "getBluetoothLeScanner() is null. Is the Adapter on?", null)

        // build scan settings
        val builder = ScanSettings.Builder()
        builder.setScanMode(settings.androidScanMode.toInt())
        if (Build.VERSION.SDK_INT >= 26) { // Android 8.0 (August 2017)
            builder.setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
            builder.setLegacy(settings.androidLegacy)
        }
        val scanSettingsNative = builder.build()

        // set filters
        val filters = buildList {
            // services
            for (service in settings.withServices) {
                val uuid = ParcelUuid.fromString(Proto.uuid128(service))
                add(ScanFilter.Builder().setServiceUuid(uuid).build())
            }

            // remoteIds
            for (address in settings.withRemoteIds) {
                add(ScanFilter.Builder().setDeviceAddress(address).build())
            }

            // names
            for (name in settings.withNames) {
                add(ScanFilter.Builder().setDeviceName(name).build())
            }

            // keywords
            if (Build.VERSION.SDK_INT >= 33 && settings.withKeywords.isNotEmpty()) { // Android 13 (August 2022)
                // device must advertise a name
                add(ScanFilter.Builder()
                    .setAdvertisingDataType(ScanRecord.DATA_TYPE_LOCAL_NAME_SHORT).build())
                add(ScanFilter.Builder()
                    .setAdvertisingDataType(ScanRecord.DATA_TYPE_LOCAL_NAME_COMPLETE).build())
            }

            // msd
            for (msd in settings.withMsd) {
                val mask = msd.mask
                add(if (mask == null || mask.isEmpty()) {
                    ScanFilter.Builder().setManufacturerData(msd.manufacturerId.toInt(), msd.data).build()
                } else {
                    ScanFilter.Builder().setManufacturerData(msd.manufacturerId.toInt(), msd.data, mask).build()
                })
            }

            // service data
            for (sd in settings.withServiceData) {
                val uuid = ParcelUuid.fromString(Proto.uuid128(sd.service))
                val mask = sd.mask
                add(if (mask == null || mask.isEmpty()) {
                    ScanFilter.Builder().setServiceData(uuid, sd.data).build()
                } else {
                    ScanFilter.Builder().setServiceData(uuid, sd.data, mask).build()
                })
            }
        }

        // remember for later
        scanSettings = settings

        // clear seen devices
        advSeen.clear()
        scanCounts.clear()

        scanner.startScan(filters, scanSettingsNative, scanCallback)

        isScanning = true
    }

    override fun stopScan() {
        val scanner = requireAdapter().bluetoothLeScanner
        if (scanner != null) {
            scanner.stopScan(scanCallback)
            isScanning = false
        }
    }

    override fun getSystemDevices(
        withServices: List<String>,
        callback: (Result<List<BmBluetoothDevice>>) -> Unit,
    ) = launch(callback) {
        requireAdapter()
        val perms = if (Build.VERSION.SDK_INT >= 31) connectPermissions() else emptyList()
        requirePermissions(perms) { perm -> "Permission $perm required to get system devices" }

        // this includes devices connected by other apps
        val devices = bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT) ?: emptyList()
        devices.map { Proto.bmBluetoothDevice(it) }
    }

    override fun getBondedDevices(callback: (Result<List<BmBluetoothDevice>>) -> Unit) = launch(callback) {
        val a = requireAdapter()
        val perms = if (Build.VERSION.SDK_INT >= 31) connectPermissions() else emptyList()
        requirePermissions(perms) { perm -> "Permission $perm required to get bonded devices" }

        val bonded = a.bondedDevices ?: emptySet()
        bonded.map { Proto.bmBluetoothDevice(it) }
    }

    override fun connect(address: String, callback: (Result<Unit>) -> Unit) = launch(callback) {
        val a = requireAdapter()
        requirePermissions(connectPermissions()) { perm -> "Permission $perm required for new connection" }

        // check adapter
        requireAdapterOn()

        // already connected?
        if (synchronized(stateLock) { connections[address]?.isConnected == true }) {
            log(LogLevel.DEBUG, "already connected")
            return@launch // no work to do
        }

        // completes via onConnectionStateChange. Bespoke (not awaitSlot):
        // the slot lives on a DeviceConnection that may not exist yet, so
        // registration and connectGatt happen in one atomic block.
        suspendCancellableCoroutine<Unit> { cont ->
            val error = synchronized(stateLock) {
                val existing = connections[address]
                if (existing?.isConnecting == true) {
                    if (existing.pendingConnect != null) {
                        return@synchronized operationInProgress()
                    }
                    // already connecting? this continuation completes on CONNECTED
                    log(LogLevel.DEBUG, "already connecting")
                    existing.pendingConnect = cont
                    return@synchronized null
                }

                // connect (no autoConnect - it is not supported)
                val device = a.getRemoteDevice(address)
                val gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
                    ?: return@synchronized FlutterError(
                        BluebirdErrorCode.GATT_ERROR.wire, "device.connectGatt returned null", null)

                // add to currently connecting peripherals
                val conn = DeviceConnection(address, gatt)
                conn.pendingConnect = cont
                connections[address] = conn
                null
            }
            if (error != null) {
                cont.resumeWithException(error)
                return@suspendCancellableCoroutine
            }
            cont.invokeOnCancellation {
                synchronized(stateLock) {
                    val c = connections[address]
                    if (c?.pendingConnect === cont) c.pendingConnect = null
                }
            }
        }
    }

    override fun disconnect(address: String, callback: (Result<Unit>) -> Unit) = launch(callback) {
        // fast paths: returns the connection to tear down,
        // or null when there is nothing left to await
        val conn = synchronized(stateLock) {
            val c = connections[address]

            // already disconnected?
            if (c == null) {
                log(LogLevel.DEBUG, "already disconnected")
                return@synchronized null // no work to do
            }

            // was connecting? cancel it
            if (c.isConnecting) {
                log(LogLevel.DEBUG, "disconnect: cancelling connection in progress")

                // disconnect & cleanup
                c.gatt.disconnect()
                connections.remove(address)
                c.gatt.close()

                // fail the pending connect
                c.pendingConnect?.also { c.pendingConnect = null }?.resumeWithException(
                    FlutterError(BluebirdErrorCode.USER_CANCELED.wire, "connection canceled", null))

                emitEvent(BmConnectionStateEvent(
                    address = address,
                    connectionState = BmConnectionStateEnum.DISCONNECTED,
                    disconnectReasonCode = USER_CANCELED_ERROR_CODE,
                    disconnectReasonString = "connection canceled",
                ))
                return@synchronized null
            }

            c
        } ?: return@launch

        // connected; completes via onConnectionStateChange
        conn.awaitDisconnect {
            synchronized(stateLock) {
                conn.gatt.disconnect()
            }
        }
    }

    override fun discoverServices(
        address: String,
        callback: (Result<List<BmBluetoothService>>) -> Unit,
    ) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt

        // completes via onServicesDiscovered
        conn.awaitGatt(GattOp.DiscoverServices) {
            if (!gatt.discoverServices()) {
                throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.discoverServices() returned false", null)
            }
        }
    }

    override fun readCharacteristic(
        address: String,
        characteristic: BmCharacteristicRef,
        callback: (Result<ByteArray>) -> Unit,
    ) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt
        val chr = resolveCharacteristicOrThrow(gatt, characteristic)

        // check readable
        if (!chr.canRead) {
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "The READ property is not supported by this BLE characteristic", null)
        }

        // completes via onCharacteristicRead
        conn.awaitGatt(GattOp.ReadChar(Proto.charKey(chr))) {
            if (!gatt.readCharacteristic(chr)) {
                throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.readCharacteristic() returned false", null)
            }
        }
    }

    override fun writeCharacteristic(
        address: String,
        characteristic: BmCharacteristicRef,
        writeType: BmWriteType,
        allowLongWrite: Boolean,
        value: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt
        val chr = resolveCharacteristicOrThrow(gatt, characteristic)

        val writeTypeInt = when (writeType) {
            BmWriteType.WITH_RESPONSE -> BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            BmWriteType.WITHOUT_RESPONSE -> BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }

        // check writeable
        if (writeTypeInt == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
            if (!chr.canWriteNoResponse) {
                throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                    "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic", null)
            }
        } else {
            if (!chr.canWrite) {
                throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                    "The WRITE property is not supported by this BLE characteristic", null)
            }
        }

        // check maximum payload
        val maxLen = getMaxPayload(address, writeTypeInt, allowLongWrite)
        if (value.size > maxLen) {
            val a = if (writeType == BmWriteType.WITH_RESPONSE) "withResponse" else "withoutResponse"
            val b = if (writeType == BmWriteType.WITH_RESPONSE) {
                if (allowLongWrite) ", allowLongWrite" else ", noLongWrite"
            } else {
                ""
            }
            throw FlutterError(BluebirdErrorCode.INVALID_ARGUMENT.wire,
                "data longer than allowed. value.length: ${value.size} > max: $maxLen ($a$b)", null)
        }

        // completes via onCharacteristicWrite
        conn.awaitGatt<Unit>(GattOp.WriteChar(Proto.charKey(chr))) {
            gatt.writeCharacteristicCompat(chr, value, writeTypeInt)
        }
    }

    override fun readDescriptor(
        address: String,
        descriptor: BmDescriptorRef,
        callback: (Result<ByteArray>) -> Unit,
    ) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt
        val desc = resolveDescriptorOrThrow(gatt, descriptor)

        // completes via onDescriptorRead
        conn.awaitGatt(GattOp.ReadDesc(Proto.charKey(desc.characteristic), Proto.uuid128(desc.uuid))) {
            if (!gatt.readDescriptor(desc)) {
                throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.readDescriptor() returned false", null)
            }
        }
    }

    override fun writeDescriptor(
        address: String,
        descriptor: BmDescriptorRef,
        value: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt
        val desc = resolveDescriptorOrThrow(gatt, descriptor)

        // check mtu
        val mtu = conn.mtu
        if ((mtu - 3) < value.size) {
            throw FlutterError(BluebirdErrorCode.INVALID_ARGUMENT.wire,
                "data longer than mtu allows. dataLength: ${value.size} > max: ${mtu - 3}", null)
        }

        // completes via onDescriptorWrite
        conn.awaitGatt<Unit>(GattOp.WriteDesc(Proto.charKey(desc.characteristic), Proto.uuid128(desc.uuid))) {
            gatt.writeDescriptorCompat(desc, value)
        }
    }

    override fun setNotifyValue(
        address: String,
        characteristic: BmCharacteristicRef,
        forceIndications: Boolean,
        enable: Boolean,
        callback: (Result<Boolean>) -> Unit,
    ) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt

        // wait if any device is bonding (increases reliability)
        waitIfBonding()

        val chr = resolveCharacteristicOrThrow(gatt, characteristic)

        // configure local Android device to listen for characteristic changes
        if (!gatt.setCharacteristicNotification(chr, enable)) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire,
                "gatt.setCharacteristicNotification($enable) returned false", null)
        }

        // find cccd descriptor
        val cccd = chr.descriptors.firstOrNull { Proto.uuid128(it.uuid) == Proto.uuid128(CCCD) }
        if (cccd == null) {
            // Some ble devices do not actually need their CCCD updated.
            // thus setCharacteristicNotification() is all that is required to enable notifications.
            // The arduino "bluno" devices are an example.
            log(LogLevel.WARNING, "CCCD descriptor for characteristic not found: ${Proto.uuidStr(chr.uuid)}")
            return@launch true
        }

        // determine value to write
        val descriptorValue: ByteArray
        if (enable) {
            if (!chr.canIndicate && !chr.canNotify) {
                throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                    "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic", null)
            }

            if (forceIndications && !chr.canIndicate) {
                throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                    "INDICATE not supported by this BLE characteristic", null)
            }

            // If a characteristic supports both notifications and indications,
            // we use notifications. This matches how CoreBluetooth works on iOS.
            // Except of course, if forceIndications is enabled.
            descriptorValue = when {
                forceIndications -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                chr.canNotify -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                else -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            }
        } else {
            descriptorValue = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        }

        // completes when the CCCD write confirms (onDescriptorWrite)
        conn.awaitGatt(GattOp.SetNotify(Proto.charKey(chr))) {
            gatt.writeDescriptorCompat(cccd, descriptorValue, label = "cccd")
        }
    }

    override fun requestMtu(address: String, mtu: Long, callback: (Result<Long>) -> Unit) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt

        // completes via onMtuChanged
        conn.awaitGatt(GattOp.Mtu) {
            if (!gatt.requestMtu(mtu.toInt())) {
                throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.requestMtu() returned false", null)
            }
        }
    }

    override fun readRssi(address: String, callback: (Result<Long>) -> Unit) = launch(callback) {
        val conn = requireConnected(address)
        val gatt = conn.gatt

        // completes via onReadRemoteRssi
        conn.awaitGatt(GattOp.Rssi) {
            if (!gatt.readRemoteRssi()) {
                throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.readRemoteRssi() returned false", null)
            }
        }
    }

    override fun requestConnectionPriority(address: String, connectionPriority: BmConnectionPriorityEnum) {
        val gatt = requireConnected(address).gatt

        if (!gatt.requestConnectionPriority(Proto.bmConnectionPriorityParse(connectionPriority))) {
            throw FlutterError(BluebirdErrorCode.GATT_ERROR.wire, "gatt.requestConnectionPriority() returned false", null)
        }
    }

    override fun getPhySupport(): BmPhySupport {
        if (Build.VERSION.SDK_INT < 26) { // Android 8.0 (August 2017)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "Only supported on devices >= API 26. This device == ${Build.VERSION.SDK_INT}", null)
        }
        val a = requireAdapter()
        return BmPhySupport(le2M = a.isLe2MPhySupported, leCoded = a.isLeCodedPhySupported)
    }

    override fun setPreferredPhy(
        address: String,
        txPhy: Long,
        rxPhy: Long,
        phyOptions: Long,
        callback: (Result<Unit>) -> Unit,
    ) = launch(callback) {
        if (Build.VERSION.SDK_INT < 26) { // Android 8.0 (August 2017)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "Only supported on devices >= API 26. This device == ${Build.VERSION.SDK_INT}", null)
        }

        val conn = requireConnected(address)
        val gatt = conn.gatt

        // completes via onPhyUpdate
        conn.awaitGatt<Unit>(GattOp.Phy) {
            gatt.setPreferredPhy(txPhy.toInt(), rxPhy.toInt(), phyOptions.toInt())
        }
    }

    override fun getBondState(address: String): BmBondStateEnum {
        val device = requireAdapter().getRemoteDevice(address)
        return Proto.bmBondStateEnum(device.bondState)
    }

    override fun createBond(address: String, pin: ByteArray?, callback: (Result<Boolean>) -> Unit) = launch(callback) {
        val a = requireAdapter()

        if (pin != null) {
            bondingPins[address] = pin
        }

        // check connection
        val conn = requireConnected(address)

        val device = a.getRemoteDevice(address)

        // already bonded?
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            log(LogLevel.WARNING, "already bonded")
            return@launch true // no work to do
        }

        // completes via the bond state receiver
        conn.awaitBond {
            // bonding already in progress? wait for completion
            if (device.bondState == BluetoothDevice.BOND_BONDING) {
                log(LogLevel.WARNING, "bonding already in progress")
            } else if (!device.createBond()) {
                throw FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "device.createBond() returned false", null)
            }
        }
    }

    override fun removeBond(address: String, callback: (Result<Boolean>) -> Unit) = launch(callback) {
        val a = requireAdapter()

        val device = a.getRemoteDevice(address)

        // already removed?
        if (device.bondState == BluetoothDevice.BOND_NONE) {
            log(LogLevel.WARNING, "already not bonded")
            return@launch true // no work to do
        }

        // completes via the bond state receiver
        awaitRemoveBond(address) {
            val rv = try {
                val removeBondMethod = device.javaClass.getMethod("removeBond")
                removeBondMethod.invoke(device) as Boolean
            } catch (e: Exception) {
                throw FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "device.removeBond() failed: $e", null)
            }
            if (!rv) {
                throw FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "device.removeBond() returned false", null)
            }
        }
    }

    override fun clearGattCache(address: String, callback: (Result<Unit>) -> Unit) = launch(callback) {
        val gatt = requireConnected(address).gatt

        try {
            val refreshMethod = gatt.javaClass.getMethod("refresh")
            refreshMethod.invoke(gatt)
            // mirror the Java plugin: complete immediately after invoking
        } catch (e: Exception) {
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "gatt.refresh() unsupported on this android version: $e", null)
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // adapter state receiver

    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) {
                return
            }

            val adapterState = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)

            log(LogLevel.DEBUG, "OnAdapterStateChanged: ${Proto.adapterStateString(adapterState)}")

            // stop scanning when adapter is turned back on.
            // Otherwise, scanning automatically resumes when the adapter is
            // turned back on. I don't think most users expect that.
            if (adapterState == BluetoothAdapter.STATE_ON) {
                stopScanInternal("Bluetooth Restarted")
            }

            emitEvent(BmAdapterStateEvent(Proto.bmAdapterStateEnum(adapterState)))

            // disconnect all devices
            if (adapterState == BluetoothAdapter.STATE_TURNING_OFF ||
                adapterState == BluetoothAdapter.STATE_OFF
            ) {
                failAllPending(FlutterError(BluebirdErrorCode.ADAPTER_OFF.wire, "the bluetooth adapter was turned off", null))
                synchronized(stateLock) {
                    disconnectAllDevices("adapterTurnOff")
                }
            }
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // pairing request receiver

    private val pairRequestReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_PAIRING_REQUEST) {
                return
            }

            val device: BluetoothDevice = intent.getParcelableExtraCompat(BluetoothDevice.EXTRA_DEVICE) ?: return

            val remoteId = device.address
            val pin = bondingPins[remoteId]
            if (pin != null) {
                log(LogLevel.DEBUG, "Setting PIN code for $remoteId: ${Proto.bytesToHex(pin)}")
                if (!device.setPin(pin)) {
                    log(LogLevel.ERROR, "setPin() failed on $remoteId")
                }
                bondingPins.remove(remoteId)
            }
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // bond state receiver

    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                return
            }

            val device: BluetoothDevice = intent.getParcelableExtraCompat(BluetoothDevice.EXTRA_DEVICE) ?: return

            val cur = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            val prev = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)

            log(LogLevel.DEBUG, "OnBondStateChanged: ${Proto.bondStateString(cur)} prev: ${Proto.bondStateString(prev)}")

            val remoteId = device.address

            // remember which devices are currently bonding
            if (cur == BluetoothDevice.BOND_BONDING) {
                bondingDevices[remoteId] = device
            } else {
                bondingDevices.remove(remoteId)
            }

            // complete in-flight bond operations on terminal states
            when (cur) {
                BluetoothDevice.BOND_BONDED -> {
                    takePendingBond(remoteId)?.resume(true)
                }
                BluetoothDevice.BOND_NONE -> {
                    takePendingBond(remoteId)?.resumeWithException(
                        FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "bond attempt failed (final state: bond-none)", null))
                    synchronized(stateLock) { pendingRemoveBond.remove(remoteId) }?.resume(true)
                    bondingPins.remove(remoteId)
                }
            }

            emitEvent(BmBondStateEvent(
                address = remoteId,
                bondState = Proto.bmBondStateEnum(cur),
                prevState = if (prev == -1) null else Proto.bmBondStateEnum(prev),
            ))
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // scan callback

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
            log(LogLevel.ERROR, "onScanFailed: ${Proto.scanFailedString(errorCode)}")

            emitEvent(BmScanFailedEvent(errorCode.toLong(), Proto.scanFailedString(errorCode)))
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // gatt callback

    /**
     * Logs the GATT [status] for [label] and completes the device's pending
     * GATT operation, if there is one and [expected] matches its kind:
     * resumes it with [value] on GATT_SUCCESS, else fails it with the
     * corresponding gatt error. Returns whether an operation was completed —
     * unsolicited callbacks (e.g. a peer-initiated MTU change) match no
     * pending op and return false (event-only). With [logUnmatched] false,
     * nothing is logged unless an operation was completed.
     */
    private fun completeGatt(
        label: String,
        gatt: BluetoothGatt,
        status: Int,
        value: Any? = null,
        logUnmatched: Boolean = true,
        expected: (GattOp) -> Boolean,
    ): Boolean {
        val pending = takePendingGatt(gatt, expected)

        if (pending != null || logUnmatched) {
            val level = if (status == BluetoothGatt.GATT_SUCCESS) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "$label: status: ${Proto.gattErrorString(status)} ($status)")
        }
        if (pending == null) {
            return false
        }

        if (status == BluetoothGatt.GATT_SUCCESS) {
            pending.cont.resume(value)
        } else {
            pending.cont.resumeWithException(gattError(status))
        }
        return true
    }

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            synchronized(stateLock) {
                log(LogLevel.DEBUG, "onConnectionStateChange: ${Proto.connectionStateString(newState)}")
                log(LogLevel.DEBUG, "  status: ${Proto.hciStatusString(status)}")

                // android never uses this callback with enums values of CONNECTING or DISCONNECTING,
                // (they're only used for gatt.getConnectionState()), but just to be
                // future proof, explicitly ignore anything else. iOS & macOS is the same way.
                if (newState != BluetoothProfile.STATE_CONNECTED &&
                    newState != BluetoothProfile.STATE_DISCONNECTED
                ) {
                    return
                }

                val remoteId = gatt.device.address

                // edge case. see function for details
                if (handleUnexpectedConnectionEvents(gatt, newState, remoteId)) {
                    return
                }

                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    val conn = connections[remoteId]
                    if (conn != null) {
                        conn.state = DeviceConnection.State.CONNECTED
                        conn.gatt = gatt
                        conn.mtu = 23 // default minimum mtu

                        conn.pendingConnect?.also { conn.pendingConnect = null }?.resume(Unit)
                    }

                    emitEvent(BmConnectionStateEvent(
                        address = remoteId,
                        connectionState = BmConnectionStateEnum.CONNECTED,
                        disconnectReasonCode = null,
                        disconnectReasonString = null,
                    ))
                } else {
                    // remove from connected devices
                    val conn = connections.remove(remoteId)

                    // remove from currently bonding devices & cached PINs
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // it is important to close after disconnection, otherwise we will
                    // quickly run out of bluetooth resources, preventing new connections
                    gatt.close()

                    // complete in-flight ops for this device
                    if (conn != null) {
                        conn.pendingDisconnect?.also { conn.pendingDisconnect = null }?.resume(Unit)
                        conn.pendingConnect?.also { conn.pendingConnect = null }?.resumeWithException(
                            FlutterError(BluebirdErrorCode.GATT_ERROR.wire, Proto.hciStatusString(status), status))
                        conn.failAllPending(
                            FlutterError(BluebirdErrorCode.DEVICE_DISCONNECTED.wire, "device is disconnected", null))
                    }

                    emitEvent(BmConnectionStateEvent(
                        address = remoteId,
                        connectionState = BmConnectionStateEnum.DISCONNECTED,
                        disconnectReasonCode = status.toLong(),
                        disconnectReasonString = Proto.hciStatusString(status),
                    ))
                }
            }
        }

        // Android has an annoying edge case. If disconnect is called right as the connection is being
        // established, Android sometimes ignores the request to disconnect and completes the connection
        // anyway. To handle this case, we make sure the device is still in our currently connecting
        // devices map, otherwise kill the connection since the user was not expecting it to connect.
        private fun handleUnexpectedConnectionEvents(gatt: BluetoothGatt, newState: Int, remoteId: String): Boolean {
            val conn = connections[remoteId]

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (conn == null || !conn.isConnecting) {
                    log(LogLevel.DEBUG, "[unexpected connection] disconnecting now")

                    // remove all record of the device
                    connections.remove(remoteId)
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // disconnect and close the connection straight away
                    gatt.disconnect()
                    gatt.close()

                    return true
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (conn == null) {
                    log(LogLevel.DEBUG, "[unexpected connection] disconnect complete")

                    // remove from currently bonding devices & cached PINs
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // close the connection
                    gatt.close()

                    return true
                }
            }
            return false
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onServicesDiscovered:")
            log(level, "  count: ${gatt.services.size}")
            log(level, "  status: $status ${Proto.gattErrorString(status)}")

            val pending = takePendingGatt(gatt) { it is GattOp.DiscoverServices } ?: return

            if (status != BluetoothGatt.GATT_SUCCESS) {
                pending.cont.resumeWithException(gattError(status))
                return
            }

            pending.cont.resume(gatt.services.map { Proto.bmBluetoothService(gatt, it) })
        }

        // detects the 0x2A05 "services changed" indication from the
        // Generic Attribute service
        private fun checkServicesReset(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Proto.uuidStr(characteristic.service.uuid) == "1801" &&
                Proto.uuidStr(characteristic.uuid) == "2a05"
            ) {
                emitEvent(BmServicesResetEvent(gatt.device.address))
            }
        }

        // this callback is only for notifications & indications
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            log(LogLevel.DEBUG, "onCharacteristicChanged:")
            log(LogLevel.DEBUG, "  chr: ${Proto.uuidStr(characteristic.uuid)}")

            checkServicesReset(gatt, characteristic)

            emitEvent(BmCharacteristicNotificationEvent(
                address = gatt.device.address,
                characteristic = Proto.characteristicRef(gatt, characteristic),
                value = value,
            ))
        }

        // this callback is only for explicit characteristic reads
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            checkServicesReset(gatt, characteristic)

            completeGatt("onCharacteristicRead: chr: ${Proto.uuidStr(characteristic.uuid)}", gatt, status, value) {
                it is GattOp.ReadChar && it.key == Proto.charKey(characteristic)
            }
        }

        // Pre-API-33 the framework only calls this deprecated overload; forward
        // to the ByteArray override. getValue() is safe here: it is populated
        // for changed/read callbacks (just not for writes). The SDK guard
        // avoids double delivery on API 33+, which calls both overloads.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < 33) {
                onCharacteristicChanged(gatt, characteristic, characteristic.value ?: ByteArray(0))
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (Build.VERSION.SDK_INT < 33) {
                onCharacteristicRead(gatt, characteristic, characteristic.value ?: ByteArray(0), status)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            // For "writeWithResponse", onCharacteristicWrite is called after the remote sends back a write response.
            // For "writeWithoutResponse", onCharacteristicWrite is called as long as there is still space left
            // in android's internal buffer. When the buffer is full, it delays calling onCharacteristicWrite
            // until there is at least ~50% free space again.

            completeGatt("onCharacteristicWrite: chr: ${Proto.uuidStr(characteristic.uuid)}", gatt, status, Unit) {
                it is GattOp.WriteChar && it.key == Proto.charKey(characteristic)
            }
        }

        override fun onDescriptorRead(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
            value: ByteArray,
        ) {
            val label = "onDescriptorRead: chr: ${Proto.uuidStr(descriptor.characteristic.uuid)}" +
                " desc: ${Proto.uuidStr(descriptor.uuid)}"
            completeGatt(label, gatt, status, value) {
                it is GattOp.ReadDesc &&
                    it.key == Proto.charKey(descriptor.characteristic) &&
                    it.descUuid == Proto.uuid128(descriptor.uuid)
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (Build.VERSION.SDK_INT < 33) {
                onDescriptorRead(gatt, descriptor, status, descriptor.value ?: ByteArray(0))
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val label = "onDescriptorWrite: chr: ${Proto.uuidStr(descriptor.characteristic.uuid)}" +
                " desc: ${Proto.uuidStr(descriptor.uuid)}"
            val key = Proto.charKey(descriptor.characteristic)

            // a CCCD write confirms a setNotifyValue request
            if (Proto.uuidStr(descriptor.uuid) == CCCD &&
                completeGatt(label, gatt, status, value = true, logUnmatched = false) {
                    it is GattOp.SetNotify && it.key == key
                }
            ) {
                return
            }

            completeGatt(label, gatt, status, Unit) {
                it is GattOp.WriteDesc && it.key == key && it.descUuid == Proto.uuid128(descriptor.uuid)
            }
        }

        override fun onReliableWriteCompleted(gatt: BluetoothGatt, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onReliableWriteCompleted:")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            completeGatt("onReadRemoteRssi: rssi: $rssi", gatt, status, rssi.toLong()) { it is GattOp.Rssi }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val remoteId = gatt.device.address

            // remember mtu (volatile field; safe to write from binder threads)
            connections[remoteId]?.mtu = mtu

            // unsolicited (peer-initiated) changes match no pending op: event-only
            completeGatt("onMtuChanged: mtu: $mtu", gatt, status, mtu.toLong()) { it is GattOp.Mtu }

            if (status == BluetoothGatt.GATT_SUCCESS) {
                // emitted for both solicited and unsolicited (peer-initiated) changes
                emitEvent(BmMtuChangedEvent(remoteId, mtu.toLong()))
            }
        }

        override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            completeGatt("onPhyUpdate: txPhy: $txPhy rxPhy: $rxPhy", gatt, status, Unit) { it is GattOp.Phy }
        }
    }
}
