import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Windows 着色器程序磁盘缓存（`engine-program-binary-cache.patch` + runner）的源码守卫。
///
/// 冷启动时 Impeller 在 ContentContext 构造里把全部管线经 ANGLE → d3dcompiler 重编，
/// 主线程在 `PlatformView::NotifyCreated` 上干等约 1 秒。补丁把 ANGLE 的
/// `EGL_ANDROID_blob_cache` 接到磁盘上。这条链路任何一环退回原样都不会编译失败，只会
/// 静默变回「每次重编」，或者更糟：读到别的引擎写的二进制、在启动关键路径上同步写盘、
/// 测试进程写进生产数据根、原版引擎下 app 起不来。下面把这些点咬住。
void main() {
  final String fushi = _fushiDir();
  final String repo = Directory(fushi).parent.path;
  final String flutterVersion = _fvmFlutterVersion(fushi);
  final String patchDir = '$repo/ci/patches/flutter-engine/$flutterVersion';
  final String patchPath = '$patchDir/engine-program-binary-cache.patch';

  test('补丁存在、是 LF，且构建脚本按序打它', () {
    expect(File(patchPath).existsSync(), isTrue);
    expect(File(patchPath).readAsBytesSync().contains(13), isFalse);
    final String script = _read(
      '$repo/tool/flutter_engine/build_patched_engine.ps1',
    );
    final int a11y = script.indexOf("'engine-a11y-tree-hardening.patch'");
    final int cache = script.indexOf("'engine-program-binary-cache.patch'");
    expect(a11y, greaterThan(0));
    // 叠在全部引擎补丁之后（改的是同一份 egl::Manager / flutter_windows.{h,cc}）。
    expect(cache, greaterThan(a11y));
  });

  test('引擎：display 初始化后、建上下文之前装上 blob cache 回调', () {
    final String patch = _read(patchPath);
    expect(patch, contains('+  InstallProgramBinaryCache();'));
    final int install = patch.indexOf('+  InstallProgramBinaryCache();');
    final int contexts = patch.indexOf('if (!InitializeConfig()) {', install);
    expect(contexts, greaterThan(install));
    expect(patch, contains('"eglSetBlobCacheFuncsANDROID"'));
    expect(patch, contains('"EGL_ANDROID_blob_cache"'));
    // display 被多个 manager 共用、最后一个才 terminate；terminate 会清掉回调。
    expect(patch, contains('+      program_binary_cache_installed_ = false;'));
  });

  test('缓存：命名空间折入引擎版本与模块文件，别的构建的目录被清掉', () {
    final String patch = _read(patchPath);
    expect(patch, contains('+  recipe += GetFlutterEngineVersion();'));
    expect(patch, contains('GetModuleFileNameW(module'));
    expect(patch, contains(r'directory_(root_ + L"\\" + namespace_tag_),'));
    expect(patch, contains('IsNamespaceFolderName(name)'));
    expect(patch, contains('+    "//flutter/shell/version",'));
  });

  test('缓存：读时校验头与校验和，坏文件当未命中并删除', () {
    final String patch = _read(patchPath);
    expect(
      patch,
      contains('+  if (std::memcmp(stored_key, key, key_size) != 0) {'),
    );
    expect(
      patch,
      contains(
        '+  if (GetU64(header + 24) != Fnv1a(Fnv1a(kFnvOffset, stored_key, '
        'key_size),',
      ),
    );
    expect(
      patch,
      contains('+    Enqueue({Task::Kind::kDelete, file_name, nullptr});'),
    );
  });

  test('缓存：写盘只在后台低优先级线程，临时文件 + 原子改名，总量封顶', () {
    final String patch = _read(patchPath);
    // Put 只入队，不碰文件。
    final String put = _between(
      patch,
      '+void ProgramBinaryCache::Put(',
      '+void ProgramBinaryCache::Enqueue(',
    );
    expect(put, isNot(contains('CreateFileW')));
    expect(put, isNot(contains('WriteFile')));
    expect(put, contains('tasks_.push_back({Task::Kind::kWrite'));
    expect(patch, contains('THREAD_MODE_BACKGROUND_BEGIN'));
    expect(
      patch,
      contains(
        'MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)',
      ),
    );
    expect(
      patch,
      contains('+    uint64_t max_total_bytes = 32ull * 1024 * 1024;'),
    );
    expect(patch, contains('+void ProgramBinaryCache::EvictToLimit() {'));
    // 写不进（磁盘满 / 无权限）就整场停写，只退回照常编译。
    expect(patch, contains('+    case ERROR_DISK_FULL:'));
    expect(patch, contains('DisableWrites('));
  });

  test('runner：运行期解析导出（原版引擎没有它也能启动），且在建引擎之前调用', () {
    final String main = _read('$fushi/windows/runner/main.cpp');
    expect(main, contains('"FlutterDesktopSetProgramBinaryCacheDirectory"'));
    expect(main, contains('GetProcAddress(engine,'));
    expect(
      RegExp(
        r'[^"]FlutterDesktopSetProgramBinaryCacheDirectory\(',
      ).hasMatch(main),
      isFalse,
      reason: '直接调用会让原版 flutter_windows.dll 加载失败',
    );
    final int call = main.indexOf('  ConfigureProgramBinaryCache();');
    final int window = main.indexOf('FlutterWindow window(project);');
    expect(call, greaterThan(0));
    expect(window, greaterThan(call));
  });

  test('runner：测试根下缓存落进测试根，其余跟着 exe 走、不进生产数据根', () {
    final String main = _read('$fushi/windows/runner/main.cpp');
    final String resolve = _between(
      main,
      'std::wstring ResolveProgramBinaryCacheDirectory() {',
      'void ConfigureProgramBinaryCache() {',
    );
    final int testRoot = resolve.indexOf('L"FUSHI_TEST_ROOT"');
    final int exe = resolve.indexOf('GetModuleFileNameW(nullptr');
    expect(testRoot, greaterThan(0));
    expect(exe, greaterThan(testRoot), reason: '测试根优先于一切别的位置');
    expect(resolve, contains(r'L"\\cache\\shader-programs"'));
    expect(resolve, contains('L".ShaderCache"'));
    expect(resolve, contains(r'L"\\Fushi\\ShaderCache\\"'));
    // 生产数据根是 Roaming 的 %APPDATA%\Fushi\Fushi，缓存永远不去那里。
    expect(resolve, isNot(contains('L"APPDATA"')));
    expect(resolve, isNot(contains('FOLDERID_RoamingAppData')));
  });

  test('安装器卸载时删掉 exe 旁的缓存目录', () {
    final String iss = _read('$fushi/windows/installer/fushi.iss');
    final RegExpMatch? section = RegExp(
      r'^\[UninstallDelete\]([\s\S]*?)^\[',
      multiLine: true,
    ).firstMatch(iss);
    expect(section, isNotNull);
    expect(
      section!.group(1),
      contains(r'Type: filesandordirs; Name: "{app}\fushi.exe.ShaderCache"'),
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
