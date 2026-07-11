// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.lib.flutter_blue_plus

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
import android.bluetooth.BluetoothStatusCodes
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

class FlutterBluePlusPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener,
    FlutterBluePlusHostApi {

    companion object {
        private const val TAG = "[FBP-Android]"
        private const val CCCD = "2902"
        private const val ENABLE_BLUETOOTH_REQUEST_CODE = 13106

        // random number defined by flutter blue plus.
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
    private val pending = PendingOperations(mainHandler)
    private val permissions = Permissions()

    // Prevents GATT callback threads & the platform thread from mutating
    // connection state concurrently (was mMethodCallMutex in the Java plugin).
    private val stateLock = Any()

    private val connections = ConcurrentHashMap<String, DeviceConnection>()
    private val bondingDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val bondingPins = ConcurrentHashMap<String, ByteArray>()
    private val advSeen = ConcurrentHashMap<String, String>()
    private val scanCounts = ConcurrentHashMap<String, Int>()
    private var scanSettings: BmScanSettings? = null

    private var sink: PigeonEventSink<BmEvent>? = null

    private val streamHandler = object : NativeEventsStreamHandler() {
        override fun onListen(p0: Any?, sink: PigeonEventSink<BmEvent>) {
            this@FlutterBluePlusPlugin.sink = sink
        }

        override fun onCancel(p0: Any?) {
            this@FlutterBluePlusPlugin.sink = null
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // helpers

    private fun log(level: LogLevel, message: String) {
        if (level.raw > logLevel.raw) {
            return
        }
        when (level) {
            LogLevel.WARNING -> Log.w(TAG, "[FBP] $message")
            LogLevel.ERROR -> Log.e(TAG, "[FBP] $message")
            else -> Log.d(TAG, "[FBP] $message")
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
        FlutterError("unsupported", "the device does not support bluetooth", null)

    private fun requireAdapter(): BluetoothAdapter = adapter() ?: throw bluetoothUnavailable()

    private fun <T> adapterOr(callback: (Result<T>) -> Unit): BluetoothAdapter? {
        val a = adapter()
        if (a == null) {
            callback(Result.failure(bluetoothUnavailable()))
        }
        return a
    }

    private fun isAdapterOn(): Boolean {
        // get adapterState, if we have permission
        return try {
            adapter()?.state == BluetoothAdapter.STATE_ON
        } catch (e: Exception) {
            false
        }
    }

    private fun connectedGatt(address: String): BluetoothGatt? =
        connections[address]?.takeIf { it.isConnected }?.gatt

    private fun notConnected() = FlutterError("not_connected", "device is not connected", null)

    private fun invalidIdentifier(detail: String) =
        FlutterError("invalid_identifier", "could not locate attribute: $detail", null)

    private fun gattError(status: Int, message: String? = null) =
        FlutterError("gatt_error", message ?: Proto.gattErrorString(status), status)

    private fun ensurePermissions(perms: List<String>, operation: (Boolean, String?) -> Unit) {
        permissions.ensurePermissions(context, activityBinding?.activity, perms, operation)
    }

    private fun connectPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) { // Android 12 (October 2021)
            listOf(Manifest.permission.BLUETOOTH_CONNECT)
        } else { // Android 11 (September 2020) and below
            listOf(Manifest.permission.BLUETOOTH)
        }

    // for highest reliability, it is recommended to not do
    // anything while the device is busy bonding.
    private fun waitIfBonding() {
        if (bondingDevices.isNotEmpty()) {
            log(LogLevel.DEBUG, "waiting for bonding to complete...")
            try {
                Thread.sleep(50)
            } catch (e: Exception) {
                // ignored
            }
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

        FlutterBluePlusHostApi.setUp(binding.binaryMessenger, this)
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

        // drop pending operations WITHOUT invoking them
        pending.clearAll()

        // stop scanning
        stopScanInternal("onDetachedFromEngine")

        synchronized(stateLock) {
            disconnectAllDevices("onDetachedFromEngine")
        }

        context?.unregisterReceiver(bondStateReceiver)
        context?.unregisterReceiver(pairRequestReceiver)
        context?.unregisterReceiver(adapterStateReceiver)
        context = null

        FlutterBluePlusHostApi.setUp(binding.binaryMessenger, null)
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
            pending.succeed(OpKey.TurnOn, resultCode == Activity.RESULT_OK)
            return true
        }
        return false // did not handle anything
    }

    /////////////////////////////////////////////////////////////////////////////
    // FlutterBluePlusHostApi

    override fun flutterRestart(): Long {
        log(LogLevel.DEBUG, "flutterRestart")

        // no adapter?
        val a = adapter() ?: return 0 // no work to do

        // stop scanning
        stopScanInternal("flutterRestart")

        // all dart state is reset after flutter restart
        // (i.e. Hot Restart) so also reset native state
        synchronized(stateLock) {
            disconnectAllDevices("flutterRestart")
        }

        // drop pending operations without invoking them
        pending.clearAll()

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

    override fun getAdapterName(callback: (Result<String>) -> Unit) {
        ensurePermissions(connectPermissions()) { _, _ ->
            val name = try {
                adapter()?.name
            } catch (e: SecurityException) {
                null
            }
            callback(Result.success(name ?: ""))
        }
    }

    override fun getAdapterState(): BmAdapterStateEnum {
        val state = try {
            adapter()?.state ?: -1
        } catch (e: Exception) {
            -1
        }
        return Proto.bmAdapterStateEnum(state)
    }

    override fun turnOn(callback: (Result<Boolean>) -> Unit) {
        val a = adapterOr(callback) ?: return
        ensurePermissions(connectPermissions()) { granted, perm ->
            if (!granted) {
                callback(Result.failure(FlutterError("permission_denied",
                    "Permission $perm required to turn Bluetooth on", null)))
                return@ensurePermissions
            }

            if (a.isEnabled) {
                callback(Result.success(true)) // no work to do
                return@ensurePermissions
            }

            val binding = activityBinding
            if (binding == null) {
                callback(Result.failure(FlutterError("unsupported",
                    "no foreground activity available to request Bluetooth enable", null)))
                return@ensurePermissions
            }

            if (!pending.register(OpKey.TurnOn, callback)) {
                return@ensurePermissions
            }

            // completes via onActivityResult
            val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            binding.activity.startActivityForResult(enableBtIntent, ENABLE_BLUETOOTH_REQUEST_CODE)
        }
    }

    @Suppress("DEPRECATION")
    override fun turnOff(callback: (Result<Boolean>) -> Unit) {
        val a = adapterOr(callback) ?: return

        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            callback(Result.failure(FlutterError("unsupported",
                "turnOff is not supported on Android 13 (API 33) and above", null)))
            return
        }

        if (!a.isEnabled) {
            callback(Result.success(false)) // no work to do
            return
        }

        callback(Result.success(a.disable()))
    }

    override fun startScan(settings: BmScanSettings, callback: (Result<Unit>) -> Unit) {
        val a = adapterOr(callback) ?: return

        val perms = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= 31) { // Android 12 (October 2021)
            perms.add(Manifest.permission.BLUETOOTH_SCAN)
            if (settings.androidUsesFineLocation) {
                perms.add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            // it is unclear why this is needed, but some phones throw a
            // SecurityException AdapterService getRemoteName, without it
            perms.add(Manifest.permission.BLUETOOTH_CONNECT)
        } else { // Android 11 (September 2020) and below
            perms.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }

        ensurePermissions(perms) { granted, perm ->
            if (!granted) {
                callback(Result.failure(FlutterError("permission_denied",
                    "Permission $perm required to scan devices", null)))
                return@ensurePermissions
            }

            // check adapter
            if (!isAdapterOn()) {
                callback(Result.failure(FlutterError("adapter_off", "Bluetooth must be turned on", null)))
                return@ensurePermissions
            }

            // get scanner
            val scanner = a.bluetoothLeScanner
            if (scanner == null) {
                callback(Result.failure(FlutterError("adapter_off",
                    "getBluetoothLeScanner() is null. Is the Adapter on?", null)))
                return@ensurePermissions
            }

            // build scan settings
            val builder = ScanSettings.Builder()
            builder.setScanMode(settings.androidScanMode.toInt())
            if (Build.VERSION.SDK_INT >= 26) { // Android 8.0 (August 2017)
                builder.setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
                builder.setLegacy(settings.androidLegacy)
            }
            val scanSettingsNative = builder.build()

            // set filters
            val filters = ArrayList<ScanFilter>()

            // services
            for (service in settings.withServices) {
                val uuid = ParcelUuid.fromString(Proto.uuid128(service))
                filters.add(ScanFilter.Builder().setServiceUuid(uuid).build())
            }

            // remoteIds
            for (address in settings.withRemoteIds) {
                filters.add(ScanFilter.Builder().setDeviceAddress(address).build())
            }

            // names
            for (name in settings.withNames) {
                filters.add(ScanFilter.Builder().setDeviceName(name).build())
            }

            // keywords
            if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
                if (settings.withKeywords.isNotEmpty()) {
                    // device must advertise a name
                    filters.add(ScanFilter.Builder()
                        .setAdvertisingDataType(ScanRecord.DATA_TYPE_LOCAL_NAME_SHORT).build())
                    filters.add(ScanFilter.Builder()
                        .setAdvertisingDataType(ScanRecord.DATA_TYPE_LOCAL_NAME_COMPLETE).build())
                }
            }

            // msd
            for (msd in settings.withMsd) {
                val mask = msd.mask
                val filter = if (mask == null || mask.isEmpty()) {
                    ScanFilter.Builder().setManufacturerData(msd.manufacturerId.toInt(), msd.data).build()
                } else {
                    ScanFilter.Builder().setManufacturerData(msd.manufacturerId.toInt(), msd.data, mask).build()
                }
                filters.add(filter)
            }

            // service data
            for (sd in settings.withServiceData) {
                val uuid = ParcelUuid.fromString(Proto.uuid128(sd.service))
                val mask = sd.mask
                val filter = if (mask == null || mask.isEmpty()) {
                    ScanFilter.Builder().setServiceData(uuid, sd.data).build()
                } else {
                    ScanFilter.Builder().setServiceData(uuid, sd.data, mask).build()
                }
                filters.add(filter)
            }

            // remember for later
            scanSettings = settings

            // clear seen devices
            advSeen.clear()
            scanCounts.clear()

            scanner.startScan(filters, scanSettingsNative, scanCallback)

            isScanning = true

            callback(Result.success(Unit))
        }
    }

    override fun stopScan() {
        val scanner = requireAdapter().bluetoothLeScanner
        if (scanner != null) {
            scanner.stopScan(scanCallback)
            isScanning = false
        }
    }

    override fun getSystemDevices(withServices: List<String>, callback: (Result<List<BmBluetoothDevice>>) -> Unit) {
        adapterOr(callback) ?: return
        val perms = if (Build.VERSION.SDK_INT >= 31) connectPermissions() else emptyList()
        ensurePermissions(perms) { granted, perm ->
            if (!granted) {
                callback(Result.failure(FlutterError("permission_denied",
                    "Permission $perm required to get system devices", null)))
                return@ensurePermissions
            }

            // this includes devices connected by other apps
            val devices = bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT) ?: emptyList()
            callback(Result.success(devices.map { Proto.bmBluetoothDevice(it) }))
        }
    }

    override fun getBondedDevices(callback: (Result<List<BmBluetoothDevice>>) -> Unit) {
        val a = adapterOr(callback) ?: return
        val perms = if (Build.VERSION.SDK_INT >= 31) connectPermissions() else emptyList()
        ensurePermissions(perms) { granted, perm ->
            if (!granted) {
                callback(Result.failure(FlutterError("permission_denied",
                    "Permission $perm required to get bonded devices", null)))
                return@ensurePermissions
            }

            val bonded = a.bondedDevices ?: emptySet()
            callback(Result.success(bonded.map { Proto.bmBluetoothDevice(it) }))
        }
    }

    override fun connect(address: String, callback: (Result<Unit>) -> Unit) {
        val a = adapterOr(callback) ?: return
        ensurePermissions(connectPermissions()) { granted, perm ->
            if (!granted) {
                callback(Result.failure(FlutterError("permission_denied",
                    "Permission $perm required for new connection", null)))
                return@ensurePermissions
            }

            // check adapter
            if (!isAdapterOn()) {
                callback(Result.failure(FlutterError("adapter_off", "Bluetooth must be turned on", null)))
                return@ensurePermissions
            }

            synchronized(stateLock) {
                val existing = connections[address]

                // already connected?
                if (existing?.isConnected == true) {
                    log(LogLevel.DEBUG, "already connected")
                    callback(Result.success(Unit)) // no work to do
                    return@ensurePermissions
                }

                // register completion; fails the new callback if a connect
                // for this device is already in flight
                if (!pending.register(OpKey.Connect(address), callback)) {
                    return@ensurePermissions
                }

                // already connecting? the freshly registered op completes on CONNECTED
                if (existing?.isConnecting == true) {
                    log(LogLevel.DEBUG, "already connecting")
                    return@ensurePermissions
                }

                // connect (no autoConnect - it is not supported)
                val device = a.getRemoteDevice(address)
                val gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)

                // error check
                if (gatt == null) {
                    pending.fail(OpKey.Connect(address),
                        FlutterError("gatt_error", "device.connectGatt returned null", null))
                    return@ensurePermissions
                }

                // add to currently connecting peripherals
                connections[address] = DeviceConnection(address, gatt)
            }
        }
    }

    override fun disconnect(address: String, callback: (Result<Unit>) -> Unit) {
        synchronized(stateLock) {
            val conn = connections[address]

            // already disconnected?
            if (conn == null) {
                log(LogLevel.DEBUG, "already disconnected")
                callback(Result.success(Unit)) // no work to do
                return
            }

            // was connecting? cancel it
            if (conn.isConnecting) {
                log(LogLevel.DEBUG, "disconnect: cancelling connection in progress")

                // disconnect & cleanup
                conn.gatt.disconnect()
                connections.remove(address)
                conn.gatt.close()

                // fail the pending connect
                pending.fail(OpKey.Connect(address),
                    FlutterError("user_canceled", "connection canceled", null))

                emitEvent(BmConnectionStateEvent(
                    address = address,
                    connectionState = BmConnectionStateEnum.DISCONNECTED,
                    disconnectReasonCode = USER_CANCELED_ERROR_CODE,
                    disconnectReasonString = "connection canceled",
                ))

                callback(Result.success(Unit))
                return
            }

            // connected; completes via onConnectionStateChange
            if (!pending.register(OpKey.Disconnect(address), callback)) {
                return
            }

            conn.gatt.disconnect()
        }
    }

    override fun discoverServices(address: String, callback: (Result<List<BmBluetoothService>>) -> Unit) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val key = OpKey.DiscoverServices(address)
        if (!pending.register(key, callback)) {
            return
        }

        if (!gatt.discoverServices()) {
            pending.fail(key, FlutterError("gatt_error", "gatt.discoverServices() returned false", null))
        }
    }

    override fun readCharacteristic(
        address: String,
        characteristic: BmCharacteristicRef,
        callback: (Result<ByteArray>) -> Unit,
    ) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val chr = Proto.resolveCharacteristic(gatt, characteristic)
        if (chr == null) {
            callback(Result.failure(invalidIdentifier(characteristic.toString())))
            return
        }

        // check readable
        if ((chr.properties and BluetoothGattCharacteristic.PROPERTY_READ) == 0) {
            callback(Result.failure(FlutterError("unsupported",
                "The READ property is not supported by this BLE characteristic", null)))
            return
        }

        val key = Proto.readCharKey(address, chr)
        if (!pending.register(key, callback)) {
            return
        }

        if (!gatt.readCharacteristic(chr)) {
            pending.fail(key, FlutterError("gatt_error", "gatt.readCharacteristic() returned false", null))
        }
    }

    @Suppress("DEPRECATION")
    override fun writeCharacteristic(
        address: String,
        characteristic: BmCharacteristicRef,
        writeType: BmWriteType,
        allowLongWrite: Boolean,
        value: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val chr = Proto.resolveCharacteristic(gatt, characteristic)
        if (chr == null) {
            callback(Result.failure(invalidIdentifier(characteristic.toString())))
            return
        }

        val writeTypeInt = when (writeType) {
            BmWriteType.WITH_RESPONSE -> BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            BmWriteType.WITHOUT_RESPONSE -> BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }

        // check writeable
        if (writeTypeInt == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
            if ((chr.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0) {
                callback(Result.failure(FlutterError("unsupported",
                    "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic", null)))
                return
            }
        } else {
            if ((chr.properties and BluetoothGattCharacteristic.PROPERTY_WRITE) == 0) {
                callback(Result.failure(FlutterError("unsupported",
                    "The WRITE property is not supported by this BLE characteristic", null)))
                return
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
            callback(Result.failure(FlutterError("invalid_argument",
                "data longer than allowed. value.length: ${value.size} > max: $maxLen ($a$b)", null)))
            return
        }

        val key = Proto.writeCharKey(address, chr)
        if (!pending.register(key, callback)) {
            return
        }

        // write characteristic
        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            val rv = gatt.writeCharacteristic(chr, value, writeTypeInt)
            if (rv != BluetoothStatusCodes.SUCCESS) {
                pending.fail(key, FlutterError("gatt_error",
                    "gatt.writeCharacteristic() returned $rv : ${Proto.bluetoothStatusString(rv)}", rv))
            }
        } else {
            // set value
            if (!chr.setValue(value)) {
                pending.fail(key, FlutterError("gatt_error", "characteristic.setValue() returned false", null))
                return
            }

            // write type
            chr.writeType = writeTypeInt

            // write char
            if (!gatt.writeCharacteristic(chr)) {
                pending.fail(key, FlutterError("gatt_error", "gatt.writeCharacteristic() returned false", null))
            }
        }
    }

    override fun readDescriptor(
        address: String,
        descriptor: BmDescriptorRef,
        callback: (Result<ByteArray>) -> Unit,
    ) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val desc = Proto.resolveDescriptor(gatt, descriptor)
        if (desc == null) {
            callback(Result.failure(invalidIdentifier(descriptor.toString())))
            return
        }

        val key = Proto.readDescKey(address, desc)
        if (!pending.register(key, callback)) {
            return
        }

        if (!gatt.readDescriptor(desc)) {
            pending.fail(key, FlutterError("gatt_error", "gatt.readDescriptor() returned false", null))
        }
    }

    @Suppress("DEPRECATION")
    override fun writeDescriptor(
        address: String,
        descriptor: BmDescriptorRef,
        value: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val desc = Proto.resolveDescriptor(gatt, descriptor)
        if (desc == null) {
            callback(Result.failure(invalidIdentifier(descriptor.toString())))
            return
        }

        // check mtu
        val mtu = connections[address]?.mtu ?: 23
        if ((mtu - 3) < value.size) {
            callback(Result.failure(FlutterError("invalid_argument",
                "data longer than mtu allows. dataLength: ${value.size} > max: ${mtu - 3}", null)))
            return
        }

        val key = Proto.writeDescKey(address, desc)
        if (!pending.register(key, callback)) {
            return
        }

        // write descriptor
        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            val rv = gatt.writeDescriptor(desc, value)
            if (rv != BluetoothStatusCodes.SUCCESS) {
                pending.fail(key, FlutterError("gatt_error",
                    "gatt.writeDescriptor() returned $rv : ${Proto.bluetoothStatusString(rv)}", rv))
            }
        } else {
            // set descriptor
            if (!desc.setValue(value)) {
                pending.fail(key, FlutterError("gatt_error", "descriptor.setValue() returned false", null))
                return
            }

            // write descriptor
            if (!gatt.writeDescriptor(desc)) {
                pending.fail(key, FlutterError("gatt_error", "gatt.writeDescriptor() returned false", null))
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun setNotifyValue(
        address: String,
        characteristic: BmCharacteristicRef,
        forceIndications: Boolean,
        enable: Boolean,
        callback: (Result<Boolean>) -> Unit,
    ) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        // wait if any device is bonding (increases reliability)
        waitIfBonding()

        val chr = Proto.resolveCharacteristic(gatt, characteristic)
        if (chr == null) {
            callback(Result.failure(invalidIdentifier(characteristic.toString())))
            return
        }

        // configure local Android device to listen for characteristic changes
        if (!gatt.setCharacteristicNotification(chr, enable)) {
            callback(Result.failure(FlutterError("gatt_error",
                "gatt.setCharacteristicNotification($enable) returned false", null)))
            return
        }

        // find cccd descriptor
        val cccd = chr.descriptors.firstOrNull { Proto.uuid128(it.uuid) == Proto.uuid128(CCCD) }
        if (cccd == null) {
            // Some ble devices do not actually need their CCCD updated.
            // thus setCharacteristicNotification() is all that is required to enable notifications.
            // The arduino "bluno" devices are an example.
            log(LogLevel.WARNING, "CCCD descriptor for characteristic not found: ${Proto.uuidStr(chr.uuid)}")
            callback(Result.success(true))
            return
        }

        // determine value to write
        val descriptorValue: ByteArray
        if (enable) {
            val canNotify = (chr.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY) > 0
            val canIndicate = (chr.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE) > 0

            if (!canIndicate && !canNotify) {
                callback(Result.failure(FlutterError("unsupported",
                    "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic", null)))
                return
            }

            if (forceIndications && !canIndicate) {
                callback(Result.failure(FlutterError("unsupported",
                    "INDICATE not supported by this BLE characteristic", null)))
                return
            }

            // If a characteristic supports both notifications and indications,
            // we use notifications. This matches how CoreBluetooth works on iOS.
            // Except of course, if forceIndications is enabled.
            descriptorValue = when {
                forceIndications -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                canNotify -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                else -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            }
        } else {
            descriptorValue = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        }

        // completes when the CCCD write confirms
        val key = Proto.setNotifyKey(address, chr)
        if (!pending.register(key, callback)) {
            return
        }

        // write descriptor
        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            val rv = gatt.writeDescriptor(cccd, descriptorValue)
            if (rv != BluetoothStatusCodes.SUCCESS) {
                pending.fail(key, FlutterError("gatt_error",
                    "gatt.writeDescriptor() returned $rv : ${Proto.bluetoothStatusString(rv)}", rv))
            }
        } else {
            // set new value
            if (!cccd.setValue(descriptorValue)) {
                pending.fail(key, FlutterError("gatt_error", "cccd.setValue() returned false", null))
                return
            }

            // update notifications on remote BLE device
            if (!gatt.writeDescriptor(cccd)) {
                pending.fail(key, FlutterError("gatt_error", "gatt.writeDescriptor() returned false", null))
            }
        }
    }

    override fun requestMtu(address: String, mtu: Long, callback: (Result<Long>) -> Unit) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val key = OpKey.Mtu(address)
        if (!pending.register(key, callback)) {
            return
        }

        if (!gatt.requestMtu(mtu.toInt())) {
            pending.fail(key, FlutterError("gatt_error", "gatt.requestMtu() returned false", null))
        }
    }

    override fun readRssi(address: String, callback: (Result<Long>) -> Unit) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val key = OpKey.Rssi(address)
        if (!pending.register(key, callback)) {
            return
        }

        if (!gatt.readRemoteRssi()) {
            pending.fail(key, FlutterError("gatt_error", "gatt.readRemoteRssi() returned false", null))
        }
    }

    override fun requestConnectionPriority(address: String, connectionPriority: BmConnectionPriorityEnum) {
        val gatt = connectedGatt(address) ?: throw notConnected()

        if (!gatt.requestConnectionPriority(Proto.bmConnectionPriorityParse(connectionPriority))) {
            throw FlutterError("gatt_error", "gatt.requestConnectionPriority() returned false", null)
        }
    }

    override fun getPhySupport(): BmPhySupport {
        if (Build.VERSION.SDK_INT < 26) { // Android 8.0 (August 2017)
            throw FlutterError("unsupported",
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
    ) {
        if (Build.VERSION.SDK_INT < 26) { // Android 8.0 (August 2017)
            callback(Result.failure(FlutterError("unsupported",
                "Only supported on devices >= API 26. This device == ${Build.VERSION.SDK_INT}", null)))
            return
        }

        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        // completes via onPhyUpdate
        if (!pending.register(OpKey.Phy(address), callback)) {
            return
        }

        gatt.setPreferredPhy(txPhy.toInt(), rxPhy.toInt(), phyOptions.toInt())
    }

    override fun getBondState(address: String): BmBondStateEnum {
        val device = requireAdapter().getRemoteDevice(address)
        return Proto.bmBondStateEnum(device.bondState)
    }

    override fun createBond(address: String, pin: ByteArray?, callback: (Result<Boolean>) -> Unit) {
        val a = adapterOr(callback) ?: return

        if (pin != null) {
            bondingPins[address] = pin
        }

        // check connection
        if (connectedGatt(address) == null) {
            callback(Result.failure(notConnected()))
            return
        }

        val device = a.getRemoteDevice(address)

        // already bonded?
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            log(LogLevel.WARNING, "already bonded")
            callback(Result.success(true)) // no work to do
            return
        }

        // completes via the bond state receiver
        val key = OpKey.CreateBond(address)
        if (!pending.register(key, callback)) {
            return
        }

        // bonding already in progress? wait for completion
        if (device.bondState == BluetoothDevice.BOND_BONDING) {
            log(LogLevel.WARNING, "bonding already in progress")
            return
        }

        // bond
        if (!device.createBond()) {
            pending.fail(key, FlutterError("bond_failed", "device.createBond() returned false", null))
        }
    }

    override fun removeBond(address: String, callback: (Result<Boolean>) -> Unit) {
        val a = adapterOr(callback) ?: return

        val device = a.getRemoteDevice(address)

        // already removed?
        if (device.bondState == BluetoothDevice.BOND_NONE) {
            log(LogLevel.WARNING, "already not bonded")
            callback(Result.success(true)) // no work to do
            return
        }

        // completes via the bond state receiver
        val key = OpKey.RemoveBond(address)
        if (!pending.register(key, callback)) {
            return
        }

        try {
            val removeBondMethod = device.javaClass.getMethod("removeBond")
            val rv = removeBondMethod.invoke(device) as Boolean
            if (!rv) {
                pending.fail(key, FlutterError("bond_failed", "device.removeBond() returned false", null))
            }
        } catch (e: Exception) {
            pending.fail(key, FlutterError("bond_failed", "device.removeBond() failed: $e", null))
        }
    }

    override fun clearGattCache(address: String, callback: (Result<Unit>) -> Unit) {
        val gatt = connectedGatt(address)
        if (gatt == null) {
            callback(Result.failure(notConnected()))
            return
        }

        try {
            val refreshMethod = gatt.javaClass.getMethod("refresh")
            refreshMethod.invoke(gatt)
            // mirror the Java plugin: complete immediately after invoking
            callback(Result.success(Unit))
        } catch (e: Exception) {
            callback(Result.failure(FlutterError("unsupported",
                "gatt.refresh() unsupported on this android version: $e", null)))
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // adapter state receiver

    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action

            // no change?
            if (action == null || BluetoothAdapter.ACTION_STATE_CHANGED != action) {
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
                pending.failAll(FlutterError("adapter_off", "the bluetooth adapter was turned off", null))
                synchronized(stateLock) {
                    disconnectAllDevices("adapterTurnOff")
                }
            }
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // pairing request receiver

    private val pairRequestReceiver = object : BroadcastReceiver() {
        @Suppress("DEPRECATION") // needed for compatibility
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action
            if (action == null || BluetoothDevice.ACTION_PAIRING_REQUEST != action) {
                return
            }

            val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            if (device == null) {
                return
            }

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
        @Suppress("DEPRECATION") // needed for compatibility
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action

            // no change?
            if (action == null || BluetoothDevice.ACTION_BOND_STATE_CHANGED != action) {
                return
            }

            val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            if (device == null) {
                return
            }

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

            // complete pending bond operations on terminal states
            when (cur) {
                BluetoothDevice.BOND_BONDED -> {
                    pending.succeed(OpKey.CreateBond(remoteId), true)
                }
                BluetoothDevice.BOND_NONE -> {
                    pending.fail(OpKey.CreateBond(remoteId),
                        FlutterError("bond_failed", "bond attempt failed (final state: bond-none)", null))
                    pending.succeed(OpKey.RemoveBond(remoteId), true)
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
                    }

                    pending.succeed(OpKey.Connect(remoteId), Unit)

                    emitEvent(BmConnectionStateEvent(
                        address = remoteId,
                        connectionState = BmConnectionStateEnum.CONNECTED,
                        disconnectReasonCode = null,
                        disconnectReasonString = null,
                    ))
                } else {
                    // remove from connected devices
                    connections.remove(remoteId)

                    // remove from currently bonding devices & cached PINs
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // it is important to close after disconnection, otherwise we will
                    // quickly run out of bluetooth resources, preventing new connections
                    gatt.close()

                    // complete pending ops for this device
                    pending.succeed(OpKey.Disconnect(remoteId), Unit)
                    pending.fail(OpKey.Connect(remoteId),
                        FlutterError("gatt_error", Proto.hciStatusString(status), status))
                    pending.failAllForDevice(remoteId,
                        FlutterError("device_disconnected", "device is disconnected", null))

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
            var unexpectedEvent = false
            val conn = connections[remoteId]

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (conn == null || !conn.isConnecting) {
                    log(LogLevel.DEBUG, "[unexpected connection] disconnecting now")

                    // this is an unexpected connection
                    unexpectedEvent = true

                    // remove all record of the device
                    connections.remove(remoteId)
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // disconnect and close the connection straight away
                    gatt.disconnect()
                    gatt.close()
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (conn == null) {
                    log(LogLevel.DEBUG, "[unexpected connection] disconnect complete")

                    // we have no record of this device, mark this is an unexpected event
                    unexpectedEvent = true

                    // remove from currently bonding devices & cached PINs
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // close the connection
                    gatt.close()
                }
            }
            return unexpectedEvent
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onServicesDiscovered:")
            log(level, "  count: ${gatt.services.size}")
            log(level, "  status: $status ${Proto.gattErrorString(status)}")

            val remoteId = gatt.device.address
            val key = OpKey.DiscoverServices(remoteId)

            if (status != BluetoothGatt.GATT_SUCCESS) {
                pending.fail(key, gattError(status))
                return
            }

            pending.succeed(key, gatt.services.map { Proto.bmBluetoothService(gatt, it) })
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
        fun onCharacteristicChangedCompat(
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
        fun onCharacteristicReadCompat(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            val level = if (status == BluetoothGatt.GATT_SUCCESS) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onCharacteristicRead:")
            log(level, "  chr: ${Proto.uuidStr(characteristic.uuid)}")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            checkServicesReset(gatt, characteristic)

            val key = Proto.readCharKey(gatt.device.address, characteristic)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, value)
            } else {
                pending.fail(key, gattError(status))
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            onCharacteristicChangedCompat(gatt, characteristic, value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            onCharacteristicReadCompat(gatt, characteristic, value, status)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            // getValue() was deprecated in API level 33 because the function makes it look like
            // you could always call getValue on a characteristic. But in reality, getValue()
            // only works after a *read* has been made, not a *write*.
            if (Build.VERSION.SDK_INT < 33) {
                onCharacteristicChangedCompat(gatt, characteristic, characteristic.value ?: ByteArray(0))
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            // getValue() was deprecated in API level 33 because the function makes it look like
            // you could always call getValue on a characteristic. But in reality, getValue()
            // only works after a *read* has been made, not a *write*.
            if (Build.VERSION.SDK_INT < 33) {
                onCharacteristicReadCompat(gatt, characteristic, characteristic.value ?: ByteArray(0), status)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            val level = if (status == BluetoothGatt.GATT_SUCCESS) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onCharacteristicWrite:")
            log(level, "  chr: ${Proto.uuidStr(characteristic.uuid)}")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            // For "writeWithResponse", onCharacteristicWrite is called after the remote sends back a write response.
            // For "writeWithoutResponse", onCharacteristicWrite is called as long as there is still space left
            // in android's internal buffer. When the buffer is full, it delays calling onCharacteristicWrite
            // until there is at least ~50% free space again.

            val key = Proto.writeCharKey(gatt.device.address, characteristic)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, Unit)
            } else {
                pending.fail(key, gattError(status))
            }
        }

        fun onDescriptorReadCompat(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
            value: ByteArray,
        ) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onDescriptorRead:")
            log(level, "  chr: ${Proto.uuidStr(descriptor.characteristic.uuid)}")
            log(level, "  desc: ${Proto.uuidStr(descriptor.uuid)}")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            val key = Proto.readDescKey(gatt.device.address, descriptor)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, value)
            } else {
                pending.fail(key, gattError(status))
            }
        }

        override fun onDescriptorRead(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
            value: ByteArray,
        ) {
            onDescriptorReadCompat(gatt, descriptor, status, value)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            // getValue() was deprecated in API level 33 because the api makes it look like
            // you could always call getValue on a descriptor. But in reality, getValue()
            // only works after a *read* has been made, not a *write*.
            if (Build.VERSION.SDK_INT < 33) {
                onDescriptorReadCompat(gatt, descriptor, status, descriptor.value ?: ByteArray(0))
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onDescriptorWrite:")
            log(level, "  chr: ${Proto.uuidStr(descriptor.characteristic.uuid)}")
            log(level, "  desc: ${Proto.uuidStr(descriptor.uuid)}")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            val remoteId = gatt.device.address

            // a CCCD write confirms a setNotifyValue request
            if (Proto.uuidStr(descriptor.uuid) == CCCD) {
                val notifyKey = Proto.setNotifyKey(remoteId, descriptor.characteristic)
                val result: Result<Any?> = if (status == BluetoothGatt.GATT_SUCCESS) {
                    Result.success(true)
                } else {
                    Result.failure(gattError(status))
                }
                if (pending.complete(notifyKey, result)) {
                    return
                }
            }

            val key = Proto.writeDescKey(remoteId, descriptor)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, Unit)
            } else {
                pending.fail(key, gattError(status))
            }
        }

        override fun onReliableWriteCompleted(gatt: BluetoothGatt, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onReliableWriteCompleted:")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onReadRemoteRssi:")
            log(level, "  rssi: $rssi")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            val key = OpKey.Rssi(gatt.device.address)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, rssi.toLong())
            } else {
                pending.fail(key, gattError(status))
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onMtuChanged:")
            log(level, "  mtu: $mtu")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            val remoteId = gatt.device.address

            // remember mtu
            connections[remoteId]?.mtu = mtu

            val key = OpKey.Mtu(remoteId)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, mtu.toLong())
                // emitted for both solicited and unsolicited (peer-initiated) changes
                emitEvent(BmMtuChangedEvent(remoteId, mtu.toLong()))
            } else {
                pending.fail(key, gattError(status))
            }
        }

        override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onPhyUpdate:")
            log(level, "  txPhy: $txPhy rxPhy: $rxPhy")
            log(level, "  status: ${Proto.gattErrorString(status)} ($status)")

            val key = OpKey.Phy(gatt.device.address)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                pending.succeed(key, Unit)
            } else {
                pending.fail(key, gattError(status))
            }
        }
    }
}
