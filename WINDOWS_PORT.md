# bluebird on Windows — port plan

A sixth platform package, `bluebird_windows`, built on C++/WinRT — plus the pigeon
fork it needs, the WinRT capabilities that don't exist, and the platform gating in
the core package that would reject Windows even where it works.

- **Target**: `packages/bluebird_windows`
- **Baseline**: Windows 10 1709+ (`GattSession` floor; Flutter requires Windows 10 anyway)
- **Toolchain**: Flutter 3.47.0, pigeon 27.1.x
- **Verification**: the ESP32-S3 fixture in `tools/esp32_peripheral`

## Picking this up on a Windows machine

```sh
git fetch && git checkout windows-port
```

Prerequisites beyond a normal checkout:

- **Visual Studio 2022** with the *Desktop development with C++* workload and the
  Windows 10/11 SDK. `flutter doctor` will confirm.
- **Flutter 3.47.0**, pinned — see the Toolchain section of `CLAUDE.md`.
  `fvm install 3.47.0 && fvm global 3.47.0`, or a plain SDK at that version.
- **The ESP32-S3 fixture** flashed, powered and advertising as `Bluebird-Test`,
  within radio range of the Windows machine. See `integration_test/README.md`.
- A Bluetooth LE radio that actually works in Windows' own Settings app — check
  that before blaming any of this code.

Nothing else transfers: the pigeon fork does not exist yet, and the example has no
`windows/` runner until phase 1 creates it.

## The shape of the work

The federation makes packaging trivial and the protocol makes it hard. A new
endorsed package is an afternoon; what costs real time is that pigeon's C++
generator refuses the current contract outright, and that WinRT models a BLE
connection as object lifetime rather than as a verb.

Everything below assumes the fork decision is made: we patch pigeon rather than
hand-write `Messages.g.cpp`, so the wire format stays derived from
`pigeons/messages.dart` instead of copied out of it by hand.

## Decisions, locked before code

| Area | Decision | Why |
| :--- | :--- | :--- |
| **Codegen** | Fork pigeon; commit the generated C++. | pigeon is a dev dependency of `bluebird_platform_interface` only, and the generated sources are already committed. The fork never reaches users — it produces source we check in, exactly like `Messages.g.kt` today. |
| **Sealed events** | Emit the 11 subclasses as independent structs; no base type. | The sealed hierarchy has no wire representation — each concrete event carries its own discriminator (150–160) and `BmEvent` carries none. C++ never needs a discriminated union, so real inheritance support is out of scope. |
| **Identity** | `remoteId` is the MAC string, as on Android. | WinRT takes a `uint64` address *and* a `BluetoothAddressType`. The type is not recoverable from the string, so the device registry caches it from the advertisement that introduced the device. |
| **Connection** | Connection is a held object, not a call. | `connect()` resolves `BluetoothLEDevice` and opens a `GattSession` with `MaintainConnection = true`, retained in a registry keyed by address; `disconnect()` releases both. `ConnectionStatusChanged` drives the state events. |
| **Threading** | One platform-thread hop in front of every channel touch. | WinRT completions and events arrive on arbitrary thread-pool threads; the event sink and pigeon replies must be used on the platform thread. A message-only window plus a work queue, established in phase 1 before any BLE code depends on it. |
| **Gating** | Replace OS checks with capability checks in the core package. | The 11 `ensurePlatform(System.isAndroid, …)` sites reject Windows before it reaches the implementation — including for bonding, which Windows genuinely supports. |

## Phases

Each phase ends at a gate that can be demonstrated, not just compiled. Phases 1 and
2 are the risky ones — everything after is volume work against a proven channel.

### 1. Fork pigeon, prove one event — 3–5 days

- Patch `CppGeneratorAdapter.validate` to drop the event-channel and sealed-class
  errors (`lib/src/pigeon_lib_internal.dart`).
