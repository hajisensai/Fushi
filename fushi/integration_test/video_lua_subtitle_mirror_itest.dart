// Issue #2014 真机端到端：用户的 mpv「字幕结束自动暂停」Lua 脚本在 Fushi 里要真能停。
//
// 根因回顾：Fushi 字幕全由 Flutter overlay 画，libmpv `sid` 恒为 `no`，脚本观察的
// `sub-text` / `sub-end` 永远不变。修复在 [VideoPlayerController] 里把 Dart 侧 cue
// （烘进调轴）写成 SRT，`sub-add <path> select fushi-lua-subtitle-mirror` 挂成隐藏轨
// （`sub-visibility=no`）。单测只能锁纯函数与接线；本文件在真 app + 真 libmpv 上跑：
//
//   ① 外挂 SRT（同名 sidecar，走 Dart 侧解析成 cue 的那条路径）+
//      mpv_scripts 里放一个典型「字幕结束自动暂停」脚本 → 播放后在第一句结束处
//      （±250ms）自动暂停；脚本记录的 sub-text 等于 cue 文本；overlay 照常有 cue；
//      libmpv 不自绘（`sub-visibility=no`、`activeSubtitleTrackId=='no'`、
//      `subtitleTracks` 不含镜像轨）。
//   ② `setDelayMs(500)` 后从句首前播放 → 暂停点后移约 500ms（调轴烘进镜像 SRT）。
//   ③ 负向：mpv_scripts 清空（目录即开关）→ `track-list` 里没有 title=fushi-lua-subtitle-mirror 的轨。
//
// 暂停由**真 Lua 脚本**执行：随包 libmpv 必须编入 Lua（BUG-3325，Windows `-lua1`
// 起 `-Dlua=luajit`；此前 `-Dlua=disabled` 时 `load-script` 静默成功、脚本不跑）。
// 随包 libmpv 退回无 Lua 的构建会让本测试直接失败，而不是悄悄换成别的验证。
// 同时断言 mpv 内置脚本（console / select 等）没有被加载（media_kit overlay 关掉）。
//
// 输入全部走 controller 公开 API / 页面 test hook（无坐标点击）。mpv 属性经
// `controller.videoController.player.platform.getProperty` 读（公开 API，未改 lib/）。
//
// 运行：fushi/ 下
//   dart tool/heavy.dart -- pwsh -File tool/run_windows_itest.ps1 integration_test/video_lua_subtitle_mirror_itest.dart
// 只在隔离测试根下跑（FUSHI_TEST_ROOT 缺失直接失败，绝不碰用户真实数据根）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_pause_ocr_scope.dart';
import 'package:fushi/src/media/video/video_lua_script_manager.dart'
    show isLuaSubtitleMirrorTrack, kLuaSubtitleMirrorTrackTitle;
import 'package:fushi/src/media/video/video_player_controller.dart'
    show VideoPlayerController;
import 'package:fushi/src/media/video/video_subtitle_overlay.dart'
    show VideoSubtitleOverlay;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi/src/storage/app_paths.dart' show AppPaths;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookRepository;
import 'package:fushi_engine/media/video/video_library_import.dart'
    show singleVideoBookUid;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kTestRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
// 素材生成用的 ffmpeg：`FUSHI_FFMPEG` 显式指定，否则走 PATH（不写死某台机器的
// 绝对路径——旧值在别的机器上不存在，测试在造素材这一步就 ProcessException）。
final String _kFfmpeg = Platform.environment['FUSHI_FFMPEG'] ?? 'ffmpeg';

// 第一句 1.5s–3.5s；第二句远在后面，保证暂停判定只看第一句。
const int _kCue1StartMs = 1500;
const int _kCue1EndMs = 3500;
const String _kCue1Text = 'こんにちは世界';
const int _kDelayMs = 500;
const int _kToleranceMs = 250;

const String _kSrt =
    '1\n'
    '00:00:01,500 --> 00:00:03,500\n'
    '$_kCue1Text\n'
    '\n'
    '2\n'
    '00:00:07,000 --> 00:00:08,000\n'
    '二行目のテスト\n'
    '\n';

