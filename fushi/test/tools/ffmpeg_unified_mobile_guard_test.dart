// 守卫：随包（vendored-binaries 清单钉住）的 Android / iOS / macOS 统一 FFmpeg 产物（tool/ffmpeg-unified，FFmpegKitNext
// 构建）必须是「配方声明的那一份」，且具备播放器与制卡都依赖的能力。
//
// 这批二进制同时服务两端：
//   - 制卡 / 导出 / ASR：Android/iOS 经 FFmpegKitNext 进程内运行，macOS 经随包的
//     ffmpeg / ffprobe 程序（CliFfmpegBackend）；
//   - 播放：libmpv 动态链接**同一批** libav* 库（Android libmpv.so 的 DT_NEEDED、Apple
//     Mpv.framework 的 @rpath/libavcodec.framework）。
// 所以这里缺一项，要么播放回退、要么制卡静默失败。产物在 CI 构建（.github/workflows/
// ffmpeg-unified-mobile.yml），人工 vendor 入库，配方与产物之间没有别的自动关联——这条
// 守卫就是那条关联。
//
// 判据纪律（BUG-1057）：configure 串只说明「声明了」，编解码器还要用库自身才有的字符串
// 证明「真链进去了」；每个平台 / ABI / 切片都验，只验一个会漏掉「那一份没编上」。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show MiningClipFormat;

const String _plugin = '../third_party/ffmpeg_kit_next_flutter';
const String _aarPath = '$_plugin/android/libs/ffmpeg-kit-next.aar';
const String _iosFrameworks = '$_plugin/ios/ffmpeg_kit_next_flutter/Frameworks';
const String _macosLayout =
    '../third_party/media_kit_libs_macos_video/native/ffmpeg-unified-macos.tar.gz';

const List<String> _ffmpegLibs = <String>[
  'libavcodec',
  'libavdevice',
  'libavfilter',
  'libavformat',
  'libavutil',
  'libswresample',
  'libswscale',
];

/// 所有平台 configure 都必须带的开关（tool/ffmpeg-unified/mobile/kit_options.sh）。
const List<String> _commonFlags = <String>[
  '--enable-gpl',
  '--enable-libx264',
  '--enable-libvpx',
  '--enable-libopus',
  '--enable-libdav1d',
  '--enable-libsvtav1',
  '--enable-libwebp',
  '--enable-openssl',
  '--enable-libxml2',
  '--enable-zlib',
];

/// 封装名 + 库自身独有的串：两证齐全才算真链进去（BUG-1057 / BUG-2947）。
const Map<String, String> _codecProof = <String, String>{
  'libx264': 'FFmpeg 的 H.264 编码器封装（片段导出 / 转码）',
  'x264 - core': 'x264 自身的版本串',
  'libvpx-vp9': 'VP9 编码器封装（WebM 音画同步片段）',
  'WebM Project VP9 Encoder': 'libvpx 自身的编码器名',
  'libopus': 'Opus 编码器封装',
  'request not implemented': 'libopus 自身的错误信息表',
  'libsvtav1': 'AV1 编码器封装（WebM·AV1 片段、AVIF 动图）',
  'SVT-AV1': 'SVT-AV1 自身的串',
  'libdav1d': 'AV1 软件解码器封装（BUG-2947）',
  'Malformed ITU-T T.35 metadata message format': 'dav1d 自身的日志串',
  'libwebp': 'WebP 编码器封装（WebP 动图封面）',
  'truehd': 'TrueHD 解码器（BUG-073：播放器）',
};

/// BUG-3503：dash demuxer 也要两证。在线视频源给 `manifest.mpd` 时制卡与播放都靠它，
/// 它硬依赖 libxml2；configure 里的 `--enable-libxml2` 只说明声明了。判 dashdec.c 与
/// libxml2 自身独有的串：dash **muxer** 没有这两个串，不会因 dashenc 而假绿。
const Map<String, String> _dashDemuxerProof = <String, String>{
  'missing root node': 'libavformat/dashdec.c 的 MPD 解析日志（dash demuxer 在）',
  'xmlParseCharRef': 'libxml2 自身的错误串（证明真链进了 libxml2）',
};

