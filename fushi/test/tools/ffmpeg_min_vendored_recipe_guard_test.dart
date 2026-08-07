// 守卫：入库的 Windows 精简 ffmpeg 二进制必须真的由当前构建配方编出来。
//
// 背景（BUG-1058）：`tool/ffmpeg-min/build-ffmpeg-min.sh` 是配方，
// `third_party/ffmpeg-min/windows/ffmpeg.exe` 是**手工**从 ffmpeg-min workflow 的
// artifact 拷进来的产物。两者之间没有任何自动关联：改了配方而忘记重跑 workflow +
// 重新 vendor，仓库照样绿，用户拿到的仍是旧能力的 exe。
//
// 这个坑真实发生过：PR#369「片段导出封入用户正在看的字幕」往 ENCODERS 里加了
// movtext（mp4 软字幕唯一可用的编码器），并给 smoke-test 加了 mov_text 校验——但
// smoke-test 只在 ffmpeg-min workflow 里跑，且只跑**刚编出来的**二进制，从不跑入库
// 的那个。于是入库 exe 一直缺 movtext，桌面端每次导出都静默降级成无字幕片段
// （见 exportVideoClipViaFfmpeg 的降级重试，video_clip_exporter.dart）。
//
// 本守卫消除这个「配方与产物各说各话」的结构性缺口：ffmpeg 会把完整的 configure
// 命令行以明文字符串编进二进制（`ffmpeg -version` 打印的就是它），所以无需执行
// exe——直接从字节里把它抠出来，跟配方逐项比对。纯 dart:io + 静态读取，Linux CI 上
// 同样有效（vendored exe 是普通入库文件，不是 LFS）。
//
// 失败即意味着：改了配方却没重新 vendor 二进制。修法见文件尾部的失败提示。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 构建脚本里的 shell 变量名 -> configure 的 `--enable-<flag>` 名。
///
/// 这 8 组是 build-ffmpeg-min.sh 里唯一以「逗号分隔组件清单」形式传给 configure 的
/// 变量，也是唯一会因为漏编而在运行时炸掉某条功能链路的部分。
const Map<String, String> _componentVarToFlag = <String, String>{
  'DEMUXERS': 'demuxer',
  'DECODERS': 'decoder',
  'ENCODERS': 'encoder',
  'MUXERS': 'muxer',
  'FILTERS': 'filter',
  'PARSERS': 'parser',
  'BSFS': 'bsf',
  'PROTOCOLS': 'protocol',
};

/// 必须出现在**每个平台**入库二进制 configure 串里的独立开关（非清单形式）。
///
/// libx264/gpl：H.264 片段导出（TODO-1257）。network：YouTube 远端制卡的 http(s)
/// 输入 + -reconnect（TODO-1214）。libsvtav1/libwebp：制卡封面动图的 AVIF / WebP
/// 编码器（默认格式已是 AVIF；缺它们时 Dart 侧会降级 GIF，卡还能制出来，但用户选的
/// 格式静默失效）。ffprobe：BUG-1420——配方曾传 --disable-ffprobe，而 Dart 侧
/// resolveFfprobeExecutable() 一直按「与 ffmpeg 并排捆绑」设计，导致内封字幕字体与
/// 音频容器元数据两条链在没装系统 ffmpeg 的机器上静默失效。
/// 少任何一个都是「二进制比配方旧」。
const List<String> _requiredStandaloneFlags = <String>[
  '--disable-everything',
  '--enable-gpl',
  '--enable-libx264',
  '--enable-libsvtav1',
  '--enable-libwebp',
  '--enable-network',
  '--enable-ffprobe',
];

/// 一个入库平台的校验目标。
///
/// BUG-1421 之前本守卫只认 Windows 的 ffmpeg.exe：macOS 从来没被 vendor 过，也就
/// 没有任何东西会红。现在每个 vendored 平台都要过同一套配方一致性检查，且 ffmpeg
/// 与 ffprobe **两个** exe 都查（它们由同一次 configure 编出，内嵌同一串配方）。
class _VendoredTarget {
  const _VendoredTarget({
    required this.label,
    required this.dir,
    required this.ffmpegName,
    required this.ffprobeName,
    required this.tlsFlag,
  });

  final String label;
  final String dir;
  final String ffmpegName;
  final String ffprobeName;

  /// 各平台走系统原生 TLS 后端（见 build-ffmpeg-min.sh 的 EXTRA_CONFIG 分支）：
  /// Windows schannel / macOS SecureTransport / Linux gnutls。
  final String tlsFlag;
}