/// 典型「字幕结束自动暂停」脚本（无按键绑定）。记录写到 [logPath]。
///
/// `sub-end` 变成 nil（句子消失）时**保留**上一句的句尾：25 fps 素材一帧 40 ms，
/// 比 30 ms 的提前窗口宽；句尾正好落在帧边界时（调轴 +500 ms 后第一句尾 = 4.000 s），
/// 3.960 s 那帧还没进窗口，4.000 s 那帧句子已消失、`sub-end` 已是 nil——丢掉句尾
/// 就会整句漏停（2026-10-13 随包 libmpv 编入 Lua 后真跑出来的）。同理，暂停记录里的
/// 句子用最后一次非空的 `sub-text`，不在暂停那一刻现读（那帧句子可能已消失）。
String _autoPauseScript(String logPath) {
  final String path = logPath.replaceAll(r'\', '/');
  return '''
local out = "$path"
local sub_end = nil
local paused_for = nil
local sub_text = ""
local function log(s)
  local f = io.open(out, "a")
  if f then f:write(s .. "\\n"); f:close() end
  mp.msg.info(s)
end
log("LOADED")
mp.observe_property("sub-end", "number", function(_, v)
  if v then
    sub_end = v
    log(string.format("SUBEND %.3f", v))
  end
end)
mp.observe_property("sub-text", "string", function(_, v)
  if v and v ~= "" then
    sub_text = v
    log("SUBTEXT " .. v)
  end
end)
mp.add_periodic_timer(0.01, function()
  if not sub_end or paused_for == sub_end then return end
  local pos = mp.get_property_number("time-pos")
  if pos and pos >= sub_end - 0.03 then
    paused_for = sub_end
    mp.set_property_bool("pause", true)
    log(string.format("PAUSE pos=%.3f end=%.3f text=%s", pos, sub_end, sub_text))
  end
end)
''';
}

class _PauseRecord {
  _PauseRecord(this.posMs, this.endMs, this.text);
  final int posMs;
  final int endMs;
  final String text;
  @override
  String toString() => 'PAUSE(pos=$posMs end=$endMs text=$text)';
}

List<_PauseRecord> _readPauses(File log) {
  if (!log.existsSync()) return <_PauseRecord>[];
  final RegExp re = RegExp(r'^PAUSE pos=([\d.]+) end=([\d.]+) text=(.*)$');
  return <_PauseRecord>[
    for (final String line
        in utf8.decode(log.readAsBytesSync(), allowMalformed: true).split('\n'))
      if (re.firstMatch(line.trimRight()) case final RegExpMatch m)
        _PauseRecord(
          (double.parse(m.group(1)!) * 1000).round(),
          (double.parse(m.group(2)!) * 1000).round(),
          m.group(3)!,
        ),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('#2014：Lua 字幕结束自动暂停脚本经隐藏镜像轨在真 libmpv 上生效', (
    WidgetTester tester,
  ) async {
    expect(
      _kTestRoot,
      isNotEmpty,
      reason: '必须经 run_windows_itest.ps1 在隔离根下跑（FUSHI_TEST_ROOT）',
    );
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[lua-mirror] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);

      // ── 0) 素材：隔离根下造 10s 视频 + 同名 SRT + Lua 脚本 ────────────────
      final Directory fixtures = Directory(
        p.join(_kTestRoot, 'fixtures', 'lua_mirror'),
      );
      await fixtures.create(recursive: true);
      final String videoPath = p.join(fixtures.path, 'lua_mirror.mp4');
      if (!File(videoPath).existsSync()) {
        final ProcessResult gen = await Process.run(_kFfmpeg, <String>[
          '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25', //
          '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
          '-t', '10', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', //
          '-c:a', 'aac', videoPath,
        ]);
        expect(gen.exitCode, 0, reason: 'ffmpeg 生成失败: ${gen.stderr}');
      }
      await File(
        p.join(fixtures.path, 'lua_mirror.srt'),
      ).writeAsString(_kSrt, flush: true);

      final Directory scriptsDir = await AppPaths.mpvLuaScriptsDirectory();
      debugPrint('[lua-mirror] scriptsDir=${scriptsDir.path} root=$_kTestRoot');
      expect(
        p.isWithin(p.normalize(_kTestRoot), p.normalize(scriptsDir.path)),
        isTrue,
        reason: 'mpv_scripts 必须在隔离根下（${scriptsDir.path}），不得写用户数据根',
      );
      await scriptsDir.create(recursive: true);
      final File luaLog = File(p.join(fixtures.path, 'lua_log.txt'));
      if (luaLog.existsSync()) await luaLog.delete();
      final File luaScript = File(
        p.join(scriptsDir.path, 'sub_end_autopause.lua'),
      );
      await luaScript.writeAsString(_autoPauseScript(luaLog.path), flush: true);

      final String bookUid = singleVideoBookUid(videoPath);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(bookUid),
          title: const Value('Lua Mirror Test'),
          videoPath: Value(File(videoPath).absolute.path),
        ),
      );

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      VideoFushiTestHooks hooks() =>
          tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
              as VideoFushiTestHooks;

      Future<VideoPlayerController> openPage() async {
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VideoFushiPage(bookUid: bookUid, repo: repo),
            ),
          ),
        );
        for (int i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
              hooks().debugPositionMs != null &&
              find.byType(VideoSubtitleOverlay).evaluate().isNotEmpty) {
            final VideoPlayerController c = tester
                .widget<VideoSubtitleOverlay>(
                  find.byType(VideoSubtitleOverlay).first,
                )
                .controller;
            if (c.cues.isNotEmpty && c.videoController != null) return c;
          }
        }
        fail(
          '视频页 / controller / overlay / sidecar cue 未就绪 '
          '(cueCount=${find.byType(VideoFushiPage).evaluate().isEmpty ? '-' : hooks().debugCueCount})',
        );
      }

      Future<String> prop(VideoPlayerController c, String name) async {
        final dynamic native = c.videoController!.player.platform;
        try {
          final dynamic v = await native.getProperty(name);
          return v?.toString() ?? '';
        } catch (e) {
          return '<err $e>';
        }
      }

      Future<List<Map<String, String>>> subTracks(
        VideoPlayerController c,
      ) async {
        final int count = int.tryParse(await prop(c, 'track-list/count')) ?? 0;
        final List<Map<String, String>> out = <Map<String, String>>[];
        for (int i = 0; i < count; i++) {
          final String type = await prop(c, 'track-list/$i/type');
          if (type != 'sub') continue;
          out.add(<String, String>{
            'id': await prop(c, 'track-list/$i/id'),
            'title': await prop(c, 'track-list/$i/title'),
            'selected': await prop(c, 'track-list/$i/selected'),
            'external-filename': await prop(
              c,
              'track-list/$i/external-filename',
            ),
          });
        }
        return out;
      }

      Future<List<Map<String, String>>> mirrorTracks(
        VideoPlayerController c,
      ) async => (await subTracks(c))
          .where(
            (Map<String, String> t) =>
                t['title'] == kLuaSubtitleMirrorTrackTitle,
          )
          .toList();

      Future<List<Map<String, String>>> waitMirror(
        VideoPlayerController c, {
        String? notFile,
      }) async {
        for (int i = 0; i < 60; i++) {
          final List<Map<String, String>> m = await mirrorTracks(c);
          if (m.length == 1 && m.single['external-filename'] != notFile) {
            return m;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        return mirrorTracks(c);
      }

      List<_PauseRecord> pauses(File luaLog) => _readPauses(luaLog);

      /// 等 controller 从播放变暂停，返回暂停后稳定的位置。
      Future<int?> waitAutoPause(
        VideoPlayerController c, {
        required int timeoutMs,
        bool Function()? overlayProbe,
      }) async {
        final Stopwatch sw = Stopwatch()..start();
        bool sawPlaying = false;
        while (sw.elapsedMilliseconds < timeoutMs) {
          await tester.pump(const Duration(milliseconds: 10));
          overlayProbe?.call();
          if (c.isPlaying) sawPlaying = true;
          if (sawPlaying && !c.isPlaying) {
            await tester.pump(const Duration(milliseconds: 400));
            return c.positionMs;
          }
        }
        return null;
      }

      // ── 1) 装着脚本：打开页面，等镜像轨挂上 ──────────────────────────────────
      // 暂停 OCR（2026-10-13 起默认对所有视频识别暂停帧）与本测试无关：脚本一停，
      // 隔离根里首次识别就弹 Lens 上传同意框，压在视频页上吞掉后面的返回。
      await appModel.setVideoPauseOcrScope(VideoPauseOcrScope.off);
      final VideoPlayerController c = await openPage();
      await c.pause();
      await c.seekMs(0);
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint(
        '[lua-mirror] cues=${c.cues.length} first='
        '${c.cues.first.startMs}-${c.cues.first.endMs} "${c.cues.first.text}"',
      );
      expect(c.cues.first.startMs, _kCue1StartMs);
      expect(c.cues.first.endMs, _kCue1EndMs);
      expect(c.cues.first.text, _kCue1Text);

      final List<Map<String, String>> mirror1 = await waitMirror(c);
      debugPrint('[lua-mirror] sub tracks=${await subTracks(c)}');
      expect(mirror1, hasLength(1), reason: '装了脚本时应恰好挂一条镜像轨');
      final String mirrorId1 = mirror1.single['id']!;
      final String mirrorFile1 = mirror1.single['external-filename']!;
      expect(await prop(c, 'sid'), mirrorId1, reason: '镜像轨应被选中');
      expect(await prop(c, 'sub-visibility'), 'no', reason: 'libmpv 不得自绘镜像字幕');
      expect(c.activeSubtitleTrackId, 'no');
      expect(
        c.subtitleTracks.where(isLuaSubtitleMirrorTrack),
        isEmpty,
        reason: 'subtitleTracks 不应暴露镜像轨',
      );
      final String mpvConfiguration = await prop(c, 'mpv-configuration');
      debugPrint('[lua-mirror] mpv-configuration=$mpvConfiguration');
      expect(
        mpvConfiguration,
        isNot(contains('lua=disabled')),
        reason: '随包 libmpv 必须编入 Lua，否则用户脚本静默不跑（BUG-3325）',
      );
      expect(
        luaLog.existsSync() && luaLog.readAsStringSync().contains('LOADED'),
        isTrue,
        reason: 'Lua 脚本应已加载',
      );
      // mpv 自带的 Lua 脚本不该跟着跑（media_kit overlay 在 mpv_initialize 前关掉）。
      for (final String option in <String>[
        'load-stats-overlay',
        'load-console',
        'load-select',
        'load-commands',
      ]) {
        expect(await prop(c, option), 'no', reason: '$option 应在初始化前关掉');
      }
      expect(await prop(c, 'ytdl'), 'no', reason: '每次 open 前的基线属性');

      // ── ① 从 0 播放 → 第一句结束处自动暂停 ──────────────────────────────
      String? overlayText;
      bool overlayProbe() {
        final String? cur = c.currentCue?.text;
        if (cur != null && overlayText == null) overlayText = cur;
        return true;
      }

      await c.play();
      final int? pausedAt1 = await waitAutoPause(
        c,
        timeoutMs: 8000,
        overlayProbe: overlayProbe,
      );
      final List<_PauseRecord> pauses1 = pauses(luaLog);
      debugPrint(
        '[lua-mirror] ① controllerPausedAt=$pausedAt1 '
        'cueEnd=$_kCue1EndMs pauses=$pauses1 overlayText=$overlayText '
        'sub-visibility=${await prop(c, 'sub-visibility')}',
      );
      expect(pausedAt1, isNotNull, reason: '8s 内应被 Lua 脚本自动暂停');
      expect(pauses1, isNotEmpty, reason: 'Lua 脚本应记录到 PAUSE');
      expect(
        pauses1.first.endMs,
        closeTo(_kCue1EndMs, 5),
        reason: '脚本读到的 sub-end 应等于 cue 结束',
      );
      expect(pauses1.first.posMs, closeTo(_kCue1EndMs, _kToleranceMs));
      expect(
        pausedAt1!,
        closeTo(_kCue1EndMs, _kToleranceMs),
        reason: 'controller 停在句尾附近',
      );
      expect(pauses1.first.text, _kCue1Text, reason: '脚本 sub-text = cue 文本');
      expect(overlayText, _kCue1Text, reason: 'overlay 照常显示第一句');
      expect(await prop(c, 'sub-visibility'), 'no');
      expect(c.activeSubtitleTrackId, 'no');

      // ── ② 调轴 +500ms → 镜像重挂 → 暂停点后移 ───────────────────────────
      c.setDelayMs(_kDelayMs);
      final List<Map<String, String>> mirror2 = await waitMirror(
        c,
        notFile: mirrorFile1,
      );
      debugPrint(
        '[lua-mirror] ② after delay sub tracks=${await subTracks(c)} '
        'sub-delay=${await prop(c, 'sub-delay')}',
      );
      expect(mirror2, hasLength(1), reason: '调轴后仍只有一条镜像轨');
      expect(
        mirror2.single['external-filename'],
        isNot(mirrorFile1),
        reason: '调轴应换新 SRT 重挂镜像（mpv 会复用 track id，按文件判）',
      );
      expect(await prop(c, 'sid'), mirror2.single['id']);
      expect(await prop(c, 'sub-visibility'), 'no');
      await c.seekMs(_kCue1StartMs - 700);
      await tester.pump(const Duration(milliseconds: 600));
      overlayText = null;
      await c.play();
      final int? pausedAt2 = await waitAutoPause(
        c,
        timeoutMs: 8000,
        overlayProbe: overlayProbe,
      );
      final List<_PauseRecord> pauses2 = pauses(luaLog);
      const int expected2 = _kCue1EndMs + _kDelayMs;
      debugPrint(
        '[lua-mirror] ② controllerPausedAt=$pausedAt2 '
        'expected=$expected2 pauses=$pauses2 overlayText=$overlayText',
      );
      expect(pausedAt2, isNotNull, reason: '调轴后应再次自动暂停');
      expect(pauses2.length, greaterThanOrEqualTo(2));
      expect(
        pauses2[1].endMs,
        closeTo(expected2, 5),
        reason: '镜像 SRT 烘进调轴：sub-end 后移 500ms',
      );
      expect(pauses2[1].posMs, closeTo(expected2, _kToleranceMs));
      expect(pausedAt2!, closeTo(expected2, _kToleranceMs));
      expect(pauses2[1].text, _kCue1Text);
      expect(overlayText, _kCue1Text);
      expect(
        await prop(c, 'sub-delay'),
        anyOf('0.000000', '0', '0.0'),
        reason: '调轴已烘进 SRT，mpv sub-delay 必须为 0',
      );
      c.setDelayMs(0);

      // ── ③ 负向：脚本目录清空 → 不挂镜像 ─────────────────────────────────────────
      navigator.pop();
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
      }
      // 装着真 Lua 脚本的播放器也必须能正常退出页面（mpv 关闭时要等脚本线程）。
      expect(
        find.byType(VideoFushiPage),
        findsNothing,
        reason: '退出视频页不应被 Lua 脚本拖住',
      );
      await tester.pump(const Duration(seconds: 1));
      await luaScript.delete();
      final VideoPlayerController c2 = await openPage();
      expect(identical(c2, c), isFalse, reason: '重开页面应是新的 controller');
      await tester.pump(const Duration(seconds: 2)); // 给可能的错挂留时间
      final List<Map<String, String>> tracksOff = await subTracks(c2);
      debugPrint(
        '[lua-mirror] ③ no scripts sub tracks=$tracksOff '
        'sid=${await prop(c2, 'sid')}',
      );
      expect(
        tracksOff.where(
          (Map<String, String> t) => t['title'] == kLuaSubtitleMirrorTrackTitle,
        ),
        isEmpty,
        reason: '没装脚本时不得挂镜像轨',
      );
      expect(await prop(c2, 'sid'), 'no');
      expect(c2.cues, isNotEmpty, reason: 'overlay cue 照常加载');
      await c2.pause();
      navigator.pop();
      await tester.pump(const Duration(seconds: 1));

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