- Override `writeEventChannelApi` in the C++ generator — a `StreamHandler`
  subclass, a typed sink wrapper, and a `SetUp()`-style registration matching
  pigeon's existing C++ HostApi convention rather than Kotlin's `register()`.
- Emit the method codec:
  `StandardMethodCodec::GetInstance(&PigeonCodecSerializer::GetInstance())`,
  guarded on `root.containsEventChannel`.
- Wire the fork in via `dependency_overrides`; add `cppOut`/`cppHeaderOut` to the
  existing `@ConfigurePigeon` block; commit `Messages.g.h`/`.cpp`.
- Skeleton package: `bluebird_windows` pubspec with `implements: bluebird`,
  `windows/CMakeLists.txt` (C++20, `windowsapp.lib`), plugin C-API entry point, and
  `BluebirdWindows extends BluebirdPlatform`.
- Endorse `windows: default_package: bluebird_windows` in `bluebird/pubspec.yaml`;
  `flutter create --platforms=windows .` in the example.
- Stand up the platform-thread dispatcher and `winrt::init_apartment` handling.
- Implement the three cheapest host calls — `isSupported`, `getAdapterName`,
  `getAdapterState` — plus `BmAdapterStateEvent` from `Radio.StateChanged`.
- CI: a `windows-latest` build job pinned to Flutter 3.47.0.

> **Gate** — toggling the Windows Bluetooth radio moves `Bluebird.adapterState` in
> the running example app.

### 2. Scanning — 4–6 days

- `BluetoothLEAdvertisementWatcher` in active mode; map `Stopped` with an error
  status to `BmScanFailedEvent`.
- Parse into `BmScanAdvertisement`: manufacturer data, service data (16/32/128-bit
  sections), service UUIDs, tx power, appearance, connectability from the
  advertisement type.
- Filter natively — the contract's six filter kinds don't map onto WinRT's single
  advertisement filter, so apply `withServices`, `withRemoteIds`, `withNames`,
  `withKeywords`, `withMsd` and `withServiceData` in our own code.
- Honour `continuousUpdates` and `continuousDivisor`; de-duplicate per address
  otherwise.
- Record address → `BluetoothAddressType` in the registry as advertisements arrive.

> **Gate** — the example's scan screen lists the ESP32 fixture with correct RSSI,
> name, manufacturer data and service UUIDs; service-UUID filtering returns only it.

### 3. Connection and discovery — 1–1.5 weeks

- Device registry holding `BluetoothLEDevice` + `GattSession` per address, with
  `MaintainConnection` as the connect verb and release as the disconnect verb.
- Map `ConnectionStatusChanged` to `BmConnectionStateEvent`, synthesising
  `connecting`/`disconnecting` around our own calls since WinRT reports only the
  two settled states.
- Decide and document the `connect()` timeout — WinRT will wait indefinitely for a
  device that never comes into range.
- Service discovery with `BluetoothCacheMode::Uncached`; populate
  `BmBluetoothService`, characteristics, descriptors and included services.
- Attribute identity: use WinRT's `AttributeHandle` as `BmAttributeId.instance`,
  which is what makes the fixture's duplicate-UUID characteristics addressable.
- `GattServicesChanged` → `BmServicesResetEvent`; `NameChanged` →
  `BmNameChangedEvent`.

> **Gate** — the e2e suite's connection and service-tree tests pass, including
> Service B's duplicate-UUID characteristics resolving as distinct instances.

### 4. GATT operations — 1–1.5 weeks

- Characteristic read; write with and without response; long write via
  `WriteValueWithResultAsync` and the reliable-write path.
- Descriptor read and write, including the 0x2901 user description the example
  reads for tile names.
- Notifications: `WriteClientCharacteristicConfigurationDescriptorAsync` for notify
  vs indicate, `ValueChanged` → `BmCharacteristicNotificationEvent`, and correct
  teardown on unsubscribe and on disconnect.
- MTU: report `GattSession.MaxPduSize` and push `MaxPduSizeChanged` as
  `BmMtuChangedEvent` — observation only, no request path.
