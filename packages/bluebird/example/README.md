# bluebird_example

Demonstrates how to use the `bluebird` plugin.

## Assigned numbers

The app puts a name next to almost every number a scan turns up — company
identifiers in manufacturer data, GAP appearance values, and service,
characteristic, descriptor and member UUIDs — from the Bluetooth SIG's
[Assigned Numbers](https://bitbucket.org/bluetooth-SIG/public) registry.

The tables in `lib/utils/assigned_numbers/` are generated; the lookups on top of
them live in `lib/utils/assigned_numbers.dart`. To refresh them from the SIG's
published YAML:

```sh
dart run tool/gen_assigned_numbers.dart
```

The plugin itself keeps only a handful of well-known names (`Uuid.name`) so it
stays small — the full registry is a demo-app concern.
