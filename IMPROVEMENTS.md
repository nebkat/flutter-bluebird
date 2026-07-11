# Code Improvement Plan

Goal: super idiomatic, low-LOC code across all packages, making full use of
modern Dart / Kotlin / Swift, with conversions and plumbing pushed to the
protocol boundary. Findings are ordered by priority within each section;
LOC estimates are net savings.

Non-generated code today: ~2,000 LOC Dart (core), ~1,400 LOC Kotlin,
~1,800 LOC Swift, plus ~1,500 LOC parked Dart (linux/web, old protocol).
The proposals below remove roughly **700-900 LOC** while fixing real bugs.

---

## 1. Bugs found during this analysis (fix before refactoring)

### 1.1 `Mutex.protect` releases the lock before async work completes — **critical**

`utils.dart:315`:

```dart
Future<T> protect<T>(FutureOr<T> Function() f) async {
  await take();
  try {
    return f();        // BUG: returns the *future*; finally runs immediately
  } finally {
    give();
  }
}
```

In Dart, `return f()` inside `try` evaluates `f()` (which returns a pending
`Future` for async closures), runs `finally`, and *then* awaits. Verified
empirically: two `protect(() async { ... })` calls interleave
(`A start | B start | B end | A end`). Every "only one BLE operation at a
time" guarantee in the package (`Mutex.global`, `Mutex.scan`,
`Mutex.platform`, `Mutex.disconnect.protect`) is currently a no-op for
async closures. Fix is two characters:

```dart
return await f();
```

Consider a regression test alongside `uuid_test.dart`.

### 1.2 `Phy.leCoded.mask` returns the PHY *value*, not the *mask*

`bluetooth_utils.dart`:

```dart
int get mask => switch (this) {
      Phy.le1m => 1,
      Phy.le2m => 2,
      Phy.leCoded => 3,   // BUG: PHY_LE_CODED_MASK is 4; 3 == 1M|2M
    };
```

Android defines `PHY_LE_1M_MASK=1, PHY_LE_2M_MASK=2, PHY_LE_CODED_MASK=4`.
`Phy.leCoded.mask` should be `4` (i.e. `1 << index`). As written, callers
requesting coded PHY actually request 1M+2M.

### 1.3 Already fixed during this session (noted for completeness)

- `Uuid.==` was identity-based (`bytes.hashCode`) — broke notification
  routing, CCCD lookup, included-services resolution. Fixed; regression
  tests added.
- darwin MTU was captured before negotiation completed (always 23). Fixed
  with an upstream-style poller.

---

## 2. Cross-cutting architecture (biggest LOC wins)

### 2.1 Collapse the guard/timeout boilerplate into one invoke pipeline (~120 LOC)

Every operation currently repeats the same 5-layer sandwich, with the
function name string written up to **four times**:

```dart
device.ensureConnected("writeCharacteristic");
await Mutex.global.protect(() async {
  await Bluebird.invoke((p) => p.writeCharacteristic(...))
      .bluebirdEnsureAdapterIsOn("writeCharacteristic")
      .bluebirdEnsureDeviceIsConnected(device, "writeCharacteristic")
      .bluebirdTimeout(timeout, "writeCharacteristic");
});
```