- Map `GattCommunicationStatus` and protocol errors onto `BluebirdErrorCode`,
  including `attError` with the ATT code where WinRT surfaces it.

> **Gate** — the full e2e suite passes on `-d windows` except the tests for
> capabilities Windows lacks.

### 5. Bonding and enumeration — 4–6 days

- Pairing via `DeviceInformation.Pairing.Custom` with a `PairingRequested` handler,
  so the PIN argument to `createBond` means something; `UnpairAsync` for
  `removeBond`.
- Derive `BmBondStateEvent` from pairing progress and `DeviceInformation` updates.
- `getBondedDevices` and `getSystemDevices` via `DeviceInformation.FindAllAsync`
  with the BLE selectors, filtered by connection status and paired state
  respectively.
- `turnOn`/`turnOff` through `Radio.SetStateAsync`, gated on `RequestAccessAsync`.

> **Gate** — pairing the fixture from the example app shows a system prompt, reports
> `bonded`, and survives an app restart.

### 6. Core gating, docs, release — 3–5 days

- Rework the 11 `ensurePlatform` sites into capability checks the platform
  implementation declares, and update the tests that flip `System.current`.
- Document the unsupported surface in the `BluebirdWindows` class doc, the way
  `bluebird_web` already does.
- Add a Windows column to the six README capability matrices; update the platform
  badge and package description.
- Record the pigeon fork in `CLAUDE.md`: where it lives, how to re-apply it, and
  that `Messages.g.h`/`.cpp` are generated by it.
- Version lockstep, CHANGELOGs, `bluebird_windows` into publish.yml's ordered list,
  and the `bluebird` dependency bump.

> **Gate** — a clean checkout on a Windows machine runs the example and the e2e
> suite with no manual steps beyond `flutter pub get`.

## What Windows can and cannot do

Unsupported methods fall through to the platform interface's `UnimplementedError`.

| Contract | Status | WinRT route, or why not |
| :--- | :--- | :--- |
| `startScan` / `stopScan` | Supported | `BluetoothLEAdvertisementWatcher`, filtering done by us |
| `connect` / `disconnect` | Supported | `GattSession.MaintainConnection` + object lifetime |
| `discoverServices` | Supported | `GetGattServicesAsync(Uncached)` |
| read / write characteristic + descriptor | Supported | `GattCharacteristic`, `GattDescriptor` |
| `setNotifyValue` | Supported | CCCD write + `ValueChanged` |
| `createBond` / `removeBond` / `getBondState` | Supported | `DeviceInformationPairing`, custom ceremony for the PIN |
| `getSystemDevices` / `getBondedDevices` | Supported | `DeviceInformation.FindAllAsync` |
| `turnOn` / `turnOff` | **Verify** | `Radio.SetStateAsync`; consent behaviour for unpackaged Win32 apps needs confirming |
| `requestMtu` | Absent | `MaxPduSize` is observable only — the event works, the request doesn't |
| `readRssi` | Absent | RSSI arrives on advertisements, never for a live connection |
| `setPreferredPhy` / `getPhySupport` | Absent | no public LE PHY API |
| `requestConnectionPriority` | Absent | no connection-parameter API |
| `openL2capChannel` | Absent | no LE credit-based channels; `Rfcomm` is classic-only |
| `clearGattCache` | Absent | no equivalent; `Uncached` discovery is the nearest behaviour |

## Risks worth pricing in

**Address type is not in the address.** `FromBluetoothAddressAsync` needs a
public/random discriminator that the MAC string doesn't carry. A device restored
from disk and never scanned this session has no cached type. *Mitigation*: cache
from advertisements; fall back to `Unspecified` and treat a failed resolve as a
connect error rather than a hang.

**Threading is the usual killer.** Touching an `EventSink` or a pigeon reply off
the platform thread is a crash that surfaces as an unrelated engine assert, often
much later. *Mitigation*: build the dispatcher in phase 1, and let no BLE code hold
a raw sink pointer.