/// 当前入库的平台。Linux 暂不入库——release-desktop.yml 没有 Linux 发布 job
/// （只有 build-multiplatform.yml 里一个 `flutter build linux --debug` 编译冒烟），
/// vendor 一份没人装配的二进制只是 11MB 的死重。将来真加 Linux 发布时，
/// 在这里补一行，desktop_ffmpeg_bundling_guard_test 会同时要求装配步。
const List<_VendoredTarget> _targets = <_VendoredTarget>[
  _VendoredTarget(
    label: 'windows',
    dir: 'windows',
    ffmpegName: 'ffmpeg.exe',
    ffprobeName: 'ffprobe.exe',
    tlsFlag: '--enable-schannel',
  ),
  _VendoredTarget(
    label: 'macos',
    dir: 'macos',
    ffmpegName: 'ffmpeg',
    ffprobeName: 'ffprobe',
    tlsFlag: '--enable-securetransport',
  ),
];

/// 从当前 cwd 向上找含 tool/ffmpeg-min/build-ffmpeg-min.sh 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/tool/ffmpeg-min/build-ffmpeg-min.sh').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 tool/ffmpeg-min/build-ffmpeg-min.sh 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

/// 解析 `NAME="a,b,c"` 形式的 shell 赋值，返回去空的组件集合。
Set<String> _parseRecipeList(String script, String varName) {
  final RegExp pattern = RegExp('^$varName="([^"]*)"\$', multiLine: true);
  final RegExpMatch? match = pattern.firstMatch(script);
  if (match == null) {
    fail(
      'build-ffmpeg-min.sh 里找不到 $varName="..." 赋值。'
      '若变量已改名，请同步更新本守卫的 _componentVarToFlag。',
    );
  }
  return _splitComponents(match.group(1)!);
}

Set<String> _splitComponents(String raw) => raw
    .split(',')
    .map((String e) => e.trim())
    .where((String e) => e.isNotEmpty)
    .toSet();

/// 从 ffmpeg 二进制里抠出内嵌的 configure 命令行。
///
/// ffmpeg 把 configure 原样存成静态字符串（`ffmpeg -version` 的 `configuration:`
/// 行），因此可以静态提取而不必执行 exe——这正是让本守卫能在 Linux CI 上跑的关键。
String _embeddedConfiguration(File exe) {
  final List<int> bytes = exe.readAsBytesSync();
  // latin1 是字节到码点的恒等映射，任何字节序列都能安全解码成可正则搜索的字符串。
  final String text = latin1.decode(bytes, allowInvalid: true);
  final int anchor = text.indexOf('--disable-everything');
  if (anchor < 0) {
    fail(
      '在 ${exe.path} 里找不到内嵌的 configure 字符串。'
      '这个 exe 不像是 build-ffmpeg-min.sh 编出来的精简 ffmpeg。',
    );
  }
  return text;
}

/// 从 configure 串里取 `--enable-<flag>='a,b,c'` 的组件集合。
Set<String> _parseBinaryList(String configuration, String flag) {
  final RegExp pattern = RegExp("--enable-$flag='([^']*)'");
  final RegExpMatch? match = pattern.firstMatch(configuration);
  if (match == null) {
    fail(
      '入库二进制的 configure 串里没有 --enable-$flag=\'...\'。'
      '说明它不是由当前 build-ffmpeg-min.sh 编出来的。',
    );
  }
  return _splitComponents(match.group(1)!);
}

String _revendorHint() => '''

修法（唯一正确路径，见 .github/workflows/ffmpeg-min.yml 头部）：
  1. gh workflow run ffmpeg-min.yml --ref develop -f ffmpeg_ref=n7.1.5
  2. 等 workflow 绿（它会跑 tool/ffmpeg-min/smoke-test.sh 验行为契约，
     含 BUG-1420 的两条 ffprobe 真实调用形态断言）
  3. 下载 ffmpeg-min-windows-x64 / ffmpeg-min-macos artifact，把其中的
     ffmpeg(.exe) 与 ffprobe(.exe) 一起替换到
     third_party/ffmpeg-min/<平台>/ 后提交（macOS 侧记得
     `git update-index --chmod=+x`，否则 bundle 里的是不可执行文件）
禁止只改配方不换二进制——用户跑的是二进制，不是脚本。''';