/// 补丁 0004：Apple 上 OpenSSL 的默认 CA 目录是 CI 构建机的前缀（设备上不存在），
/// FFmpeg 8+ 又默认校验证书——不改就是 iOS / macOS 公网 HTTPS 全挂。补丁改为交给
/// 系统信任库（Security.framework SecTrust）校验；这两个串分别证明「校验代码在」与
/// 「libavformat 真链了 Security.framework」（LC_LOAD_DYLIB：iOS 是
/// `.../Security.framework/Security`，macOS 是 `.../Versions/A/Security`，取公共前缀）。
const String _appleTrustMarker = 'System trust rejected the certificate';
const String _securityFramework =
    '/System/Library/Frameworks/Security.framework/';

/// capabilities.json 的类别 → 注册该类组件的库。
const Map<String, String> _capabilityLibs = <String, String>{
  'encoders': 'libavcodec',
  'decoders': 'libavcodec',
  'bsfs': 'libavcodec',
  'muxers': 'libavformat',
  'demuxers': 'libavformat',
  'protocols': 'libavformat',
  'filters': 'libavfilter',
};

String _text(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);

/// GPL「对应源码」声明必须指向本仓配方与补丁（tool/ffmpeg-unified/source_notice.py
/// 生成），上游 FFmpegKitNext 的原文只指向它自己的 wiki，不含 Fushi 补丁。
void _expectSourceNotice(String label, String text) {
  expect(
    text,
    contains('https://github.com/hajisensai/Fushi/tree/'),
    reason: '$label 的源码声明没指向 Fushi 仓库的具体提交',
  );
  expect(text, contains('tool/ffmpeg-unified'), reason: label);
  expect(text, contains('patches/ffmpeg/0001-'), reason: '$label 没列出 Fushi 补丁');
}

