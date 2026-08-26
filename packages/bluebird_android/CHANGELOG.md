## Unreleased

- Implemented `getPermission`, distinguishing never-asked from refused by whether the OS still offers a rationale, falling back to whether this process has already asked. Implemented `getLocationEnabled` against `LocationManager.isLocationEnabled` (API 28+) and `Settings.Secure.LOCATION_MODE` below it; always true from API 31, where `neverForLocation` retires the requirement.

## 0.4.3

- Stopped applying the Kotlin Gradle Plugin. Under AGP 9+ (or `android.builtInKotlin=true`) the Android Gradle Plugin compiles Kotlin itself, and below that Flutter's Gradle plugin applies `kotlin-android` to plugin modules that don't declare it — so nothing is lost, and apps no longer list `bluebird_android` under "uses the following plugins that apply Kotlin Gradle Plugin (KGP)", which future Flutter versions will make a build failure. Applying it conditionally was not enough: Flutter detects the declaration by scanning `build.gradle` with a regex, not by inspecting Gradle state.

## 0.4.1

- Fixed manufacturer specific data parsing when an advertisement carries more than one Manufacturer Specific Data (AD type `0xFF`) structure. Each structure is now attributed to its own company id; previously every structure was concatenated into one blob keyed by the first company id, so a later structure's company id leaked into the earlier structure's payload (e.g. a device advertising `0x0000` then `0x08FA` surfaced as `{ 0x0000: [.. FA 08 ..] }` instead of two separate entries). Multiple structures sharing a company id are still concatenated.

## 0.4.0

- Added L2CAP connection-oriented channel support (`BluetoothDevice.createL2capChannel`, Android 10 / API 29+).

## 0.3.0

- Regenerated for the `BluetoothConnectionState` `connecting` / `disconnecting` additions. Native behaviour is unchanged — Android still reports only connected / disconnected.

## 0.2.0

- Platform method-channel tracing now goes to `BluebirdPlatform.logger` (at `Level.FINEST`); `setLogLevel` no longer takes a `color` argument.
- Surface a peer's ATT Error Response as `attError` (with the raw ATT code), distinct from local GATT stack/link failures (`androidError`).

## 0.1.0

- Initial release.
