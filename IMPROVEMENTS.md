# Code Improvement Plan — Round 2

Round 1 (Mutex/Phy bugs, Dart `op()` pipeline, shared `BluebirdErrorCode`,
sealed events, typedefs, utils rewrite, Kotlin helpers/OpKey collapse,
Swift `PeripheralState` unification) is fully applied and verified. This
round covers what a fresh deep-scan of the *refactored* code found.
Net: the Swift side is essentially done; the Kotlin side has one real
(minor) bug and one good LOC win left; the largest outstanding chunk
overall remains the parked linux/web migration.

---

## 1. Kotlin (bluebird_android)

### 1.1 `DeviceConnection.mtu` visibility bug — fix first (2 lines)

`getMaxPayload` (BluebirdPlugin.kt ~246) and the `writeDescriptor` MTU
check (~845) read `connections[address]?.mtu` on the platform thread
without synchronization, while `onMtuChanged` writes it under `stateLock`
from a binder thread. Int writes don't tear on the JVM, so this is a
*visibility* (stale read) issue, not corruption — the worst case is a
payload-size check against an outdated MTU. Cleanest minimal fix is
publication via volatile rather than locking the readers:

```kotlin
// DeviceConnection.kt
@Volatile var mtu: Int = 23
```

(The `synchronized` around the write in `onMtuChanged` can then go.)

### 1.2 GATT-callback completion boilerplate (~40-50 LOC) — the one big win left

Seven callbacks (`onCharacteristicRead/Write`, `onDescriptorRead/Write`,
`onReadRemoteRssi`, `onMtuChanged`, `onPhyUpdate`) still repeat:

```kotlin
val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
log(level, "onX:")
log(level, "  status: ${Proto.gattErrorString(status)} ($status)")
...
if (status == BluetoothGatt.GATT_SUCCESS) pending.succeed(key, value)
else pending.fail(key, gattError(status))
```

One helper collapses both halves:

```kotlin
/** Logs the callback outcome and completes [key]: success -> [value], else gatt_error. */
private fun completeGatt(label: String, key: OpKey, status: Int, value: Any? = null, detail: String = "") {
  val level = if (status == BluetoothGatt.GATT_SUCCESS) LogLevel.DEBUG else LogLevel.ERROR
  log(level, "$label:$detail status: ${Proto.gattErrorString(status)} ($status)")
  if (status == BluetoothGatt.GATT_SUCCESS) pending.succeed(key, value) else pending.fail(key, gattError(status))
}
```

Callbacks become 2-3 lines each. (`onMtuChanged` keeps its extra
mtu-cache + event emission; `onDescriptorWrite` keeps its CCCD branch.)

### 1.3 `Intent.getParcelableExtraCompat` (10-15 LOC)

The API-33 `getParcelableExtra` split appears twice (pair + bond
receivers):

```kotlin
inline fun <reified T : Parcelable> Intent.getParcelableExtraCompat(key: String): T? =
    if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(key, T::class.java)
    else @Suppress("DEPRECATION") getParcelableExtra(key)
```

### 1.4 Receiver action guards (6 lines)

The three receivers' null-checking preamble is over-built; `!=` already
handles null:

```kotlin
if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
```

(The scan proposed a helper function here — rejected; a one-line
comparison needs no helper.)

### 1.5 Optional polish

- `handleUnexpectedConnectionEvents`: replace the `var unexpectedEvent`
  flag with direct `return true` paths (~5 lines, reads better).
- `connect()` sits at 4 indent levels; extracting the `synchronized`
  body into `connectLocked()` flattens it (net-neutral LOC, readability).

Verified clean by the scan: PendingOperations API surface (no overlap),
Proto.kt parsers (inherent BLE-spec complexity), reflection uses
(`removeBond`/`refresh` — no public API exists), zero dead code.

---

## 2. Swift (bluebird_darwin) — essentially done

The deep-scan actively *rejected* the remaining candidates, with
reasoning worth recording:

- **Host-API connected-guard prologue (7×)**: a `withConnectedPeripheral`
  helper saves ~2 LOC/site but adds indirection over an idiomatic 3-line
  `guard`. Not worth it. (Contrast with Kotlin, where the same helper won
  because the prologue there was longer and paired with op registration.)
- **Discovery bookkeeping arrays**: O(n) identity removals only run
  during discovery (cold path), and the arrays are defensive against
  re-entrant discovery callbacks. A counter state machine saves ~8 lines
  but assumes each service reports exactly once. Keep.
- **Per-op `PendingMap` properties vs a Kotlin-style OpKey enum**: the
  typed per-op maps are *better* in Swift — the enum would force type
  erasure + casts. Keep. (The two languages diverge here by design.)
- **flutterRestart stale `peripherals` entries**: the scan suggested
  `peripherals.removeAll()` after cancelling — **rejected**: entries are
  intentionally retained so `didDisconnectPeripheral` callbacks drive the
  `connectedCount` hot-restart handshake polled by Dart; removing them
  early would report 0 while connections are still closing. Worth a
  short code comment explaining the retention, nothing more.

Scan found zero force-unwraps, zero unjustified `var`s, correct timer
lifecycle (`weak self`, double-start guard, idle stop), and correct
`PeripheralState` cleanup coverage.

---

## 3. Dart

- **Post-rename naming artifacts**: the mechanical `fbp→bluebird` sweep
  produced `bluebirdTimeout`, `bluebirdEnsureAdapterIsOn`,
  `bluebirdEnsureDeviceIsConnected` extension names. They're internal;
  consider shorter intent-named forms (`orTimeout(d, name)`,
  `untilAdapterOff(name)`, `untilDisconnected(device, name)`) — or leave,
  since `op()` is the only real consumer.
- Nothing else outstanding: analyze clean, event model sealed, wire enum
  shared, 9/9 tests green.

---

## 4. The big outstanding item: linux/web migration

Unchanged from round 1 — `bluebird_linux` (1,131 LOC, ~11 copy-pasted
resolution blocks) and `bluebird_web` (5 host methods stubbed) are still
parked on the pre-pigeon 7.0.0 interface (commented out of the
workspace). Migrating them onto the typed-ref + shared-error-enum
protocol is worth ~250+ LOC and, more importantly, brings all six
packages onto one protocol. This dwarfs everything above.

---

## Suggested order

| # | Change | Risk | Net LOC |
|---|---|---|---|
| 1 | `@Volatile` mtu (1.1) | none | 0 |
| 2 | `completeGatt` (1.2) | low | −45 |
| 3 | `getParcelableExtraCompat` + action guards (1.3/1.4) | none | −18 |
| 4 | Kotlin polish (1.5) | none | −5 |
| 5 | Swift retention comment in flutterRestart | none | +2 |
| 6 | linux/web migration (when unparked) | high | −250+ |