Map<String, dynamic> _capabilities() =>
    jsonDecode(
          File('../tool/ffmpeg-unified/capabilities.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

/// 组件结构体的短名（`.name`）即使 --enable-small 也保留，没编进去的组件不会留下
/// 「前后都是 NUL 的这个名字」。与 mobile/verify_mobile_outputs.py 同一判据。
bool _hasComponent(String lib, String name) => lib.contains('\x00$name\x00');

String _recipeVersion() => File('../tool/ffmpeg-unified/recipe.env')
    .readAsLinesSync()
    .firstWhere((String l) => l.startsWith('FFMPEG_VERSION='))
    .split('=')
    .last
    .trim();

/// 一个平台 / ABI / 切片的完整判据。
void _expectUnified({
  required String label,
  required Map<String, List<int>> libs,
  required List<String> platformFlags,
  List<int>? kitLib,
  bool android = false,
  bool apple = false,
}) {
  for (final String lib in _ffmpegLibs) {
    expect(libs.containsKey(lib), isTrue, reason: '$label 缺 $lib');
  }
  final String util = _text(libs['libavutil']!);
  final RegExpMatch? conf = RegExp(
    r'--(?:prefix|cross-prefix|arch|target-os)=[^\x00]{200,}',
  ).firstMatch(util);
  expect(conf, isNotNull, reason: '$label 的 libavutil 里没有内嵌 configure 串');
  final String configuration = conf!.group(0)!;
  for (final String flag in <String>[..._commonFlags, ...platformFlags]) {
    expect(
      configuration,
      contains(flag),
      reason:
          '$label 的 configure 缺 $flag——入库产物与配方不符，重跑 '
          'ffmpeg-unified-mobile.yml 并重新 vendor',
    );
  }
  expect(
    configuration,
    isNot(contains('--disable-everything')),
    reason: '统一 FFmpeg 是全组件构建（播放器也用它）',
  );
  expect(
    util.contains(_recipeVersion()) ||
        _text(libs['libavcodec']!).contains(_recipeVersion()),
    isTrue,
    reason: '$label 的 FFmpeg 版本不是 recipe.env 的 ${_recipeVersion()}',
  );

  final String codec = _text(libs['libavcodec']!);
  _codecProof.forEach((String needle, String what) {
    expect(
      codec.contains(needle),
      isTrue,
      reason: '$label libavcodec 里没有「$needle」（$what）',
    );
  });
  // png 编码器硬依赖 zlib 的 deflate（BUG-2366 时移动端恰好缺它）。
  expect(
    RegExp(r'_?deflate(Init|Init2)?_').hasMatch(codec),
    isTrue,
    reason: '$label libavcodec 没有链 zlib deflate → 没有 png 编码器（BUG-2366）',
  );

  final String format = _text(libs['libavformat']!);
  expect(
    format.contains('matroskaenc'),
    isTrue,
    reason:
        '$label libavformat 没有 matroska muxer：播放器 dump-cache（在线视频'
        '制卡快照）会恒失败',
  );
  expect(
    format.contains('tls_pin_sha256'),
    isTrue,
    reason: '$label 缺补丁 0001（远端自签主机证书钉扎，BUG-891）',
  );
  if (apple) {
    expect(
      format.contains(_appleTrustMarker),
      isTrue,
      reason:
          '$label 缺补丁 0004：Apple 上 OpenSSL 没有可用的信任库，FFmpeg 默认校验'
          '证书 → 公网 HTTPS 全挂',
    );
    expect(
      format.contains(_securityFramework),
      isTrue,
      reason:
          '$label 的 libavformat 没链 Security.framework（补丁 0004 的 configure 段）',
    );
  } else {
    // 负向对照：Apple 专用代码不该出现在别的平台，证明上面的判据能区分。
    expect(
      format.contains(_appleTrustMarker),
      isFalse,
      reason: '$label 不是 Apple，却带了 Apple 信任库校验串——#ifdef __APPLE__ 失效',
    );
  }
  final Map<String, dynamic> caps = _capabilities();
  _capabilityLibs.forEach((String key, String lib) {
    final String blob = lib == 'libavcodec'
        ? codec
        : lib == 'libavformat'
        ? format
        : _text(libs[lib]!);
    for (final dynamic name in caps[key] as List<dynamic>) {
      expect(
        _hasComponent(blob, name as String),
        isTrue,
        reason: '$label 低于能力下限：$lib 里没有 $key「$name」（capabilities.json）',
      );
    }
  });
  _dashDemuxerProof.forEach((String needle, String what) {
    expect(
      format.contains(needle),
      isTrue,
      reason:
          '$label libavformat 里没有「$needle」（$what）——在线源 .mpd 制卡 / 播放'
          '会报 Invalid data（BUG-3503）',
    );
  });
  if (android) {
    expect(
      format.contains('Android system CA certificates'),
      isTrue,
      reason:
          '$label 缺补丁 0001 的 Android 系统 CA 加载：FFmpeg 8+ 默认校验证书，'
          '公网 HTTPS 会全挂',
    );
  }
  expect(
    util.contains('av_log_fushi_set_primary_callback'),
    isTrue,
    reason: '$label 缺补丁 0002（libmpv 与 FFmpegKit 共用日志回调）',
  );
  if (kitLib != null) {
    expect(
      _text(kitLib).contains('av_log_fushi_set_primary_callback'),
      isTrue,
      reason:
          '$label 的 ffmpegkit 没打 kit 补丁 0001：它仍会用 av_log_set_callback '
          '抢走 libmpv 的日志 / 被 libmpv 抢走会话输出',
    );
  }
}

void main() {
  group('Android AAR（arm64-v8a / armeabi-v7a / x86_64）', () {
    late Archive aar;
    setUpAll(() {
      final File file = File(_aarPath);
      expect(file.existsSync(), isTrue, reason: '入库 AAR 缺失：${file.path}');
      aar = ZipDecoder().decodeBytes(file.readAsBytesSync());
    });

    test('64 位 ABI 的每个 .so 都按 16 KB 页对齐（Android 15+ / Google Play）', () {
      for (final ArchiveFile f in aar.files.where(
        (ArchiveFile f) =>
            f.name.endsWith('.so') &&
            (f.name.startsWith('jni/arm64-v8a/') ||
                f.name.startsWith('jni/x86_64/')),
      )) {
        final List<int> b = f.content as List<int>;
        final ByteData d = ByteData.sublistView(Uint8List.fromList(b));
        expect(b[4], 2, reason: '${f.name} 不是 64 位 ELF');
        final int phoff = d.getUint64(32, Endian.little);
        final int phentsize = d.getUint16(54, Endian.little);
        final int phnum = d.getUint16(56, Endian.little);
        int loads = 0;
        for (int i = 0; i < phnum; i++) {
          final int h = phoff + i * phentsize;
          if (d.getUint32(h, Endian.little) != 1) continue;
          loads++;
          expect(
            d.getUint64(h + 48, Endian.little),
            greaterThanOrEqualTo(16384),
            reason: '${f.name} LOAD $i 未按 16 KB 对齐：16 KB 页设备上加载失败',
          );
        }
        expect(loads, greaterThan(0), reason: f.name);
      }
    });

    test('ABI 集合正好三个，且没有 *_neon 变体（libmpv 按原名链接）', () {
      final Set<String> abis = aar.files
          .map((ArchiveFile f) => f.name)
          .where((String n) => n.startsWith('jni/') && n.split('/').length == 3)
          .map((String n) => n.split('/')[1])
          .toSet();
      expect(abis, <String>{'arm64-v8a', 'armeabi-v7a', 'x86_64'});
      expect(
        aar.files.where((ArchiveFile f) => f.name.contains('_neon')),
        isEmpty,
      );
    });

    test('GPL 许可、各外部库许可与源码获取声明随 AAR 分发', () {
      final ArchiveFile? license = aar.findFile('res/raw/license.txt');
      expect(license, isNotNull, reason: 'AAR 缺 res/raw/license.txt');
      expect(
        _text(license!.content as List<int>),
        contains('GNU GENERAL PUBLIC LICENSE'),
        reason: 'GPL 构建的 FFmpeg 必须带 GPL 许可原文',
      );
      for (final String extra in <String>[
        'license_x264.txt',
        'license_libvpx.txt',
        'license_opus.txt',
        'license_dav1d.txt',
        'license_libsvtav1.txt',
        'license_libwebp.txt',
        'license_openssl.txt',
        'license_libxml2.txt',
        'source.txt',
      ]) {
        expect(
          aar.findFile('res/raw/$extra'),
          isNotNull,
          reason: 'AAR 缺 res/raw/$extra：外部库许可 / GPL「源码获取途径」声明不得丢失',
        );
      }
      _expectSourceNotice(
        'AAR res/raw/source.txt',
        utf8.decode(aar.findFile('res/raw/source.txt')!.content as List<int>),
      );
    });

    for (final String abi in <String>['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      test('$abi：统一配方 + 能力 + 全部补丁', () {
        List<int> so(String lib) {
          final ArchiveFile? f = aar.findFile('jni/$abi/$lib.so');
          if (f == null) fail('AAR 里没有 jni/$abi/$lib.so');
          return f.content as List<int>;
        }

        _expectUnified(
          label: 'Android $abi',
          libs: <String, List<int>>{
            for (final String l in _ffmpegLibs) l: so(l),
          },
          platformFlags: const <String>['--enable-mediacodec', '--enable-jni'],
          kitLib: so('libffmpegkit'),
          android: true,
        );
      });
    }
  });

  group('iOS xcframework（device + simulator）', () {
    for (final String slice in <String>[
      'ios-arm64',
      'ios-arm64_x86_64-simulator',
    ]) {
      test('$slice：统一配方 + 能力 + 全部补丁', () {
        List<int> fw(String lib) {
          final File f = File(
            '$_iosFrameworks/$lib.xcframework/$slice/$lib.framework/$lib',
          );
          expect(f.existsSync(), isTrue, reason: '切片缺失：${f.path}');
          return f.readAsBytesSync();
        }

        _expectUnified(
          label: 'iOS $slice',
          libs: <String, List<int>>{
            for (final String l in _ffmpegLibs) l: fw(l),
          },
          platformFlags: const <String>['--enable-videotoolbox'],
          kitLib: fw('ffmpegkit'),
          apple: true,
        );
      });
    }
  });

  // BUG-3503 审查跟进（从 ffmpeg_kit_flutter 守卫移植）：动态 framework 自带
  // LC_LOAD_DYLIB，podspec 漏声明系统库不会链接失败，但 s.libraries 是「这个 pod 依赖
  // 哪些系统库」的唯一声明处——重编后多出一个 /usr/lib 库时这里当场红，而不是等到某个
  // iOS 版本上 dyld 找不到库才在真机启动时崩。
  test('iOS：ffmpegkit.framework 的 SOURCE 指向本仓配方', () {
    for (final String slice in <String>[
      'ios-arm64',
      'ios-arm64_x86_64-simulator',
    ]) {
      final File f = File(
        '$_iosFrameworks/ffmpegkit.xcframework/$slice/ffmpegkit.framework/SOURCE',
      );
      expect(f.existsSync(), isTrue, reason: f.path);
      _expectSourceNotice('iOS $slice SOURCE', f.readAsStringSync());
    }
  });

  group('iOS podspec 声明了 framework 链接的全部 /usr/lib 系统库', () {
    // libSystem / libobjc 由工具链隐式链接，podspec 不必（也不该）声明。
    const Set<String> implicitLibs = <String>{'System', 'objc'};
    final RegExp dylibRef = RegExp(
      r'/usr/lib/lib([A-Za-z0-9_+]+)\.(?:[A-Za-z0-9]+\.)*dylib',
    );

    Set<String> podspecLibraries() {
      final String podspec = File(
        '$_plugin/ios/ffmpeg_kit_next_flutter.podspec',
      ).readAsStringSync();
      final RegExpMatch? line = RegExp(
        r'^\s*s\.libraries\s*=\s*(.+)$',
        multiLine: true,
      ).firstMatch(podspec);
      expect(line, isNotNull, reason: 'podspec 里找不到 s.libraries');
      return RegExp(
        r"'([^']+)'",
      ).allMatches(line!.group(1)!).map((RegExpMatch m) => m.group(1)!).toSet();
    }

    Set<String> linkedSystemLibs() {
      final Set<String> libs = <String>{};
      for (final FileSystemEntity xc in Directory(_iosFrameworks).listSync()) {
        if (xc is! Directory || !xc.path.endsWith('.xcframework')) continue;
        final String name = xc.uri.pathSegments
            .lastWhere((String s) => s.isNotEmpty)
            .replaceAll('.xcframework', '');
        for (final FileSystemEntity slice in xc.listSync()) {
          if (slice is! Directory) continue;
          final File bin = File('${slice.path}/$name.framework/$name');
          if (!bin.existsSync()) continue;
          for (final RegExpMatch m in dylibRef.allMatches(
            _text(bin.readAsBytesSync()),
          )) {
            libs.add(m.group(1)!);
          }
        }
      }
      return libs;
    }

    test('linked ⊆ s.libraries ∪ 隐式库', () {
      final Set<String> declared = podspecLibraries();
      final Set<String> missing = linkedSystemLibs()
          .difference(declared)
          .difference(implicitLibs);
      expect(
        missing,
        isEmpty,
        reason:
            'framework 链接了 /usr/lib/lib{$missing} 但 podspec 的 '
            's.libraries 没声明（${declared.join(', ')}）',
      );
    });

    test('负向对照：扫描真读到了系统库（libc++ / libz / libiconv）', () {
      // 扫描若读错路径会得到空集，上一条就恒绿；这里钉住它确实看见了库。
      expect(linkedSystemLibs(), containsAll(<String>['c++', 'z', 'iconv']));
    });
  });

  group('macOS（播放器 framework + ffmpeg/ffprobe 程序，同一套库）', () {
    late Archive layout;
    setUpAll(() {
      final File file = File(_macosLayout);
      expect(file.existsSync(), isTrue, reason: '入库 macOS 布局包缺失：${file.path}');
      layout = TarDecoder().decodeBytes(
        GZipDecoder().decodeBytes(file.readAsBytesSync()),
      );
    });

    test('arm64：统一配方 + 能力 + 补丁', () {
      List<int> fw(String lib) {
        final ArchiveFile? f = layout.findFile(
          'Frameworks/$lib.framework/Versions/A/$lib',
        );
        if (f == null) fail('布局包里没有 $lib.framework');
        return f.content as List<int>;
      }

      _expectUnified(
        label: 'macOS arm64',
        libs: <String, List<int>>{for (final String l in _ffmpegLibs) l: fw(l)},
        platformFlags: const <String>['--enable-videotoolbox'],
        apple: true,
      );
    });

    test('每个 libav* framework 带指向本仓配方的 SOURCE', () {
      for (final String lib in _ffmpegLibs) {
        final ArchiveFile? f = layout.findFile(
          'Frameworks/$lib.framework/Versions/A/Resources/SOURCE',
        );
        expect(f, isNotNull, reason: '$lib.framework 缺 Resources/SOURCE');
        _expectSourceNotice('macOS $lib', utf8.decode(f!.content as List<int>));
      }
    });

    test(
      'ffmpeg / ffprobe 程序链接同一套 @rpath framework，rpath 指向 ../Frameworks',
      () {
        for (final String prog in <String>['ffmpeg', 'ffprobe']) {
          final ArchiveFile? f = layout.findFile('MacOS/$prog');
          expect(f, isNotNull, reason: '布局包里没有 MacOS/$prog');
          final String bin = _text(f!.content as List<int>);
          expect(
            bin,
            contains('@rpath/libavcodec.framework/libavcodec'),
            reason: '$prog 必须链接随包的统一 FFmpeg framework（与播放器同一份）',
          );
          expect(
            bin,
            contains('@executable_path/../Frameworks'),
            reason: '$prog 的 rpath 必须指向 app 的 Contents/Frameworks',
          );
          expect(
            RegExp(
              r'/(opt/homebrew|usr/local|Users)/[^\x00]*\.dylib',
            ).hasMatch(bin),
            isFalse,
            reason: '$prog 依赖了构建机专有的共享库（BUG-1443）',
          );
        }
      },
    );
  });

  group('Apple TLS 校验走系统信任库（配方层，补丁 0004）', () {
    final File patch = Directory('../tool/ffmpeg-unified/patches/ffmpeg')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (File f) => f.path.contains('0004-'),
          orElse: () => fail('缺补丁 0004（Apple 系统信任库校验）'),
        );
    final String body = patch.readAsStringSync();

    test('OpenSSL 校验回调交给 SecTrust，默认 CA 路径在 Apple 上不用', () {
      expect(
        body,
        contains(
          'SSL_CTX_set_cert_verify_callback(c->ctx, openssl_apple_verify_cb, h)',
        ),
      );
      expect(
        body,
        contains('SecPolicyCreateSSL(true, host)'),
        reason: '必须按主机名校验（SSL server policy），不能只验链',
      );
      expect(body, contains('SecTrustEvaluateWithError'));
      expect(
        body,
        contains('+#ifndef __APPLE__'),
        reason: 'Apple 上不能再去读 OpenSSL 编进去的构建机 CA 目录',
      );
      expect(
        body,
        contains(
          'append openssl_extralibs "-framework CoreFoundation -framework Security"',
        ),
      );
    });

    test('负向对照：回调安装与 Security 头文件都在 #ifdef __APPLE__ 内', () {
      final List<String> added = body
          .split('\n')
          .where((String l) => l.startsWith('+') && !l.startsWith('+++'))
          .map((String l) => l.substring(1))
          .toList();
      int depth = 0;
      bool insideApple = false;
      for (final String line in added) {
        if (line.startsWith('#ifdef __APPLE__')) {
          insideApple = true;
          depth = 1;
          continue;
        }
        if (insideApple && line.startsWith('#if')) depth++;
        if (insideApple && line.startsWith('#endif')) {
          depth--;
          if (depth == 0) insideApple = false;
          continue;
        }
        if (line.contains('SSL_CTX_set_cert_verify_callback') ||
            line.contains('#include <Security/')) {
          expect(insideApple, isTrue, reason: '「$line」不在 #ifdef __APPLE__ 内');
        }
      }
    });

    test('podspec 声明 Security.framework；macOS 构建跑公网 HTTPS 信任冒烟', () {
      final String podspec = File(
        '$_plugin/ios/ffmpeg_kit_next_flutter.podspec',
      ).readAsStringSync();
      expect(
        RegExp(
          r"^\s*s\.frameworks\s*=.*'Security'",
          multiLine: true,
        ).hasMatch(podspec),
        isTrue,
      );
      final String macos = File(
        '../tool/ffmpeg-unified/mobile/build_macos.sh',
      ).readAsStringSync();
      expect(macos, contains('https_trust_smoke.sh'));
      expect(
        macos,
        contains("'System trust rejected the certificate'"),
        reason: '坏证书必须被补丁 0004 的校验器拒绝，而不是碰巧失败',
      );
      expect(
        macos,
        isNot(contains('badssl.com')),
        reason: '负向用例由脚本在本地起 openssl s_server，不再依赖外部站点',
      );
    });

    test('信任冒烟：负向用例本地封闭、正向用例区分「网络不可达」与「校验失败」', () {
      final String smoke = File(
        '../tool/ffmpeg-unified/https_trust_smoke.sh',
      ).readAsStringSync();
      // 负向：自签 / 错主机名 / 过期证书全在脚本里现生成，127.0.0.1 上的 s_server 提供。
      expect(smoke, isNot(contains('badssl.com')));
      expect(smoke, contains('openssl s_server'));
      expect(smoke, contains('subjectAltName = DNS:wrong.host.invalid'));
      expect(
        smoke,
        contains('-startdate "\$3" -enddate "\$4"'),
        reason: '过期证书须真的回填过去的有效期',
      );
      expect(
        smoke,
        contains('-http_proxy ""'),
        reason: '本地用例绝不能经代理离开 127.0.0.1',
      );
      // 对照组：同一套本地 CA 的合法证书必须能打开，否则错主机名 / 过期的失败不说明问题。
      expect(smoke, contains('D. control'));
      // 正向：先 tls_verify=0 判可达，不可达单独退出 3，不能被当成校验失败或通过。
      expect(smoke, contains('-tls_verify 0'));
      expect(smoke, contains('NETWORK UNREACHABLE'));
      expect(smoke, contains('exit 3'));
      // 正向源钉在固定提交上的固定文件，内容不会随分支变化或消失。
      expect(
        RegExp(
          r'raw\.githubusercontent\.com/hajisensai/Fushi/[0-9a-f]{40}/',
        ).hasMatch(smoke),
        isTrue,
      );
    });
  });

  test('GPL 源码声明指向本仓配方与补丁（source_notice.py → 各平台）', () {
    expect(
      File('../tool/ffmpeg-unified/mobile/prepare_kit.sh').readAsStringSync(),
      contains('source_notice.py" > "\${KIT}/tools/source/SOURCE"'),
    );
    expect(
      File('../tool/ffmpeg-unified/mobile/build_macos.sh').readAsStringSync(),
      contains('tools/source/SOURCE" "\${res}/SOURCE"'),
    );
    expect(
      File('../tool/bluray/package_libmpv.py').readAsStringSync(),
      contains('source_notice.py'),
    );
  });

  test('片段格式降级链不变：AV1 → VP9 → MP4（只给外部 ffmpeg 兜底）', () {
    expect(MiningClipFormat.webmAv1.encodeAttempts, <MiningClipFormat>[
      MiningClipFormat.webmAv1,
      MiningClipFormat.webmVp9,
      MiningClipFormat.mp4H264,
    ]);
  });
}
