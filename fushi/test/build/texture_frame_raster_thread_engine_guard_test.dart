import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Windows 引擎补丁 `engine-texture-frame-raster-thread.patch` 的源码守卫（BUG-5200）。
///
/// 原版 `FlutterWindowsTextureRegistrar::MarkTextureFrameAvailable` 把每个外部纹理新帧先
/// post 到平台线程（Windows 默认与 Dart UI 线程合并），再由 `Animator` 等 vsync 调一帧；主线程
/// 忙过一个视频帧间隔，这帧就被 media_kit 画进同一块共享纹理的下一帧覆盖、永远不上屏（应用内
/// 反馈 q5f7uiRd__：平移镜头「一卡一卡」）。补丁让生产方线程直接把 mark + 重画交给 raster
/// 线程。这条链路退回原样不会编译失败，只会静默回到「主线程一忙视频就丢帧」；改坏合并逻辑则
/// 会丢掉晚到的 mark（同样是丢帧）。下面把这些点咬住。
void main() {
  final String fushi = _fushiDir();
  final String repo = Directory(fushi).parent.path;
  final String flutterVersion = _fvmFlutterVersion(fushi);
  final String patchDir = '$repo/ci/patches/flutter-engine/$flutterVersion';
  final String patchPath = '$patchDir/engine-texture-frame-raster-thread.patch';

  test('补丁存在、是 LF，且构建脚本在 resize 补丁之后打它', () {
    expect(File(patchPath).existsSync(), isTrue);
    expect(File(patchPath).readAsBytesSync().contains(13), isFalse);
    final String script = _read(
      '$repo/tool/flutter_engine/build_patched_engine.ps1',
    );
    final int resize = script.indexOf(
      "'engine-resize-before-first-frame.patch'",
    );
    final int raster = script.indexOf(
      "'engine-texture-frame-raster-thread.patch'",
    );
    expect(resize, greaterThan(0));
    expect(raster, greaterThan(resize));
  });

  test('只改 embedder 的 mark 入口与 Windows 纹理注册器（含单测）', () {
    final List<String> files = RegExp(
      r'^\+\+\+ b/(.+)$',
      multiLine: true,
    ).allMatches(_read(patchPath)).map((RegExpMatch m) => m.group(1)!).toList();
    expect(files, <String>[
      'engine/src/flutter/shell/platform/embedder/embedder.cc',
      'engine/src/flutter/shell/platform/embedder/embedder.h',
      'engine/src/flutter/shell/platform/embedder/embedder_engine.cc',
      'engine/src/flutter/shell/platform/embedder/embedder_engine.h',
      'engine/src/flutter/shell/platform/windows/flutter_windows_engine.cc',
      'engine/src/flutter/shell/platform/windows/flutter_windows_engine.h',
      'engine/src/flutter/shell/platform/windows/flutter_windows_texture_registrar.cc',
      'engine/src/flutter/shell/platform/windows/flutter_windows_texture_registrar_unittests.cc',
    ]);
  });

  test('Windows 注册器的 mark 不再 post 到平台线程', () {
    final String patch = _read(patchPath);
    final String mark = _between(
      patch,
      ' bool FlutterWindowsTextureRegistrar::MarkTextureFrameAvailable(',
      '+}',
    );
    expect(
      mark,
      contains(
        'engine_->MarkExternalTextureFrameAvailableOnRasterThread(texture_id)',
      ),
    );
    final String added = mark
        .split('\n')
        .where((String l) => l.startsWith('+'))
        .join('\n');
    expect(added, isNot(contains('task_runner()')));
    // 原版那段 post 到平台线程的实现被删掉。
    expect(
      patch,
      contains(
        '-  engine_->task_runner()->RunNowOrPostTask([engine = engine_, texture_id]() {\n'
        '-    engine->MarkExternalTextureFrameAvailable(texture_id);',
      ),
    );
  });

  test('raster 线程上：先取走待标记集合并清 scheduled，再 mark、再重画上一棵树', () {
    final String patch = _read(patchPath);
    final String impl = _between(
      patch,
      '+bool EmbedderEngine::MarkTextureFrameAvailableOnRasterThread(',
      '+  return true;\n+}',
    );
    // 生产方线程：入集合；已有排队的重画就不再排（合并）。
    final int push = impl.indexOf('state->marked.push_back(texture);');
    final int coalesce = impl.indexOf('if (state->scheduled) {');
    final int post = impl.indexOf('GetRasterTaskRunner()->PostTask(');
    expect(push, greaterThan(0));
    expect(coalesce, greaterThan(push));
    expect(post, greaterThan(coalesce));
    // raster 任务：swap + scheduled=false 在同一把锁里、在 mark 之前——之后来的 mark
    // 必须能排下一次重画，否则它画好的帧被这次重画漏掉、又没人再画。
    final int swap = impl.indexOf('marked.swap(state->marked);', post);
    final int clear = impl.indexOf('state->scheduled = false;', post);
    final int markNew = impl.indexOf('MarkNewFrameAvailable();', post);
    final int draw = impl.indexOf(
      'rasterizer->DrawLastLayerTrees(std::move(recorder));',
      post,
    );
    expect(swap, greaterThan(post));
    expect(clear, greaterThan(swap));
    expect(markNew, greaterThan(clear));
    expect(draw, greaterThan(markNew));
    // 不经 Animator / 平台线程。
    expect(impl, isNot(contains('ScheduleFrame')));
    expect(impl, isNot(contains('GetPlatformTaskRunner')));
    expect(impl, isNot(contains('GetUITaskRunner')));
    // 帧时记录器按 Animator::DrawLastLayerTrees 的方式补齐 vsync / build。
    expect(impl, contains('recorder->RecordVsync(now, now + frame_interval);'));
    expect(impl, contains('recorder->RecordBuildStart(now);'));
    expect(impl, contains('recorder->RecordBuildEnd(now);'));
  });

  test('embedder API 追加在 proc table 末尾并已注册', () {
    final String patch = _read(patchPath);
    expect(
      patch,
      contains(
        '   FlutterEngineSendSemanticsActionFnPtr SendSemanticsAction;\n'
        '+  // Fushi patch (texture frames on the raster thread); appended last.\n'
        '+  FlutterEngineMarkExternalTextureFrameAvailableOnRasterThreadFnPtr\n'
        '+      MarkExternalTextureFrameAvailableOnRasterThread;\n'
        ' } FlutterEngineProcTable;',
      ),
    );
    expect(
      patch,
      contains(
        '+  SET_PROC(MarkExternalTextureFrameAvailableOnRasterThread,\n'
        '+           FlutterEngineMarkExternalTextureFrameAvailableOnRasterThread);',
      ),
    );
  });

  test('单测：生产方线程上同步调到 raster 入口，平台线程入口不被调用', () {
    final String patch = _read(patchPath);
    expect(
      patch,
      contains(
        '+     MarkFrameAvailableFromProducerThreadSkipsPlatformThread) {',
      ),
    );
    expect(patch, contains('+  EXPECT_EQ(marked_on, producer);'));
    expect(
      patch,
      contains(
        '+        ADD_FAILURE() << "texture marks must not need the platform thread";',
      ),
    );
  });
}

String _between(String text, String start, String end) {
  final int from = text.indexOf(start);
  expect(from, greaterThanOrEqualTo(0), reason: start);
  final int to = text.indexOf(end, from);
  expect(to, greaterThan(from), reason: end);
  return text.substring(from, to);
}

String _fushiDir() {
  final Directory cwd = Directory.current;
  if (File('${cwd.path}/pubspec.yaml').existsSync() &&
      Directory('${cwd.path}/windows/runner').existsSync()) {
    return cwd.path;
  }
  return '${cwd.path}/fushi';
}

String _fvmFlutterVersion(String fushi) {
  final Object? json = jsonDecode(_read('$fushi/.fvmrc'));
  return (json! as Map<String, Object?>)['flutter']! as String;
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');
