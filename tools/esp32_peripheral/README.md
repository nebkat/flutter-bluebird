# Bluebird BLE Peripheral Test Fixture (ESP32-S3)

An ESP-IDF (v6.0.2) + NimBLE firmware that turns an ESP32-S3 into a BLE
peripheral exercising every feature of the **bluebird** Flutter BLE library.
Based on the upstream `examples/bluetooth/nimble/bleprph` example.

## Build & flash

```sh
# One-time toolchain setup (if not already installed):
#   git clone --depth 1 --branch v6.0.2 https://github.com/espressif/esp-idf \
#       ~/esp/esp-idf-v6.0.2 --recursive
#   ~/esp/esp-idf-v6.0.2/install.sh esp32s3

. ~/esp/esp-idf-v6.0.2/export.sh
cd tools/esp32_peripheral
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash monitor   # port: ls /dev/cu.usb*
```

All GAP/GATT activity is logged verbosely to the serial monitor.

## Advertising (scan-filter tests)

Advertises as a connectable, general-discoverable legacy advertiser.
Payload is split across ADV (26 bytes) and scan response (12 bytes):

| Packet   | AD field                  | Value                                | bluebird API tested |
|----------|---------------------------|--------------------------------------|---------------------|
| ADV      | Flags                     | LE General Discoverable, BR/EDR unsupported | — |
| ADV      | Complete local name       | `Bluebird-Test`                      | `withNames` / `withKeywords` scan filters, `advName` |
| ADV      | Manufacturer data         | company ID `0x02E5`, payload `de ad be ef` | `withMsd` filter, `msd` in scan results |
| SCAN RSP | Complete 16-bit UUID list | `0x181A`                             | `withServices` filter, `serviceUuids` in scan results |
| SCAN RSP | Service data (16-bit)     | UUID `0x181A`, data `11 22 33 44`    | `withServiceData` filter, `serviceData` in scan results |

Advertising resumes automatically on disconnect.

## GATT database

UUID scheme: `B1EBxxxx-CAFE-4E5D-A2B1-1BD5EE12B1EB` (the `xxxx` short code
below). Preferred ATT MTU is **517** (`ble_att_set_preferred_mtu`), so
`requestMtu`/`mtu` can be tested up to the spec maximum.

### Service A — `B1EBA000-CAFE-4E5D-A2B1-1BD5EE12B1EB` (primary)

| Short code | Attribute | Properties | Behaviour | bluebird API tested |
|------------|-----------|------------|-----------|---------------------|
| `A001` | Characteristic | READ | Static value `"bluebird"` | `readValue` (plain read) |
| — 0x2901 | Descriptor (User Description) | READ | `"Bluebird static read characteristic"` | `BluetoothDescriptor.read` |
| — `A0FF` | Descriptor (custom 128-bit) | READ, WRITE | 16-byte read/write buffer | `BluetoothDescriptor.read` / `.write` |
| `A002` | Characteristic | READ, WRITE, WRITE_NO_RSP | Stores what is written (256-byte buffer); read it back to verify | `write` (with response), `write(withoutResponse: true)`, read-back verification |
| `A003` | Characteristic | NOTIFY | Incrementing `uint32` counter (LE) every **1 s** while subscribed | `setNotifyValue(true)`, CCCD handling, `onCharacteristicReceived` / `lastValueStream` |
| `A004` | Characteristic | INDICATE | Counter every **2 s** while subscribed | Indications + CCCD indicate bit |
| `A005` | Characteristic | NOTIFY, INDICATE | Counter every 1 s; uses notifications if the notify bit is set, indications if only the indicate bit is set | notify preferred when a characteristic supports both notify + indicate |
| `A006` | Characteristic | READ, WRITE | 512-byte value buffer (initialised with `00..ff` pattern) | Long reads (blob), `allowLongWrite` MTU-spanning writes, `maxAttrLen` |
| `A007` | Characteristic | READ (encrypted) | Static value `"top-secret"`; read triggers Just Works pairing (NO_INPUT_NO_OUTPUT, bonding=1, SC=1) | `createBond` / implicit pairing, `bondState`, encrypted read errors |
| `A008` | Characteristic | WRITE | Control: write `0x01` → sends Service Changed (`ble_svc_gatt_changed(0x0001, 0xffff)`); write `0x02` → peripheral terminates the connection | `onServicesReset` (0x2A05 handling); disconnect events + `disconnectReason` |

### Service B — `B1EBB000-CAFE-4E5D-A2B1-1BD5EE12B1EB` (primary)

| Short code | Attribute | Properties | Behaviour | bluebird API tested |
|------------|-----------|------------|-----------|---------------------|
| `B001` (instance 1) | Characteristic | READ | Static value `"instance-one"` | Instance-ID disambiguation of duplicate characteristic UUIDs |
| `B001` (instance 2) | Characteristic | READ | Static value `"instance-two"` | Same — the two reads must return different values |

## Other behaviour

- **MTU**: preferred MTU 517 (`CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=517`).
- **Bonding**: bonds/CCCDs persisted to NVS (`CONFIG_BT_NIMBLE_NVS_PERSIST=y`).
  A repeat-pairing attempt deletes the stale bond and retries automatically.
- **Disconnect**: advertising restarts immediately; all subscription timers stop.
- **Stack**: NimBLE only, Bluedroid disabled (`sdkconfig.defaults`).
