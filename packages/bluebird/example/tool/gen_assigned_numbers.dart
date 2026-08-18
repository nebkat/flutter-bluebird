// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Regenerates the Bluetooth SIG Assigned Numbers tables the example app uses
/// to put names next to the numbers it discovers.
///
///     dart run tool/gen_assigned_numbers.dart [--ref <branch-or-commit>]
///
/// The SIG publishes the registry as YAML in the `bluetooth-SIG/public`
/// repository; this downloads it (pinned to a single commit so a run is
/// reproducible), and writes `lib/utils/assigned_numbers/*.g.dart`, formatted
/// with the same `dart format` the CI check uses.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

const _repo = 'bluetooth-SIG/public';
const _apiBase = 'https://api.bitbucket.org/2.0/repositories/$_repo';
const _rawBase = 'https://bitbucket.org/$_repo/raw';

/// Where the generated files go, relative to the example package root.
const _outDir = 'lib/utils/assigned_numbers';

/// The 16-bit UUID registries, in the order [uuidRegistries] resolves them.
/// Each becomes one `const Map<int, String>` in `uuid_names.g.dart`.
const _uuidRegistries = <_Registry>[
  _Registry('uuids/service_uuids.yaml', 'serviceUuidNames', 'GATT service UUIDs (`0x18xx`).'),
  _Registry('uuids/characteristic_uuids.yaml', 'characteristicUuidNames', 'GATT characteristic UUIDs (`0x2Axx`).'),
  _Registry('uuids/descriptors.yaml', 'descriptorUuidNames', 'GATT descriptor UUIDs (`0x29xx`).'),
  _Registry('uuids/declarations.yaml', 'declarationUuidNames', 'GATT attribute declaration UUIDs (`0x28xx`).'),
  _Registry(
    'uuids/service_class.yaml',
    'serviceClassUuidNames',
    'Service class and profile identifiers (`0x1xxx`), used by classic Bluetooth service discovery.',
  ),
  _Registry(
    'uuids/member_uuids.yaml',
    'memberUuidNames',
    'Member UUIDs (`0xFCxx`–`0xFExx`) — allocated to a SIG member for their own\nuse, so the name is a company rather than a service.',
  ),
  _Registry(
    'uuids/sdo_uuids.yaml',
    'sdoUuidNames',
    'Standards Development Organization UUIDs (`0xFFxx`), allocated to another\nstandards body.',
  ),
];

class _Registry {
  const _Registry(this.path, this.variable, this.doc);

  /// Path under `assigned_numbers/` in the SIG repository.
  final String path;

  /// Name of the generated Dart map.
  final String variable;

  /// Doc comment body for the generated map.
  final String doc;
}

Future<void> main(List<String> args) async {
  var ref = 'main';
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--ref' && i + 1 < args.length) {
      ref = args[++i];
    } else if (arg.startsWith('--ref=')) {
      ref = arg.substring('--ref='.length);
    } else {
      stderr.writeln('usage: dart run tool/gen_assigned_numbers.dart [--ref <branch-or-commit>]');
      exit(64);
    }
  }

  final client = HttpClient();
  try {
    final commit = await _resolveCommit(client, ref);
    stdout.writeln('bluetooth-SIG/public @ ${commit.hash} (${commit.date})');

    final source = _Source(client, commit);
    final written = <String>[
      await _writeUuidNames(source),
      await _writeCompanyIdentifiers(source),
      await _writeAppearanceValues(source),
    ];

    await _format(written);
    for (final path in written) {
      stdout.writeln('wrote $path');
    }
  } finally {
    client.close();
  }
}

/// Resolves a branch name or short sha to the exact commit to download from, so
/// every file in one run comes from the same snapshot of the registry.
Future<_Commit> _resolveCommit(HttpClient client, String ref) async {
  final json = await _get(client, Uri.parse('$_apiBase/commits/$ref?pagelen=1'));
  final values = (jsonDecode(json) as Map<String, dynamic>)['values'] as List<dynamic>;
  if (values.isEmpty) throw StateError('no commit found for ref "$ref"');
  final commit = values.first as Map<String, dynamic>;
  return _Commit(commit['hash'] as String, (commit['date'] as String).split('T').first);
}

