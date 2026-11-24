import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const String _assetName = 'xue_hua_media_compression_objc_gen.dylib';

final Map<Architecture, String> _macOSTargetTriples = <Architecture, String>{
  Architecture.arm64: 'arm64-apple-darwin',
  Architecture.arm64e: 'arm64e-apple-darwin',
  Architecture.x64: 'x86_64-apple-darwin',
};

final Map<Architecture, Map<IOSSdk, String>> _iOSTargetTriples =
    <Architecture, Map<IOSSdk, String>>{
      Architecture.arm64: <IOSSdk, String>{
        IOSSdk.iPhoneOS: 'arm64-apple-ios',
        IOSSdk.iPhoneSimulator: 'arm64-apple-ios-simulator',
      },
      Architecture.arm64e: <IOSSdk, String>{
        IOSSdk.iPhoneOS: 'arm64e-apple-ios',
        IOSSdk.iPhoneSimulator: 'arm64e-apple-ios-simulator',
      },
      Architecture.x64: <IOSSdk, String>{
        IOSSdk.iPhoneSimulator: 'x86_64-apple-ios-simulator',
      },
    };

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final CodeConfig codeConfig = input.config.code;
    final OS targetOS = codeConfig.targetOS;
    if (targetOS != OS.iOS && targetOS != OS.macOS) {
      return;
    }

    if (codeConfig.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('LinkModePreference.static is not supported.');
    }

    final String platformDir = targetOS == OS.iOS ? 'ios' : 'macos';
    final Directory objcGenDir = Directory.fromUri(
      input.packageRoot.resolve(
        '$platformDir/xue_hua_media_compression/Sources/'
        'xue_hua_media_compression_objc_gen/',
      ),
    );
    if (!objcGenDir.existsSync()) {
      throw StateError(
        'Missing Objective-C generated directory: ${objcGenDir.path}',
      );
    }

    final List<String> mFiles = <String>[];
    final List<String> hFiles = <String>[];
    for (final FileSystemEntity entity in objcGenDir.listSync(
      recursive: true,
    )) {
      if (entity is! File) {
        continue;
      }
      if (entity.path.endsWith('.m')) {
        mFiles.add(entity.path);
      } else if (entity.path.endsWith('.h')) {
        hFiles.add(entity.path);
      }
    }
    mFiles.sort();
    hFiles.sort();

    if (mFiles.isEmpty) {
      throw StateError(
        'No Objective-C (.m) sources found in ${objcGenDir.path}',
      );
    }

    final String compiler = _findCompiler(codeConfig);
    final String sysroot = _sdkPath(codeConfig);
    final String targetTriple = _targetTriple(codeConfig);
    final String minOSFlag = _minOSVersionFlag(codeConfig);

    final Directory objDir = Directory.fromUri(
      input.outputDirectory.resolve('obj/'),
    )..createSync(recursive: true);

    final List<String> objectFiles = <String>[];
    for (int i = 0; i < mFiles.length; i++) {
      final String src = mFiles[i];
      final String objPath = objDir.uri.resolve('objc_gen_$i.o').toFilePath();
      await _runTool(compiler, <String>[
        '-isysroot',
        sysroot,
        '-target',
        targetTriple,
        minOSFlag,
        '-x',
        'objective-c',
        '-fobjc-arc',
        '-fpic',
        '-gline-tables-only',
        '-I',
        objcGenDir.path,
        '-c',
        src,
        '-o',
        objPath,
      ]);
      objectFiles.add(objPath);
    }

    final Uri assetPath = input.outputDirectory.resolve(_assetName);
    await _runTool(compiler, <String>[
      '-shared',
      if (targetOS == OS.iOS) '-Wl,-encryptable',
      '-isysroot',
      sysroot,
      '-target',
      targetTriple,
      minOSFlag,
      '-framework',
      'Foundation',
      '-lobjc',
      ...objectFiles,
      '-o',
      assetPath.toFilePath(),
    ]);

    output.dependencies.addAll(mFiles.map(Uri.file));
    output.dependencies.addAll(hFiles.map(Uri.file));

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        file: assetPath,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}

String _findCompiler(CodeConfig codeConfig) {
  final String? compiler = codeConfig.cCompiler?.compiler.toFilePath();
  if (compiler != null && File(compiler).existsSync()) {
    return compiler;
  }
  return 'clang';
}

String _sdkPath(CodeConfig codeConfig) {
  final String sdkName;
  if (codeConfig.targetOS == OS.iOS) {
    sdkName = codeConfig.iOS.targetSdk == IOSSdk.iPhoneOS
        ? 'iphoneos'
        : 'iphonesimulator';
  } else {
    sdkName = 'macosx';
  }
  final ProcessResult result = Process.runSync('xcrun', <String>[
    '--show-sdk-path',
    '--sdk',
    sdkName,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'xcrun --show-sdk-path --sdk $sdkName failed '
      '(exit ${result.exitCode}): ${result.stderr}',
    );
  }
  return (result.stdout as String)
      .split('\n')
      .map((String line) => line.trim())
      .firstWhere((String line) => line.isNotEmpty);
}

String _targetTriple(CodeConfig codeConfig) {
  final Architecture arch = codeConfig.targetArchitecture;
  if (codeConfig.targetOS == OS.iOS) {
    final IOSSdk sdk = codeConfig.iOS.targetSdk;
    final String? triple = _iOSTargetTriples[arch]?[sdk];
    if (triple == null) {
      throw UnsupportedError('Unsupported iOS target: $arch ($sdk).');
    }
    return triple;
  }
  final String? triple = _macOSTargetTriples[arch];
  if (triple == null) {
    throw UnsupportedError('Unsupported macOS target: $arch.');
  }
  return triple;
}

String _minOSVersionFlag(CodeConfig codeConfig) {
  if (codeConfig.targetOS == OS.iOS) {
    final String version = _formatAppleVersion(
      codeConfig.iOS.deploymentVersion,
    );
    if (codeConfig.iOS.targetSdk == IOSSdk.iPhoneSimulator) {
      return '-mios-simulator-version-min=$version';
    }
    return '-mios-version-min=$version';
  }
  final String version = _formatAppleVersion(
    codeConfig.macOS.deploymentVersion,
  );
  return '-mmacosx-version-min=$version';
}

String _formatAppleVersion(AppleVersion version) {
  if (version.patch != 0) {
    return '${version.major}.${version.minor}.${version.patch}';
  }
  return '${version.major}.${version.minor}';
}

Future<void> _runTool(String executable, List<String> arguments) async {
  final ProcessResult result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}'.trim(),
      result.exitCode,
    );
  }
}
