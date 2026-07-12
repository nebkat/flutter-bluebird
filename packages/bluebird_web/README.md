# bluebird_web

The Web implementation of [`bluebird`][1].

## Usage

This package is [endorsed][2], which means you can simply use `bluebird`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

## Web Bluetooth limitations

This implementation is backed by the browser's
[Web Bluetooth API][3], which is deliberately restricted for security and
privacy reasons. Several capabilities available on native platforms are simply
not exposed by the browser and therefore throw `UnimplementedError` here: read
RSSI, request/observe MTU, bonding (create/remove/query bond), PHY
(get/set/support), clear GATT cache, enumerate system or bonded devices, get the
adapter name, and turn the adapter on/off.

### Scanning is a device chooser, not a passive scan

Web Bluetooth has **no passive scan**. There is no way to observe advertisements
from arbitrary nearby devices. The only entry point,
`navigator.bluetooth.requestDevice(...)`, opens a browser-controlled chooser and
returns **exactly one** device that the user picks.

As a consequence:

- `startScan` opens the chooser (using the scan filters — services and names —
  and `webOptionalServices`) and, once the user picks a device, emits a **single**
  scan advertisement for that one device.
- The advertisement is minimal: the browser exposes almost no advertising data,
  so `rssi` is reported as `0` and the service/manufacturer-data maps are empty.
- If the user dismisses the chooser, a scan-failed event is emitted instead.
- `stopScan` is a no-op — the chooser is modal and there is no ongoing scan.

### Adapter state

`isSupported` uses `navigator.bluetooth.getAvailability()`. `getAdapterState`
reports `on` when Bluetooth is available and `unavailable` otherwise; finer
states (off/turning-on/etc.) are not observable from the web.

[1]: https://pub.dev/packages/bluebird
[2]: https://flutter.dev/to/endorsed-federated-plugin
[3]: https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API
