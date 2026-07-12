# bluebird end-to-end integration tests

UI-less integration tests that exercise the bluebird API against real
hardware: the ESP32-S3 test fixture in `tools/esp32_peripheral` (repo root).

## Prerequisites

1. Flash the fixture firmware onto an ESP32-S3 and power it (see
   `tools/esp32_peripheral/README.md` for build/flash instructions).
   It must be advertising as **`Bluebird-Test`**.
2. Bluetooth enabled on the host machine.

## Run

```sh
cd packages/bluebird/example
flutter test integration_test/bluebird_e2e_test.dart -d macos
```

(Substitute `-d <device-id>` for an Android device; `flutter devices` lists ids.)

## Notes

- If the fixture is not advertising, the suite fails fast in `setUpAll` with:
  `ESP32 fixture 'Bluebird-Test' not advertising — flash tools/esp32_peripheral and power it`.
- Tests are ordered and share one connection (established in `setUpAll`);
  they cover scanning/advertisement contents, service discovery (including
  duplicate-UUID characteristic instances), reads, writes (with/without
  response, 512-byte long writes), descriptors, notifications, indications,
  services-changed handling, and peripheral-initiated disconnects.
- The encrypted-read/bonding test is skipped by default because Just-Works
  pairing requires an interactive dialog on macOS. Remove the `skip:` on the
  `bonding` group to run it manually.
- Total runtime with the fixture present is under two minutes.

## Troubleshooting: stale GATT cache on macOS

macOS caches a peripheral's GATT database by device identity. If the fixture
board previously ran different firmware, discovery returns the *old* services
(the advertisement will look correct — the cache only affects GATT). Fix:

    blueutil -p 0 && sleep 2 && blueutil -p 1    # brew install blueutil
