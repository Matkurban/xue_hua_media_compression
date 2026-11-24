// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as path;

const String _pluginName = 'xue_hua_media_compression';
const String _assetId = 'package:$_pluginName/${_pluginName}_objc_gen.dylib';

const String _ffigenConfigPath = 'tool/pigeon/messages_ffigen_config.dart';
const String _ffiBindingsPath = 'lib/src/messages.g.ffi.dart';
const String _iosObjcGenDir =
    'ios/$_pluginName/Sources/${_pluginName}_objc_gen';
const String _macosObjcGenDir =
    'macos/$_pluginName/Sources/${_pluginName}_objc_gen';

Future<void> main(List<String> args) async {
  final bool ffigenOnly = args.contains('--ffigen-only');
  final String repoRoot = Platform.script.resolve('..').toFilePath();
  Directory.current = repoRoot;

  if (!ffigenOnly) {
    await _run('dart', <String>[
      'run',
      'pigeon',
      '--input',
      'pigeons/messages.dart',
    ]);
  }

  _injectAssetId(_ffigenConfigPath);

  if (Platform.isMacOS) {
    await _run('dart', <String>['run', _ffigenConfigPath]);
    _syncMacosObjcGen();
  } else {
    print(
      'Skipping Darwin FFI regeneration on non-macOS host; '
      'updated $_ffigenConfigPath with assetId.',
    );
  }

  _deleteObjectFiles(_iosObjcGenDir);
  _deleteObjectFiles(_macosObjcGenDir);
  _verifyDefaultAsset(_ffiBindingsPath);
  print('Pigeon FFI bindings verified with @ffi.DefaultAsset($_assetId).');
}

void _injectAssetId(String configPath) {
  final File file = File(configPath);
  if (!file.existsSync()) {
    throw StateError('Missing generated ffigen config: $configPath');
  }
  final String original = file.readAsStringSync();
  final String assetLine = "      assetId: '$_assetId',";
  if (original.contains("assetId: '$_assetId'")) {
    return;
  }

  final RegExp modulePattern = RegExp(
    r"(output:\s*Output\(\s*\r?\n\s*module:\s*'xue_hua_media_compression',)",
  );
  if (!modulePattern.hasMatch(original)) {
    throw StateError(
      'Could not find Output(module: ...) in $configPath to inject assetId.',
    );
  }
  final String updated = original.replaceFirstMapped(
    modulePattern,
    (Match match) => '${match.group(1)}\n$assetLine',
  );
  file.writeAsStringSync(updated);
}

void _syncMacosObjcGen() {
  final Directory iosDir = Directory(_iosObjcGenDir);
  final Directory macosDir = Directory(_macosObjcGenDir)
    ..createSync(recursive: true);

  for (final FileSystemEntity entity in iosDir.listSync()) {
    if (entity is! File) {
      continue;
    }
    final String name = path.basename(entity.path);
    if (name.endsWith('.m') || name.endsWith('.h')) {
      entity.copySync(path.join(macosDir.path, name));
    }
  }
}

void _deleteObjectFiles(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return;
  }
  for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.o')) {
      entity.deleteSync();
    }
  }
}

void _verifyDefaultAsset(String bindingsPath) {
  final File file = File(bindingsPath);
  if (!file.existsSync()) {
    throw StateError('Missing generated FFI bindings: $bindingsPath');
  }
  final String content = file.readAsStringSync();
  final RegExp expected = RegExp(
    "@ffi\\.DefaultAsset\\(\\s*'${RegExp.escape(_assetId)}',?\\s*\\)\\r?\\nlibrary;",
  );
  if (!expected.hasMatch(content)) {
    throw StateError(
      'Expected @ffi.DefaultAsset(\'$_assetId\') library; in $bindingsPath',
    );
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  print('> $executable ${arguments.join(' ')}');
  final Process process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  final int code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(
      executable,
      arguments,
      'Exited with code $code',
      code,
    );
  }
}
