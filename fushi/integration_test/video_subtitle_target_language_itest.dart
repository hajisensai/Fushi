// BUG-5465 真 app 复测：打开视频时自动挑字幕按本视频的目标语言（含繁 / 简中文），
// 不再写死日语。真 app、真 media_kit、真 ffmpeg 抽取内封文本字幕、真 sidecar 探测。
//
// 素材（ffmpeg 现场生成，每个视频一个独立目录，互不串 sidecar）：
//   内封：一条 30 秒 mkv 带 3 条内封 subrip 轨，顺序
//         [0] jpn「Japanese」 [1] chi「简体中文」 [2] chi「繁體中文」，
//         复制成 3 个视频，行语言分别 `zh-Hant` / `zh-Hans` / `ja`；
//         期望各挑 [2] / [1] / [0]——不是「第一条文本轨」，也不是「第一条中文轨」。
//   外挂：无内封字幕的 mkv，同名 `<主名>.ja.srt` / `.zh-CN.srt` / `.zh-TW.srt`，
//         行语言 `zh-Hant` → zh-TW，`zh-Hans` → zh-CN。
//   嗅探：无标记 `<主名>.srt`（正文繁体）+ `<主名>.zh.srt`（只标中文、正文简体）+
//         `<主名>.zh-CN.srt`，行语言 `zh-Hant` → 无标记那份。不读正文时 `.zh.srt`
//         （标了中文、看不出繁简）排在无标记前面，所以只有嗅出繁体才会挑中无标记那份。
// 每份字幕每句都带来源编号（`#EHANT-3` 之类），cue 一看就知道是哪一份。
//
// 行都不带自己持久化的 `subtitleSource`（否则它优先），字幕工作台默认语言
// （`jimaku_default_language`）保持空，目标语言只来自行上的 `language`。
// 每个视频与视频卡 onTap 同一入口（`openLocalVideoBook`）打开，等 overlay 出 cue，
// 焦点落进画面后按 Escape 退出，再开下一个。
//
// 两个坑（同 video_embedded_text_subtitle_switch_itest）：app 的 `main` 会替换
// [FlutterError.onError]，先存原 handler、流程跑完先还原再断言；`flutter test -d windows`
// 的 stdout 只在进程退出时刷出，关键观测同时追加写进
// `<FUSHI_TEST_ROOT>/sub-target-lang-report.txt`（flush: true）。
//
// 跑法（在 fushi/ 下）：
//   dart tool/heavy.dart --max-minutes=30 -- powershell -ExecutionPolicy Bypass
//     -File tool/run_windows_itest.ps1 integration_test/video_subtitle_target_language_itest.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/media/video/video_subtitle_overlay.dart'
    show VideoSubtitleOverlay;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[sub-target-lang]';
const int _kCueCount = 6;

/// 一份字幕：来源编号（写进每句 cue）+ 正文。
class _SubSpec {
  const _SubSpec(this.id, this.phrase);

  final String id;
  final String phrase;

  String textAt(int i) => '$phrase #$id-${i + 1}';
}

// 内封三条轨。
const _SubSpec _embJa = _SubSpec('EJA', 'これは日本語の字幕です');
const _SubSpec _embHans = _SubSpec('EHANS', '这是简体中文字幕，我们说话读书写字');
const _SubSpec _embHant = _SubSpec('EHANT', '這是繁體中文字幕，我們說話讀書寫字');

// 同名 sidecar。
const _SubSpec _sideJa = _SubSpec('SJA', 'こちらは外部の日本語字幕です');
const _SubSpec _sideHans = _SubSpec('SHANS', '这是外挂简体字幕，我们说话读书写字');
const _SubSpec _sideHant = _SubSpec('SHANT', '這是外掛繁體字幕，我們說話讀書寫字');

// 正文嗅探：无标记（繁体正文）/ 只标中文（简体正文）/ 标简体。
const _SubSpec _sniffUntagged = _SubSpec('XHANT', '這份沒有標記，我們說話讀書寫字');
const _SubSpec _sniffZh = _SubSpec('XZH', '这份只标中文，我们说话读书写字');
const _SubSpec _sniffHans = _SubSpec('XHANS', '这份标了简体，我们说话读书写字');

const List<_SubSpec> _kAllSpecs = <_SubSpec>[
  _embJa,
  _embHans,
  _embHant,
  _sideJa,
  _sideHans,
  _sideHant,
  _sniffUntagged,
  _sniffZh,
  _sniffHans,
];

final String _kTestRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

final String _sep = Platform.pathSeparator;