class _Commit {
  const _Commit(this.hash, this.date);

  final String hash;
  final String date;
}

/// Downloads (and caches) the registry YAML from one commit.
class _Source {
  _Source(this._client, this.commit);

  final HttpClient _client;
  final _Commit commit;

  Future<YamlMap> yaml(String path) async {
    final uri = Uri.parse('$_rawBase/${commit.hash}/assigned_numbers/$path');
    final document = loadYaml(await _get(_client, uri), sourceUrl: uri);
    if (document is! YamlMap) throw StateError('$path: expected a YAML mapping at the top level');
    return document;
  }

  /// The `- uuid:`/`- value:` + `name:` entries of a registry file, keyed by
  /// number. The SIG lists some files newest-first; sorting keeps the generated
  /// map (and its diffs) stable and readable.
  Future<Map<int, String>> entries(String path, {required String key, required String numberKey}) async {
    final document = await yaml(path);
    final list = document[key];
    if (list is! YamlList) throw StateError('$path: expected a list under "$key"');
    final result = <int, String>{};
    for (final entry in list) {
      if (entry is! YamlMap) throw StateError('$path: expected mappings under "$key"');
      final number = _number(entry[numberKey], path);
      final name = _clean(entry['name'] as String);
      if (result.containsKey(number)) {
        throw StateError('$path: duplicate entry for ${_hex(number)}');
      }
      result[number] = name;
    }
    return _sorted(result);
  }
}