**No connect, therefore no connect failure.** With connection as a side effect of
object lifetime, a device out of range produces neither success nor error — just
silence, until it happens to come back. *Mitigation*: own the timeout in native
code and map expiry to `timeout`; document the difference from Android's GATT error
codes.

**Disconnect reasons are unavailable.** `BmConnectionStateEvent` carries an optional
reason code and string that WinRT simply does not provide. *Mitigation*: leave both
null; the fields are already nullable, so nothing in the core package changes.

**Pairing UX is not Android's.** Custom pairing hands us the ceremony, but the
accepted kinds vary by device, and a consent-only device ignores the PIN the API
takes. *Mitigation*: advertise `ProvidePin` and `ConfirmOnly`, and treat an
unsupported ceremony as `userRejected`.

**The fork must be re-appliable.** A patch nobody can reproduce becomes a blocker at
the next pigeon bump, when the person bumping it isn't the person who wrote it.
*Mitigation*: keep it as a git fork with one squashed commit per pigeon version, and
a `CLAUDE.md` note; upstream it once it has run in anger.

## Sizing

Measured against the existing implementations: 2,926 lines of Kotlin and 2,371 of
Swift, excluding generated code.

| Component | Est. lines | Notes |
| :--- | ---: | :--- |
| pigeon fork — C++ event channels | 200–300 | generator code, plus its golden tests |
| Generated `Messages.g.h` / `.cpp` | ~2,500 | machine-written, committed |
| Plugin scaffolding, dispatcher, registry | 400–600 | the part that must be right before anything else works |
| Scanning | 400–500 | parsing and our own filtering |
| Connection and GATT | 1,200–1,600 | the bulk |
| Bonding and enumeration | 300–400 | |
| Dart side of `bluebird_windows` | ~150 | mirrors `bluebird_android.dart` |
| Core capability rework + tests | 150–250 | touches the app-facing package |

Roughly **4–6 weeks** of focused work to a publishable 0.5.0, front-loaded with the
two phases that carry the unknowns. Dropping bonding to a follow-up saves about a
week and costs nothing structural.

## Verification

`flutter test integration_test/bluebird_e2e_test.dart -d windows` against the
ESP32-S3 fixture, throughout. CI can build the Windows target but cannot run that
suite — hosted runners have no Bluetooth radio, which is already true of every
other platform here.

## Background

Why the pigeon fork is necessary at all, with the evidence:

- pigeon's C++ generator supports HostApi, FlutterApi, `@async`, classes and enums,
  but has **zero** references to `EventChannel` or `ProxyApi` — as do the Java,
  Obj-C and GObject generators. Only Dart, Kotlin and Swift have them.
- `StructuredGenerator.writeEventChannelApi` (`lib/src/generator.dart:269`) is an
  empty virtual that those three override. The framework already routes event
  channel APIs to every generator; four of them no-op.
- `CppGeneratorAdapter.validate` calls `_errorOnEventChannelApi`,
  `_errorOnSealedClass` and `_errorOnInheritedClass`, so adding `cppOut` to the
  current `messages.dart` is a hard error, not a partial generation.
- The embedder side is complete: `StandardMethodCodec::GetInstance(const
  StandardCodecSerializer* serializer = nullptr)` and `EventChannel(messenger, name,
  const MethodCodec<T>* codec)` are exactly what Kotlin's one-line
  `StandardMethodCodec(PigeonCodec())` needs translating into.
- Upstream tracking: [flutter/flutter#161633](https://github.com/flutter/flutter/issues/161633)
  — open since 2025-01-15, P2, unassigned, no comments. The maintainers' stated
  direction is *fewer* generators
  ([#158287](https://github.com/flutter/flutter/issues/158287),
  [#158288](https://github.com/flutter/flutter/issues/158288)), not more feature
  backfill. This is prioritisation, not a technical wall.