Future<void> _note(String line) async {
  debugPrint('$_tag $line');
  if (_kTestRoot.isEmpty) return;
  await File(
    '$_kTestRoot${_sep}sub-target-lang-report.txt',
  ).writeAsString('$line\n', mode: FileMode.append, flush: true);
}

String _srtTime(int ms) {
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(ms ~/ 3600000)}:${p(ms ~/ 60000 % 60)}:${p(ms ~/ 1000 % 60)},'
      '${p(ms % 1000, 3)}';
}

String _srtFor(_SubSpec spec) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < _kCueCount; i++) {
    final int start = 1000 + i * 2500;
    b
      ..writeln(i + 1)
      ..writeln('${_srtTime(start)} --> ${_srtTime(start + 2000)}')
      ..writeln(spec.textAt(i))
      ..writeln();
  }
  return b.toString();
}

Future<void> _writeSrt(String path, _SubSpec spec) =>
    File(path).writeAsString(_srtFor(spec), flush: true);

/// ffmpeg 生成一条 30 秒 mkv；[tracks] 非空时带这些内封 subrip 轨（语言 + 标题）。
Future<void> _makeMkv(
  String outPath,
  List<({String srtPath, String language, String title})> tracks,
) async {
  final List<String> args = <String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=640x360:rate=24',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=mono',
    for (final t in tracks) ...<String>['-i', t.srtPath],
    '-map',
    '0:v',
    '-map',
    '1:a',
    for (int i = 0; i < tracks.length; i++) ...<String>['-map', '${i + 2}:0'],
    '-t',
    '30',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    '-c:a',
    'aac',
    if (tracks.isNotEmpty) ...<String>['-c:s', 'srt'],
    for (int i = 0; i < tracks.length; i++) ...<String>[
      '-metadata:s:s:$i',
      'language=${tracks[i].language}',
      '-metadata:s:s:$i',
      'title=${tracks[i].title}',
    ],
    outPath,
  ];
  final FfmpegRunResult r = await resolveFfmpegBackend().run(
    args,
    const Duration(seconds: 180),
  );
  if (!r.isSuccess) {
    throw StateError('ffmpeg 生成 $outPath 失败: ${r.failureSummary}');
  }
}

/// 视频主名：`singleVideoBookUid` 只取文件主名，每个视频必须各不相同（否则共用一行）。
String _stemOf(String dirName) => 'Clip $dirName';

/// 把 [source] 复制进 `<root>/<dirName>/<主名>.mkv` 并以行语言 [language] 入库，返回 bookUid。
Future<({String uid, String dir, String videoPath})> _seedVideo(
  VideoBookRepository repo,
  Directory root,
  String source,
  String dirName,
  String language,
) async {
  final Directory dir = Directory('${root.path}$_sep$dirName');
  await dir.create(recursive: true);
  final String videoPath = File(
    '${dir.path}$_sep${_stemOf(dirName)}.mkv',
  ).absolute.path;
  await File(source).copy(videoPath);
  final String uid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(uid),
      title: Value(_stemOf(dirName)),
      videoPath: Value(videoPath),
      language: Value(language),
    ),
  );
  return (uid: uid, dir: dir.path, videoPath: videoPath);
}

/// cue 列表来自哪一份字幕（句数与逐句文本全等），如 `EHANT`；都对不上返回 null。
String? _matchSource(List<AudioCue> cues) {
  for (final _SubSpec spec in _kAllSpecs) {
    if (cues.length != _kCueCount) continue;
    bool all = true;
    for (int i = 0; i < cues.length; i++) {
      if (cues[i].text.trim() != spec.textAt(i)) {
        all = false;
        break;
      }
    }
    if (all) return spec.id;
  }
  return null;
}

String _describeCues(List<AudioCue> cues) => cues.isEmpty
    ? 'cues=0'
    : 'cues=${cues.length} first="${cues.first.text}" last="${cues.last.text}"';

Element? _pageElement() {
  final Iterable<Element> pages = find
      .byType(VideoFushiPage, skipOffstage: false)
      .evaluate();
  return pages.isEmpty ? null : pages.last;
}

String? _currentPageUid() =>
    (_pageElement()?.widget as VideoFushiPage?)?.bookUid;

/// 当前播放页字幕 overlay 上的 cue。
List<AudioCue> _pageCues() {
  final Element? page = _pageElement();
  if (page == null) return const <AudioCue>[];
  final Finder overlay = find.descendant(
    of: find.byElementPredicate((Element e) => identical(e, page)),
    matching: find.byType(VideoSubtitleOverlay),
  );
  if (overlay.evaluate().isEmpty) return const <AudioCue>[];
  return List<AudioCue>.of(
    (overlay.evaluate().first.widget as VideoSubtitleOverlay).controller.cues,
  );
}

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required Duration timeout,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (done()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return done();
}