× ~15 methods across `bluetooth_device.dart`, `bluetooth_characteristic.dart`,
`bluetooth_descriptor.dart`. (It has already produced one bug: `read()`
guards with the typo'd name `"readCharacteristics"`, characteristic.dart:64.)

Proposal — one operation runner that owns the whole pipeline; the name is
stated once:

```dart
// on BluetoothDevice
Future<T> op<T>(
  String name,
  Future<T> Function(BluebirdPlatform p) call, {
  Duration timeout = const Duration(seconds: 15),
  bool requiresConnection = true,   // pre-check + mid-flight guard
  System? platform,                 // ensurePlatform when non-null
  bool serialized = true,           // Mutex.global
}) { ... }
```

Method bodies become expression-bodied one-liners:

```dart
Future<int> readRssi({Duration timeout = _t15}) =>
    op("readRssi", (p) => p.readRssi(remoteId), timeout: timeout);

Future<void> write(List<int> value, {bool withoutResponse = false, ...}) =>
    device.op("writeCharacteristic",
        (p) => p.writeCharacteristic(device.remoteId, bm, _writeType(withoutResponse),
            allowLongWrite, Uint8List.fromList(value)),
        timeout: timeout);
```

This also lets the adapter-off / disconnected watchdogs be created once per
op instead of layering two extra `Completer`s per call.

### 2.2 Merge the twin future-guard extensions (~45 → ~18 LOC)

`bluebirdEnsureAdapterIsOn` and `bluebirdEnsureDeviceIsConnected` (utils.dart:41-105)
are the same 30-line completer dance differing only in the stream and the
error. Generalize:

```dart
extension<T> on Future<T> {
  /// Completes with [error] if [fatal] emits before this future completes.
  Future<T> failOn<S>(Stream<S> fatal, bool Function(S) isFatal,
          BluebirdException Function() error) =>
      Future.any([
        this,
        fatal.firstWhere(isFatal).then((_) => throw error()),
      ]);
}
```

(One caveat vs `Future.any`: the loser's error must not go unhandled —
keep the completer form if needed, but write it once.) The two public
guards become one-line wrappers, or disappear entirely into `op()`.

### 2.3 `BluebirdErrorCode` as a shared pigeon enum (kills the switch + all native string literals)

Why the hand-written map exists today: error codes cross the channel as
`PlatformException.code` **strings**, and pigeon cannot type that field.
But the enum can still be the single source of truth:

1. Move `BluebirdErrorCode` into `pigeons/messages.dart` (rename members to
   match the wire: `deviceDisconnected`, `adapterOff`, `userCanceled`,
   `bondFailed`, `gattError`, `notConnected`, `invalidIdentifier`,
   `unsupported`, `operationInProgress`, `permissionDenied`, `timeout`, …).
2. Convention: the wire string is the snake_case of the Dart name. Each
   side needs one ~3-line helper:
   - Kotlin (generated names are UPPER_SNAKE):
     `fun BluebirdErrorCode.wire() = name.lowercase()` →
     `FlutterError(BluebirdErrorCode.DEVICE_DISCONNECTED.wire(), ...)`
   - Swift: `extension BluebirdErrorCode { var wire: String { snakeCased(rawName) } }`
   - Dart: `BluebirdErrorCode? bluebirdCodeFromWire(String s) =>
       _wireNames[s]` where `_wireNames` is built once from `values`.
3. Delete `_bluebirdCodeForPlatformError` (bluebird.dart:423) and every
   hand-typed `"device_disconnected"` literal in Kotlin/Swift (~40 literal
   sites native-side become enum references, compiler-checked).

Note the current Dart enum members don't match the wire names
(`deviceIsDisconnected` vs `device_disconnected` etc.) — unifying fixes
that latent mismatch class permanently.

### 2.4 Typed, sealed app-event model (~50 LOC + type safety)

- `Bluebird._eventStream` is `StreamController<dynamic>`. Make the
  nine `On*Event` classes implement a `sealed class BluebirdEvent` (with an
  optional `BluetoothDevice? device` on the base); the stream becomes
  `StreamController<BluebirdEvent>` and `_onPlatformEvent`-style exhaustive
  switches become available to users too.
- `extractEventStream`'s `.where((m) => m is T).map((m) => m as T)` →
  `.where((m) => m is T).cast<T>()`, shared with the platform interface's
  identical `_eventsOf<T>()`.
- The event classes are pure data: with a sealed base + super parameters
  (`OnMtuChangedEvent(super.device, this.mtu)`), bluetooth_events.dart
  shrinks by roughly a third.

### 2.5 More pigeon-mirror typedefs (same treatment as the enums)

Already done for the four enums. Remaining 1:1 mirrors:

- `CharacteristicProperties` (characteristic.dart:149-186) is a
  field-for-field copy of `BmCharacteristicProperties` →
  `typedef CharacteristicProperties = BmCharacteristicProperties;` and keep
  the nice compact `toString` as an `extension` (`describe()` or similar).
  −25 LOC.
- `getPhySupport()` already returns raw `BmPhySupport` publicly —
  inconsistent with everything else being wrapped. Either
  `typedef PhySupport = BmPhySupport` (recommended, matches the new
  direction) or wrap it; today it's accidental.

---

## 3. Dart core, file-by-file

### utils.dart (354 → ~180 LOC)

| Item | Detail |
|---|---|
| `Mutex.protect` | bug — see §1.1 |
| `hexDecode` | **dead code** (no callers) — delete; also duplicates `_tryHexDecode` in uuid.dart |
| `StreamControllerReEmit.listen` | unused, and buggy (double-delivers `latestValue`, discards the subscription) — delete |
| `StreamControllerReEmit.stream` | `latestValue != null` + `latestValue!` on a non-nullable `T` is vestigial — body is just `_controller.stream.newStreamWithInitialValue(latestValue)` |
| `_NewStreamWithInitialValueTransformer` | 115 lines to prepend one value. A `StreamTransformer.fromBind`-based version with a merged controller lands at ~35 lines; the broadcast/single-sub split can share one code path |
| `FutureTimeout` extension | merge per §2.2 |
| `System.current` | good; consider `@visibleForTesting` setter documented for mocking |

### bluebird.dart (612 → ~520 LOC)

- `_bluebirdCodeForPlatformError` — replaced per §2.3.
- `invoke` wraps *every* call in `Mutex.platform` while callers additionally
  wrap in `Mutex.global` — after §1.1 is fixed, review whether both layers
  are needed (platform-level serialization exists to gate the hot-restart
  handshake; a simple `late final Future<void> _ready = _flutterRestart()`
  in the adapter could replace it).
- `startScan` body: `List.from(output.values)` → `output.values.toList()`;
  the buffered-listen + error unwind is fine but deserves extraction into a
  private `_beginScan(settings)` for readability.
- `ScanResult`/`AdvertisementData`: fine; `msd` getter could use a record
  `(low, high)` destructure but it's marginal.
- `MsdFilter`/`ServiceDataFilter._bm`: fine — already the `.bm` convention;
  rename `_bm` → `bm` for consistency with the attribute classes.

### bluetooth_device.dart (572 → ~430 LOC)

- ~120 lines evaporate via §2.1 (`op()` runner).
- `_attributeForId` re-parses `BluetoothAttributeId.fromBm(id)` per element —
  hoist out of the loop (or accept, lists are tiny).
- `onServicesReset`: `.map((m) {})` → `.map((_) {})` (or
  `Stream<void>.fromFuture`-free `map((_) => null)`); cosmetic.
- `handleConnectionStateEvent`: the delayed-subscription block reads well;
  could use `Future.microtask` instead of `Future.delayed(Duration.zero)`
  to state intent.
- `discoverServices` carries `// TODO: Use notifications` (line ~203) — the
  services-changed subscription should use `c.notifications.listen` once the
  notify stream API is blessed.

### bluetooth_characteristic.dart

- `read()` guard name typo `"readCharacteristics"` (line 64) — fixed for
  free by §2.1.
- `setNotifyValue` **discards the platform's bool** and returns
  `return true;` unconditionally (line 136). Android meaningfully returns
  the CCCD-write result; either return it or change the signature to
  `Future<void>`.
- The broadcast controller with `onListen/onCancel` auto-subscribe is a
  genuinely nice pattern — keep.

### platform interface

- `BluebirdPlatform` default method bodies silently succeed
  (`Future.value()` / empty lists). For an unimplemented platform this
  masks bugs — prefer `throw UnimplementedError('$runtimeType.connect')`
  in the base (the darwin/android adapters override everything anyway).
- `Uuid`: `bytes` should be an unmodifiable `Uint8List`; `Uuid.empty()` is
  unused — delete; `string128` is computed per comparison — cache
  (`late final`) since `Uuid` is immutable in practice.
- Consider documenting (in `pigeons/messages.dart`) the canonical uuid
  string form natives must emit (shortest, lowercase). With that contract
  stated, wire-level assertions become possible in debug builds.

---

## 4. Kotlin (bluebird_android, ~1,400 LOC → ~1,200)

The port was deliberately 1:1 with the Java. Now condense:

### 4.1 Host-method prologue/epilogue helpers (~90 LOC)

Three patterns repeat across the ~12 GATT host methods:

```kotlin
// prologue, ×11
val gatt = connectedGatt(address) ?: run {
  callback(Result.failure(notConnected())); return
}
// registration, ×10
if (!pending.register(key, callback)) return
// failure epilogue, ×10
if (!gatt.readCharacteristic(chr)) pending.fail(key, ...)
```

Introduce two inline higher-order helpers:

```kotlin
private inline fun <T> withConnectedGatt(
    address: String, callback: (Result<T>) -> Unit,
    block: (BluetoothGatt) -> Unit,
) = connectedGatt(address)?.let(block)
    ?: callback(Result.failure(notConnected()))

/** Registers [key]; runs [start]; fails the op if [start] throws or returns an error. */
private inline fun <T> startOperation(
    key: OpKey, callback: (Result<T>) -> Unit,
    start: () -> FlutterError?,
) {
  if (!pending.register(key, callback)) return
  start()?.let { pending.fail(key, it) }
}
```

`readCharacteristic` collapses from 27 lines to ~10.

### 4.2 Compat write extensions (~35 LOC)

The API-33 vs legacy branches are copy-pasted three times
(writeCharacteristic / writeDescriptor / setNotifyValue). Two extensions —
`BluetoothGatt.writeCharacteristicCompat(chr, value, type): FlutterError?`
and `BluetoothGatt.writeDescriptorCompat(desc, value): FlutterError?` —
centralize the `Build.VERSION` split and the error-string formatting.

### 4.3 OpKey field-cluster collapse (~30 LOC)

`ReadChar/WriteChar/SetNotify` and `ReadDesc/WriteDesc` share the
(svcUuid, svcInstance, chrUuid, chrInstance[, descUuid]) cluster. Collapse
to:

```kotlin
data class CharKey(val svcUuid: String, val svcInstance: Int,
                   val chrUuid: String, val chrInstance: Int)
sealed class OpKey {
  data class CharOp(override val address: String, val kind: Kind, val key: CharKey) : OpKey()
  data class DescOp(override val address: String, val kind: Kind, val key: CharKey, val descUuid: String) : OpKey()
  enum class Kind { READ, WRITE, NOTIFY }
  ...
}
```

`Proto.readCharKey/writeCharKey/setNotifyKey/readDescKey/writeDescKey`
become a single `charKey()` + two factory calls.

### 4.4 Property/permission sugar (~30 LOC)

- `BluetoothGattCharacteristic.canRead/canWrite/canNotify/canIndicate`
  extension vals replace six masked bit-tests.
- `withPermissions(perms, callback) { ... }` wrapper folds the
  `granted/perm` branch repeated in 6 methods.
- Scan filter building: `buildList { ... }` with collection-style adds.

### 4.5 Correctness nits

- `onMtuChanged` mutates `connections[remoteId]?.mtu` outside `stateLock`
  (benign Int write, but take the lock for consistency).
- `Permissions.lastEventId` could theoretically collide after reuse across
  re-attachments; reset or scope it per binding.
- Error-code audit came back clean (13 codes, no stragglers) — §2.3 will
  turn them into enum references.

### 4.6 Explicitly *not* recommended

Coroutines/androidx-lifecycle: the callback surface here is pigeon
completion lambdas + Binder-thread GATT callbacks; a coroutine layer would
add a dependency and an impedance mismatch for no LOC win.

---

## 5. Swift (bluebird_darwin, ~1,790 LOC → ~1,550)

The strongest "direct conversion from ObjC" smells live here:

### 5.1 Unify per-device state — mirror Kotlin's `DeviceConnection` (~50-80 LOC)

Seven address-keyed dictionaries must be mutated in lockstep
(`knownPeripherals`, `connectedPeripherals`, `connectingPeripherals`,
`discoveredServices`, `servicesToDiscover`, `characteristicsToDiscover`,
`peripheralMtu`), with cleanup sequences duplicated in didDisconnect,
adapter-off, and flutterRestart. Replace with:

```swift
final class PeripheralState {
  let peripheral: CBPeripheral
  var connection: ConnectionState = .connecting   // enum
  var mtu = 23
  var discoveredServices: [CBService] = []
  var servicesToDiscover: [CBService] = []
  var characteristicsToDiscover: [CBCharacteristic] = []
}
private var peripherals: [String: PeripheralState] = [:]
private var knownPeripherals: [String: CBPeripheral] = [:]  // strong-ref keepalive only
```

One `peripherals.removeValue(forKey:)` replaces five coordinated removals.

### 5.2 Delegate error-handling helper (~35-50 LOC)

17 delegate methods repeat:

```swift
if let error = error {
  log(.error, "didX: \(error.localizedDescription)")
  pending.x.take(address)?(.failure(cbError(error)))
} else {
  log(.debug, "didX")
  pending.x.take(address)?(.success(value))
}
```

One generic
`complete(_ pending:, _ error: Error?, _ label: String, success: @autoclosure () -> T)`
collapses each to one line. (This is the Swift analog of the Kotlin
`startOperation` runner.)

### 5.3 Idiom sweep (~40 LOC)

- `removeByIdentity` helper → `array.removeAll { $0 === object }`; the
  extract-mutate-reassign triples (`guard var toDiscover = ...`) →
  `servicesToDiscover[address]?.removeAll { $0 === service }`.
- Scan-filter matchers (`foundService`, `foundKeyword`, `foundRemoteId`,
  `foundMsd` in Proto.swift) are manual for-loops → `contains(where:)`
  one-liners.
- `== true` on optional-bool chains → `?? false`; redundant
  `else if error == nil` after an `if let error` branch.
- CCCD string `"2902"` → `CBUUID(string: CBUUIDClientCharacteristicConfigurationString)`.

### 5.4 What to keep as-is

The 25 ms MTU poll timer is the correct approach — CoreBluetooth has no
MTU callback; upstream Bluebird does the same (ours at least stops when no
device is connected). Don't chase a reactive replacement that doesn't
exist.

---

## 6. Parked packages (linux / web — old 7.0.0 protocol)

Both are commented out of the workspace pending interface stabilization.
When migrating, bake these in rather than porting the old shape:

- **linux** (1,131 LOC): ~11 near-identical device/service/characteristic/
  descriptor resolution blocks (lines ~292-1046). The new typed refs plus
  four small `_getX` helpers remove **~150-180 LOC**. Errors are currently
  `errorCode: 0` + `e.toString()` — map BlueZ exceptions onto the shared
  error enum (§2.3). Triple-nested subscription loops → collection-fors.
  The existing `uuid2` extension is defined but unused in half the sites.
- **web** (402 LOC): `_findCharacteristicOrThrow` / `_findDescriptorOrThrow`
  throw `UnimplementedError` with their real bodies commented out — 5 of
  the host methods are dead on arrival; three `TODO`s (service index,
  includedServices, event identifier) map directly onto the new
  `BmAttributeId`/ref model. This package needs a rewrite against the new
  interface more than a cleanup.

---

## 7. Protocol-level ideas (pigeon schema)

- **Error enum in the schema** — §2.3.
- **Canonical uuid form**: document (and assert debug-side) that natives
  emit shortest-form lowercase uuid strings. `Uuid` equality already
  normalizes, but a stated contract keeps raw string comparisons safe in
  generated-code contexts.
- **`BmAttributeId.instance`**: descriptors don't have instances; the Dart
  side models this as `int? index` but the wire type forces `instance: 0`.
  If the schema ever gets revisited, making `instance` nullable removes the
  `index ?? 0` normalization in `BluetoothAttributeId.==`.
- Pigeon cannot type uuid fields as `Uuid` (no custom scalar support) — do
  **not** hand-patch generated files; the `BluetoothAttributeId` boundary
  conversion is the right layer.

---

## 8. Suggested order of attack

| # | Change | Risk | Net LOC |
|---|---|---|---|
| 1 | `Mutex.protect` `return await` fix (+ test) | none | +6 (test) |
| 2 | `Phy.leCoded.mask` = 4 | none | 0 |
| 3 | `op()` invoke pipeline + delete twin guards | medium (touches every op) | −160 |
| 4 | BluebirdErrorCode → pigeon enum, all three languages | low | −60 |
| 5 | Sealed `BluebirdEvent` + typed event stream | low | −50 |
| 6 | `CharacteristicProperties`/`PhySupport` typedefs | low | −30 |
| 7 | utils.dart cleanup (dead code, transformer rewrite) | low | −140 |
| 8 | Kotlin helpers (§4.1-4.4) | low | −190 |
| 9 | Swift `PeripheralState` + delegate helper + idiom sweep (§5) | medium | −180 |
| 10 | linux/web migration to new protocol (when unparked) | high | −250+ |

Items 3-6 change public-ish surfaces and should land before the 8.0.0
interface is declared stable; 8-9 are internal and can land any time.