Future<String> _writeUuidNames(_Source source) async {
  final registries = <_Registry, Map<int, String>>{};
  for (final registry in _uuidRegistries) {
    registries[registry] = await source.entries(registry.path, key: 'uuids', numberKey: 'uuid');
  }

  // A single number must name one thing for the flat, registry-by-registry
  // lookup in assigned_numbers.dart to be unambiguous. The SIG allocates each
  // registry its own range, so this only fires if that ever stops being true.
  final seen = <int, String>{};
  for (final entry in registries.entries) {
    for (final number in entry.value.keys) {
      final other = seen[number];
      if (other != null) {
        throw StateError('${_hex(number)} is in both $other and ${entry.key.path}');
      }
      seen[number] = entry.key.path;
    }
  }

  final buffer = StringBuffer()
    ..write(
      _header(
        source,
        'Bluetooth SIG 16-bit UUID registries: the assigned number → name tables\n'
        '// behind `Uuid.assignedName` in `../assigned_numbers.dart`.',
        _uuidRegistries.map((registry) => registry.path),
      ),
    );
  for (final entry in registries.entries) {
    buffer
      ..writeln()
      ..writeln('/// ${entry.key.doc.replaceAll('\n', '\n/// ')}')
      ..writeln('const Map<int, String> ${entry.key.variable} = {');
    _writeEntries(buffer, entry.value);
    buffer.writeln('};');
  }
  return _write('uuid_names.g.dart', buffer.toString());
}

Future<String> _writeCompanyIdentifiers(_Source source) async {
  const path = 'company_identifiers/company_identifiers.yaml';
  final companies = await source.entries(path, key: 'company_identifiers', numberKey: 'value');

  final buffer = StringBuffer()
    ..write(
      _header(
        source,
        'Bluetooth SIG company identifiers: the 16-bit ids that key the\n'
        '// manufacturer-specific data of an advertisement.',
        const [path],
      ),
    )
    ..writeln()
    ..writeln('/// Maps a 16-bit Bluetooth SIG company identifier to its assigned name.')
    ..writeln('const Map<int, String> companyIdentifiers = {');
  _writeEntries(buffer, companies);
  buffer.writeln('};');
  return _write('company_identifiers.g.dart', buffer.toString());
}

Future<String> _writeAppearanceValues(_Source source) async {
  const path = 'core/appearance_values.yaml';
  final document = await source.yaml(path);
  final categories = document['appearance_values'];
  if (categories is! YamlList) throw StateError('appearance_values.yaml: expected a list');

  // The GAP appearance is a 16-bit value: the top 10 bits are the category and
  // the low 6 bits the subcategory. Flattening both into one table lets a
  // lookup fall back from the exact value to the bare category.
  final values = <int, String>{};
  for (final category in categories) {
    if (category is! YamlMap) throw StateError('appearance_values.yaml: expected mappings');
    final number = _number(category['category'], 'appearance_values.yaml');
    final name = _clean(category['name'] as String);
    values[number << 6] = name;
    final subcategories = category['subcategory'];
    if (subcategories == null) continue;
    if (subcategories is! YamlList) throw StateError('appearance_values.yaml: expected a subcategory list');
    for (final subcategory in subcategories) {
      final value = _number((subcategory as YamlMap)['value'], 'appearance_values.yaml');
      values[number << 6 | value] = '$name: ${_clean(subcategory['name'] as String)}';
    }
  }

  final buffer = StringBuffer()
    ..write(
      _header(
        source,
        'Bluetooth SIG GAP appearance values, category and subcategory flattened\n'
        '// into the 16-bit value that appears in an advertisement.',
        const [path],
      ),
    )
    ..writeln()
    ..writeln('/// Maps a 16-bit GAP appearance value to its human-readable name.')
    ..writeln('/// The low 6 bits are the subcategory; masking them off gives the category.')
    ..writeln('const Map<int, String> appearanceValues = {');
  _writeEntries(buffer, _sorted(values));
  buffer.writeln('};');
  return _write('appearance_values.g.dart', buffer.toString());
}

String _header(_Source source, String description, Iterable<String> paths) =>
    '// GENERATED FILE — do not edit by hand.\n'
    '// Regenerate with: dart run tool/gen_assigned_numbers.dart\n'
    '//\n'
    '// $description\n'
    '//\n'
    '// Source: https://bitbucket.org/$_repo (${source.commit.hash}, ${source.commit.date})\n'
    '//         assigned_numbers/${paths.join('\n//         assigned_numbers/')}\n';

void _writeEntries(StringBuffer buffer, Map<int, String> entries) {
  for (final entry in entries.entries) {
    buffer.writeln('  ${_hex(entry.key)}: ${_dartString(entry.value)},');
  }
}

Map<int, String> _sorted(Map<int, String> entries) =>
    Map.fromEntries(entries.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));

/// Accepts the `0x1800` form the SIG uses (parsed as an int by YAML 1.2) as well
/// as a quoted string, in case a file ever spells one out.
int _number(Object? value, String path) => switch (value) {
  int() => value,
  String() => int.tryParse(value.replaceFirst('0x', ''), radix: 16) ?? (throw StateError('$path: bad number $value')),
  _ => throw StateError('$path: missing or unparseable number ($value)'),
};

String _hex(int value) => '0x${value.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// Normalizes a name for display: the SIG data has occasional LaTeX escapes and
/// stray whitespace from the tooling that produces it.
String _clean(String name) {
  final subscripts = '₀₁₂₃₄₅₆₇₈₉';
  return name
      .replaceAllMapped(RegExp(r'\\textsubscript\{(\d)\}'), (m) => subscripts[int.parse(m[1]!)])
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _dartString(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');
  return "'$escaped'";
}

Future<String> _get(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw HttpException('GET $uri failed: ${response.statusCode} ${response.reasonPhrase}', uri: uri);
  }
  return response.transform(utf8.decoder).join();
}

Future<String> _write(String name, String contents) async {
  final file = File('$_outDir/$name');
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
  return file.path;
}

/// Formats the generated files with the Dart running this script, so they pass
/// the repo's `dart format` check without a follow-up commit.
Future<void> _format(List<String> paths) async {
  final result = await Process.run(Platform.resolvedExecutable, ['format', ...paths]);
  if (result.exitCode != 0) {
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    throw StateError('dart format failed (${result.exitCode})');
  }
}
