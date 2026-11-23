// fushi 包的构建钩子（`flutter run` / `build` / `test` 都会先跑它）。
//
// 只做一件事：把 Flutter GPU 的着色器包编出来。shaderbundle 是引擎自带 impellerc 的产物，和引擎
// 版本绑在一起，所以不入库、每次构建现编（输入没变时 hooks runner 按依赖哈希直接跳过）。产物落在
// build/shaderbundles/diorama.shaderbundle，pubspec 的 flutter.assets 登记同一路径；
// 运行时由 lib/src/media/music/lyrics/visualizer/modes/diorama/diorama_gpu.dart 加载。
import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'shaders/diorama.shaderbundle.json',
    );
  });
}
