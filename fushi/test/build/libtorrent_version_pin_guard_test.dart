import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1772 源码扫描守卫：内置 torrent 引擎的 libtorrent 版本必须钉死。
///
/// 病灶：CI 原来跑的是 classic 模式的裸 `vcpkg install libtorrent:x64-windows`
/// / `libtorrent:arm64-android` —— 装到哪个版本完全由 runner 镜像内固化的 vcpkg
/// 修订决定，仓库这边一个字都管不着。vcpkg 在 e90cc0982b（2026-08-12）把
/// ports/libtorrent 从 2.0.11 升到 2.1.1，镜像 20260818.277.1 跟进，于是
/// fushi_torrent_ffi.cpp 里五处 2.0-only API（torrent_info::files() /
/// lt::add_files / create_torrent(file_storage) / lt::from_span / peer_info::ip）
/// 同时编不过，Windows 4 个 DLL 和 Android .so 一起断供 —— 而
/// build_windows_dll.ps1 对 Release 校验那 4 个 DLL 缺一即 throw，等于 Windows
/// 正式包直接出不来。develop 上连红，且不是任何一个 commit 引入的。
///
/// 修复是 native/fushi_torrent/vcpkg.json（manifest + overrides 钉 2.0.11）。
/// 这个守卫钉住让它继续生效的三个条件；任何一条被破坏，都会重演一次同款断供。
void main() {
  const String nativeDir = '../native/fushi_torrent';

  test('vcpkg.json 把 libtorrent 钉在 2.0.x（overrides + builtin-baseline）', () {
    final File manifest = File('$nativeDir/vcpkg.json');
    expect(manifest.existsSync(), isTrue,
        reason: 'native/fushi_torrent/vcpkg.json 是版本钉定的唯一真相源，删掉它'
            '就退回「装到哪版看 runner 心情」的不可重现构建');

    final Map<String, dynamic> json =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;

    final Object? baseline = json['builtin-baseline'];
    expect(baseline, isA<String>(),
        reason: 'overrides 只有在 versioning 生效时才被考虑，而 builtin-baseline '
            '是启用 versioning 的必填项；缺了它 overrides 会被静默忽略');
    expect((baseline! as String).length, 40,
        reason: 'builtin-baseline 必须是完整 40 位 commit sha');

    final List<dynamic> overrides =
        (json['overrides'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> pin = overrides
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> o) => o['name'] == 'libtorrent',
            orElse: () => <String, dynamic>{});
    expect(pin['version'], isNotNull,
        reason: 'libtorrent 必须显式钉版；注意字段名是 version（2.0.11 的 port 用的是 '
            'relaxed scheme），写成 version-string / version-semver 会被 vcpkg 拒掉');
    expect((pin['version']! as String).startsWith('2.0.'), isTrue,
        reason: 'bridge 用的是 2.0 API；要升 2.1 得先改 fushi_torrent_ffi.cpp '
            '那五处调用，不能只动这里');
  });

  test('CI 不得退回 classic vcpkg install（版本会重新随 runner 镜像漂）', () {
    for (final String name in <String>[
      'build-multiplatform.yml',
      'release-desktop.yml',
      'release.yml',
    ]) {
      final File wf = File('../.github/workflows/$name');
      if (!wf.existsSync()) continue;
      final String text = wf.readAsStringSync();
      for (final String line in const LineSplitter().convert(text)) {
        final String bare = line.trim();
        if (bare.startsWith('#')) continue;
        expect(bare.contains('install libtorrent'), isFalse,
            reason: '$name 又出现 classic `vcpkg install libtorrent`：manifest 模式'
                '下依赖由 cmake 工具链按 vcpkg.json 装，classic 装的是 ports 当下'
                '的版本，会把 2.0 的钉定绕过去（BUG-1772）');
      }
    }
  });

  test('Android 构建脚本把 overlay triplets 传给 cmake（否则静默降到 API 28）', () {
    for (final String name in <String>[
      'build_android_so.sh',
      'build_android_so.ps1',
    ]) {
      final String text = File('$nativeDir/$name').readAsStringSync();
      expect(text.contains('VCPKG_OVERLAY_TRIPLETS'), isTrue,
          reason: '$name 必须给 cmake 传 -DVCPKG_OVERLAY_TRIPLETS：manifest 模式下'
              '装依赖的是 vcpkg 工具链而不是命令行，overlay 不参与就会退回 vcpkg '
              '自带的 arm64-android（钉 API 28），boost.asio 会引用 API 28 才有的 '
              'aligned_alloc，bridge 按 minSdk 24 链接直接 undefined symbol');
    }
  });

  test('bridge 仍在用 2.0-only API —— 钉版和源码必须同进退', () {
    final String cpp =
        File('$nativeDir/fushi_torrent_ffi.cpp').readAsStringSync();
    // 这几处是 2.1 移除/改名的：只要还在，vcpkg.json 就必须钉 2.0.x（上一条测试保证）。
    // 真迁到 2.1 后它们会一起消失，这条断言自然失效 —— 那时才允许动 overrides。
    final List<String> markers = <String>[
      'lt::add_files',
      'lt::from_span',
      'pi.ip',
    ];
    final List<String> present =
        markers.where((String m) => cpp.contains(m)).toList();
    expect(present, isNotEmpty,
        reason: 'fushi_torrent_ffi.cpp 已经不含任何 2.0-only 调用了？如果 bridge 真的'
            '迁到了 2.1 API，请同时把 vcpkg.json 的 libtorrent overrides 一起改掉，'
            '并删掉这条断言 —— 否则钉定和源码会各说各话（BUG-1772）');
  });
}