void main() {
  final Directory root = _repoRoot();
  final File recipe = File('${root.path}/tool/ffmpeg-min/build-ffmpeg-min.sh');

  test('配方脚本在', () {
    expect(recipe.existsSync(), isTrue, reason: '缺 ${recipe.path}');
  });

  for (final _VendoredTarget target in _targets) {
    final String base = '${root.path}/third_party/ffmpeg-min/${target.dir}';
    final File exe = File('$base/${target.ffmpegName}');
    final File probe = File('$base/${target.ffprobeName}');

    group('ffmpeg-min 入库二进制与构建配方一致性守卫（${target.label}，BUG-1058/1420/1421）',
        () {
      test('ffmpeg 与 ffprobe 两个 exe 都在且是真二进制', () {
        // BUG-1420：ffprobe 有独立消费方（内封字幕字体 / 音频容器元数据），
        // 缺它不会让 ffmpeg 相关功能报错，只会让那两条链静默退化，所以必须单查。
        for (final File f in <File>[exe, probe]) {
          expect(f.existsSync(), isTrue, reason: '缺 ${f.path}${_revendorHint()}');
          // 入库的是真 exe（~5-13MB），不是 LFS 指针或占位符。
          expect(
            f.lengthSync(),
            greaterThan(1 << 20),
            reason: '${f.path} 太小，疑似 LFS 指针或占位文件',
          );
        }
      });

      test('8 组组件清单逐项一致（缺项 = 忘了重新 vendor）', () {
        final String script = recipe.readAsStringSync();
        final String configuration = _embeddedConfiguration(exe);

        final List<String> problems = <String>[];
        _componentVarToFlag.forEach((String varName, String flag) {
          final Set<String> wanted = _parseRecipeList(script, varName);
          final Set<String> got = _parseBinaryList(configuration, flag);
          final Set<String> missing = wanted.difference(got);
          final Set<String> extra = got.difference(wanted);
          if (missing.isNotEmpty) {
            problems.add(
              '--enable-$flag 缺少配方要求的组件: ${(missing.toList()..sort()).join(", ")}',
            );
          }
          if (extra.isNotEmpty) {
            problems.add(
              '--enable-$flag 多出配方之外的组件: ${(extra.toList()..sort()).join(", ")}',
            );
          }
        });

        expect(
          problems,
          isEmpty,
          reason: '入库 ${target.ffmpegName}（${target.label}）与 '
              'build-ffmpeg-min.sh 不一致：\n'
              '${problems.join("\n")}\n${_revendorHint()}',
        );
      });

      test('关键独立开关 + 本平台 TLS 后端都编进去了', () {
        final String configuration = _embeddedConfiguration(exe);
        for (final String flag in <String>[
          ..._requiredStandaloneFlags,
          target.tlsFlag,
        ]) {
          expect(
            configuration.contains(flag),
            isTrue,
            reason: '入库 ${target.ffmpegName}（${target.label}）的 configure 串缺 '
                '$flag${_revendorHint()}',
          );
        }
      });

      test('ffprobe 与 ffmpeg 由同一次 configure 编出', () {
        // 两个 exe 出自同一棵源码树、同一条 configure，因此内嵌配方串必须一致。
        // 不一致 = 只换了其中一个（半拉子 vendor），比两个都旧更危险：
        // 能力矩阵对不上，排查时会指向错误的方向。
        final Set<String> exeEncoders =
            _parseBinaryList(_embeddedConfiguration(exe), 'encoder');
        final Set<String> probeEncoders =
            _parseBinaryList(_embeddedConfiguration(probe), 'encoder');
        expect(
          probeEncoders,
          equals(exeEncoders),
          reason: '${target.label} 的 ffmpeg 与 ffprobe 内嵌配方不一致，'
              '说明只重新 vendor 了其中一个。${_revendorHint()}',
        );
      });

      test('mp4 软字幕能力（movtext 编码器）真的在二进制里', () {
        // 单拎出来断言，因为这就是 BUG-1058 的具体表现，且失败信息要能直接读懂：
        // configure 的组件名是 movtext，ffmpeg -encoders 列出来的名字是 mov_text，
        // 而片段导出传的是 `-c:s mov_text`。缺它 → 'Unknown encoder' → 静默降级成
        // 无字幕片段（video_clip_exporter.dart 的降级重试）。
        final Set<String> encoders =
            _parseBinaryList(_embeddedConfiguration(exe), 'encoder');
        expect(
          encoders,
          contains('movtext'),
          reason: '入库 ${target.ffmpegName}（${target.label}）没有 movtext 编码器，'
              '桌面端片段导出永远封不进字幕。${_revendorHint()}',
        );
      });
    });
  }
}