/// 焦点落进画面后按 Escape 退出播放页（逐级关前台浮层，最多 4 次）。
Future<bool> _exitPage(WidgetTester tester) async {
  final FocusDriver driver = FocusDriver(tester);
  await driver.requestFocusInside(find.byType(Video));
  bool gone = false;
  for (int i = 0; i < 4 && !gone; i++) {
    await tester.sendKeyEvent(
      LogicalKeyboardKey.escape,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    gone = await _pumpUntil(
      tester,
      () => find.byType(VideoFushiPage).evaluate().isEmpty,
      timeout: const Duration(seconds: 5),
    );
  }
  return gone;
}

/// 打开 [uid]（与视频卡 onTap 同一入口），等自动加载出 cue，记下是哪一份，再退出。
Future<String?> _openAndIdentify(
  WidgetTester tester,
  VideoBookRepository repo,
  String label,
  String uid,
) async {
  final BuildContext ctx = tester.element(find.byType(Scaffold).first);
  unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
  final bool loaded = await _pumpUntil(
    tester,
    () => _currentPageUid() == uid && _pageCues().isNotEmpty,
    timeout: const Duration(seconds: 90),
  );
  // cue 出来后再稳一下，确认没有被别的源顶替。
  await tester.pump(const Duration(seconds: 2));
  final List<AudioCue> cues = _pageCues();
  final String? source = _matchSource(cues);
  final String? row = (await repo.getByBookUid(uid))?.subtitleSource;
  await _note(
    '$label loaded=$loaded source=${source ?? '-'} rowSubtitle=$row '
    '${_describeCues(cues)}',
  );
  if (!loaded) throw StateError('$label 90s 内没有自动加载出 cue');
  final bool exited = await _exitPage(tester);
  await _note('$label exited=$exited');
  if (!exited) throw StateError('$label 退出播放页失败');
  await tester.pump(const Duration(milliseconds: 500));
  return source;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('打开视频自动挑字幕按目标语言：内封轨与同名外挂都区分繁 / 简', (WidgetTester tester) async {
    final void Function(FlutterErrorDetails)? originalOnError =
        FlutterError.onError;

    String? flowError;
    final Map<String, String?> picked = <String, String?>{};

    try {
      if (_kTestRoot.isNotEmpty) {
        final File report = File(
          '$_kTestRoot${_sep}sub-target-lang-report.txt',
        );
        if (report.existsSync()) report.deleteSync();
      }
      await launchFushiTestApp();
      final bool homeShown = await waitForHome(tester);
      await _note('home=$homeShown');
      if (!homeShown) throw StateError('主页 90s 内未出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      if (appModel.jimakuDefaultLanguage.trim().isNotEmpty) {
        await appModel.setJimakuDefaultLanguage('');
      }
      await _note(
        'prefs jimakuDefaultLanguage="${appModel.jimakuDefaultLanguage}" '
        'defaultContentLanguage="${appModel.defaultContentLanguage}" '
        'videoSubtitlePreferredLanguages='
        '"${appModel.videoSubtitlePreferredLanguages}"',
      );
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final Directory root = _kTestRoot.isEmpty
          ? await Directory.systemTemp.createTemp('fushi_subtarget_')
          : Directory('$_kTestRoot${_sep}fixtures');
      await root.create(recursive: true);
      final Directory src = Directory('${root.path}${_sep}src');
      await src.create(recursive: true);

      // 素材：带 3 条内封轨的 mkv、无内封字幕的 mkv。
      final String jaSrt = '${src.path}${_sep}emb_ja.srt';
      final String hansSrt = '${src.path}${_sep}emb_hans.srt';
      final String hantSrt = '${src.path}${_sep}emb_hant.srt';
      await _writeSrt(jaSrt, _embJa);
      await _writeSrt(hansSrt, _embHans);
      await _writeSrt(hantSrt, _embHant);
      final String embeddedMkv = '${src.path}${_sep}embedded.mkv';
      await _makeMkv(
        embeddedMkv,
        <({String srtPath, String language, String title})>[
          (srtPath: jaSrt, language: 'jpn', title: 'Japanese'),
          (srtPath: hansSrt, language: 'chi', title: '简体中文'),
          (srtPath: hantSrt, language: 'chi', title: '繁體中文'),
        ],
      );
      final String plainMkv = '${src.path}${_sep}plain.mkv';
      await _makeMkv(
        plainMkv,
        const <({String srtPath, String language, String title})>[],
      );

      // 1. 内封。
      final embHant = await _seedVideo(
        repo,
        root,
        embeddedMkv,
        'emb-hant',
        'zh-Hant',
      );
      final embHans = await _seedVideo(
        repo,
        root,
        embeddedMkv,
        'emb-hans',
        'zh-Hans',
      );
      final embJa = await _seedVideo(repo, root, embeddedMkv, 'emb-ja', 'ja');

      // 2. 同名 sidecar。
      final sideHant = await _seedVideo(
        repo,
        root,
        plainMkv,
        'side-hant',
        'zh-Hant',
      );
      final sideHans = await _seedVideo(
        repo,
        root,
        plainMkv,
        'side-hans',
        'zh-Hans',
      );
      for (final ({String uid, String dir, String videoPath}) v
          in <({String uid, String dir, String videoPath})>[
            sideHant,
            sideHans,
          ]) {
        final String base = v.videoPath.substring(0, v.videoPath.length - 4);
        await _writeSrt('$base.ja.srt', _sideJa);
        await _writeSrt('$base.zh-CN.srt', _sideHans);
        await _writeSrt('$base.zh-TW.srt', _sideHant);
      }

      // 3. 无标记 sidecar 按正文嗅繁简。
      final sniff = await _seedVideo(
        repo,
        root,
        plainMkv,
        'sniff-hant',
        'zh-Hant',
      );
      final String sniffBase = sniff.videoPath.substring(
        0,
        sniff.videoPath.length - 4,
      );
      await _writeSrt('$sniffBase.srt', _sniffUntagged);
      await _writeSrt('$sniffBase.zh.srt', _sniffZh);
      await _writeSrt('$sniffBase.zh-CN.srt', _sniffHans);

      final List<({String uid, String dir, String videoPath})> seeded =
          <({String uid, String dir, String videoPath})>[
            embHant,
            embHans,
            embJa,
            sideHant,
            sideHans,
            sniff,
          ];
      if (seeded.map((v) => v.uid).toSet().length != seeded.length) {
        throw StateError('种子视频的 bookUid 撞了：${seeded.map((v) => v.uid)}');
      }
      for (final ({String uid, String dir, String videoPath}) v in seeded) {
        final row = await repo.getByBookUid(v.uid);
        await _note(
          'seeded ${v.videoPath} uid=${v.uid} language=${row?.language} '
          'subtitleSource=${row?.subtitleSource}',
        );
        if (row?.language == null || row!.subtitleSource != null) {
          throw StateError('${v.uid} 种子行应带 language、不应带 subtitleSource');
        }
      }

      picked['emb zh-Hant'] = await _openAndIdentify(
        tester,
        repo,
        'emb zh-Hant',
        embHant.uid,
      );
      picked['emb zh-Hans'] = await _openAndIdentify(
        tester,
        repo,
        'emb zh-Hans',
        embHans.uid,
      );
      picked['emb ja'] = await _openAndIdentify(
        tester,
        repo,
        'emb ja',
        embJa.uid,
      );
      picked['side zh-Hant'] = await _openAndIdentify(
        tester,
        repo,
        'side zh-Hant',
        sideHant.uid,
      );
      picked['side zh-Hans'] = await _openAndIdentify(
        tester,
        repo,
        'side zh-Hans',
        sideHans.uid,
      );
      picked['sniff zh-Hant'] = await _openAndIdentify(
        tester,
        repo,
        'sniff zh-Hant',
        sniff.uid,
      );
      await tester.pump(const Duration(seconds: 1));
    } catch (e, s) {
      flowError = '$e\n$s';
      await _note('flow error: $e');
    } finally {
      FlutterError.onError = originalOnError;
    }

    expect(flowError, isNull, reason: flowError);
    expect(
      picked['emb zh-Hant'],
      'EHANT',
      reason: '行语言 zh-Hant：应挑内封「繁體中文」轨（不是第一条文本轨 / 第一条中文轨）',
    );
    expect(picked['emb zh-Hans'], 'EHANS', reason: '行语言 zh-Hans：应挑内封「简体中文」轨');
    expect(picked['emb ja'], 'EJA', reason: '行语言 ja：应挑内封日语轨');
    expect(
      picked['side zh-Hant'],
      'SHANT',
      reason: '行语言 zh-Hant：应挑 .zh-TW.srt',
    );
    expect(
      picked['side zh-Hans'],
      'SHANS',
      reason: '行语言 zh-Hans：应挑 .zh-CN.srt',
    );
    expect(
      picked['sniff zh-Hant'],
      'XHANT',
      reason:
          '行语言 zh-Hant：无标记 .srt 正文是繁体，应排在只标中文的 .zh.srt '
          '与标简体的 .zh-CN.srt 前面（XZH = 没读正文）',
    );
  });
}
