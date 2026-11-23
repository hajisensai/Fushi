// Builds the Flutter GPU shader bundles (build/shaderbundles/*.shaderbundle)
// outside a Flutter build, by running the package's own hook/build.dart.
//
// The bundles are impellerc output tied to the engine build, so they are not
// tracked; `flutter run|build|test` produce them through the build hook. But
// pubspec.yaml lists build/shaderbundles/diorama.shaderbundle under
// flutter.assets, and `flutter analyze` runs no hooks: on a checkout that
// has not built or tested yet, the analyzer reports asset_does_not_exist.
// Every analyze of the app therefore runs this first (CI:
// .github/actions/gen-shader-bundles; locally tool/heavy.dart; dist workers
// fushi/tool/dist_test/worker_prepare.sh). It runs the very same hook main
// the Flutter tool runs, so the output path and the impellerc arguments have
// one source (hook/build.dart).
//
// Run with the Flutter SDK's dart (flutter_gpu_shaders finds impellerc next
// to it in bin/cache/artifacts/engine/<host>/), from anywhere:
//   "$(dirname "$(command -v flutter)")/dart" fushi/tool/gen_shader_bundles.dart
import 'dart:io';

import 'package:hooks/hooks.dart';

import '../hook/build.dart' as hook;

Future<void> main(List<String> args) async {
  // testBuildHook takes the package root from the current directory.
  Directory.current = Directory.fromUri(Platform.script.resolve('../'));
  await testBuildHook(
    mainMethod: hook.main,
    check: (BuildInput input, BuildOutput output) {},
    extensions: const <ProtocolExtension>[],
  );
  stdout.writeln(
    'gen_shader_bundles: built build/shaderbundles/ from hook/build.dart',
  );
}
