// 媒体服务器（Jellyfin）曲目「生成日语字幕」对真服务器、真模型的端到端取证：
//
//   1. 模型：把本机缓存的 Parakeet 日语识别文件（int8 + vocab + VAD）放进隔离数据根里
//      歌曲素材那个包的目录，缺的人声分离模型走 app 正常的下载入口
//      （`AppVideoSubtitleAsrModelPort.download(audioProfile: song)`，即生成面板点「下载」
//      那一条）补齐，之后 `plan(song).modelReady` 为真；
//   2. 转写：服务器上专辑「日本語スピーチ」（ナレーター）的「スピーチ 全部」（36 s，四段 9 s
//      日语对白）经与 UI 入口同一条管线跑完：服务器流 → 暂存 16 kHz WAV
//      （`musicServerAsrAudioInput` → `musicAsrAudioFileOf`）→
//      `MusicSubtitleTargets.forRemoteTracks` → `appVideoSubtitleService(...).start`；
//   3. 产物：从落点（该曲 uid 的 `music_lyrics` `asr` 行）读回 SRT，断言有日语文字、且与
//      参考台词（[_kReferenceLines]）有宽松的字符重合。
//
// 凭据与模型缓存经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER / FUSHI_JELLYFIN_PASS
//   FUSHI_ASR_MODEL_CACHE：放着 `model.int8.onnx` / `vocab.txt` / `silero_vad.onnx` 的目录
//   （缺省则全部走下载）。
// 缺凭据直接失败（只在人工点名时跑）。证据是 observe-*.png 与 [srv-asr] 日志行。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show openAsrModelStore;
import 'package:fushi/src/media/music/asr/music_plugin_asr_audio.dart';
import 'package:fushi/src/media/music/asr/music_server_asr_audio.dart';
import 'package:fushi/src/media/music/asr/music_subtitle_target.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrAudioProfile,
        AsrLanguage,
        AsrModelFile,
        AsrModelRole,
        AsrModelStore,
        ModelDownloadEvent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_JELLYFIN_URL');
const String _username = String.fromEnvironment('FUSHI_JELLYFIN_USER');
const String _password = String.fromEnvironment('FUSHI_JELLYFIN_PASS');
const String _modelCache = String.fromEnvironment('FUSHI_ASR_MODEL_CACHE');

const String _kAlbum = '日本語スピーチ';
const String _kArtist = 'ナレーター';
const String _kTrack = 'スピーチ 全部';

/// 「スピーチ 全部」四段对白（各 9 s，取自参考片的 120 / 178 / 489 / 512 s 起）对应的
/// 参考字幕行（9 s 窗口内出现的全部行）。只做宽松比对：识别稿与人工字幕的断句、
/// 用字（汉字 / 假名）都会不同。
const List<String> _kReferenceLines = <String>[
  // 120 s
  '星子が小僧の住所を言った時 ピンときたぜ',
  'そこは温泉地帯だってことがよお',
  'そこでワシはコッソリ',
  // 178 s
  'この器の能力が 勝手に出ただけだぜ',
  'そういや そうだね',
  'それよりさ ジジの家 見た？',
  'ターボババア的にどうよ？',
  'ウチは何も見えなくってさ',
  // 489 s
  '鬼頭家の人間が警察に捕まったら',
  'つるちゃんのせいだよ？',
  'よお 仁 どこ行ってたんだよ？',
  'いやあ ちょっと友達と…',
  // 512 s
  '彼は オレの親友で 遊びに来たいって…',
  'ふーん…',
  '仁の好きなサッカーのチームは？',
  'え？',
  '親友なら分かるでしょ？',
];

/// 平假名 / 片假名 / 汉字。
final RegExp _kJapaneseChar = RegExp(r'[ぁ-ゖァ-ヺ一-鿿]');

Set<String> _japaneseChars(String text) => <String>{
  for (final Match m in _kJapaneseChar.allMatches(text)) m.group(0)!,
};

/// 相邻两个日语字符组成的二元组（跨标点 / 空格不连）。
Set<String> _japaneseBigrams(String text) {
  final Set<String> out = <String>{};
  final List<String> chars = text.split('');
  for (int i = 0; i + 1 < chars.length; i++) {
    if (_kJapaneseChar.hasMatch(chars[i]) &&
        _kJapaneseChar.hasMatch(chars[i + 1])) {
      out.add('${chars[i]}${chars[i + 1]}');
    }
  }
  return out;
}

/// SRT 的正文行（去掉序号与时间轴行）。
List<String> _srtTextLines(String srt) => <String>[
  for (final String line in const LineSplitter().convert(srt))
    if (line.trim().isNotEmpty &&
        !RegExp(r'^\d+$').hasMatch(line.trim()) &&
        !line.contains('-->'))
      line.trim(),
];

/// 把本机缓存的识别文件放进隔离数据根里该包的目录（只放清单里有、长度对得上的）。
Future<List<String>> _provisionFromCache(AsrModelStore store) async {
  final List<String> copied = <String>[];
  if (_modelCache.isEmpty) return copied;
  await store.dir.create(recursive: true);
  for (final AsrModelFile f in store.pack.files) {
    if (f.role == AsrModelRole.vocalSeparator) continue;
    final File src = File(p.join(_modelCache, f.fileName));
    if (!await src.exists() || await src.length() != f.expectedBytes) continue;
    final File dst = store.fileFor(f.role);
    if (await dst.exists() && await dst.length() == f.expectedBytes) continue;
    await src.copy(dst.path);
    copied.add(f.fileName);
  }
  return copied;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Jellyfin 曲目：生成日语字幕端到端出文字（真模型、真服务器）', (
    WidgetTester tester,
  ) async {
    expect(
      _serverUrl.isNotEmpty && _username.isNotEmpty,
      isTrue,
      reason: '需要 --dart-define FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER',
    );
    await runFushiItest(
      label: 'music-server-asr',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);
        final FushiDatabase db = appModel.database;

        // ── 0. 登录并落配置（产品同一条 authenticateByName + upsert 路径）──
        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinAuthResult auth = await JellyfinApi(
          serverUrl: url,
        ).authenticateByName(_username, _password);
        await SyncRepository(db).upsertJellyfinServer(
          JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: auth.userId,
            accessToken: auth.accessToken,
            serverName: auth.serverName,
          ),
        );
        final Map<String, MusicServerBinding> bindings =
            await musicServerBindingLoader!();
        final JellyfinMusicClient browser = bindings.values
            .map((MusicServerBinding b) => b.browser)
            .whereType<JellyfinMusicClient>()
            .single;

        // ── 1. 模型：缓存的识别文件 + app 下载入口补分离模型 ──
        final AsrModelStore store = await openAsrModelStore(
          AsrLanguage.japanese,
          AsrAudioProfile.song,
        );
        final List<String> copied = await _provisionFromCache(store);
        debugPrint(
          '[srv-asr] model dir=${store.dir.path} pack=${store.pack.id} '
          'copied=$copied',
        );
        const AppVideoSubtitleAsrModelPort port =
            AppVideoSubtitleAsrModelPort();
        final Set<String> downloaded = <String>{};
        Object? downloadError;
        bool downloadDone = false;
        port
            .download(audioProfile: AsrAudioProfile.song)
            .listen(
              (ModelDownloadEvent e) => downloaded.add(e.fileName),
              onError: (Object e) {
                downloadError = e;
                downloadDone = true;
              },
              onDone: () => downloadDone = true,
            );
        final DateTime downloadDeadline = DateTime.now().add(
          const Duration(minutes: 20),
        );
        while (!downloadDone && DateTime.now().isBefore(downloadDeadline)) {
          await tester.pump(const Duration(seconds: 1));
        }
        debugPrint(
          '[srv-asr] download done=$downloadDone files=$downloaded '
          'error=$downloadError',
        );
        expect(downloadError, isNull);
        expect(downloadDone, isTrue, reason: '分离模型应在 20 分钟内下完');
        if (_modelCache.isNotEmpty) {
          // 下载器对已在盘的文件也报一条事件，所以按「没碰 fp32 识别权重」判：
          // 盘上是 int8，有独显推荐 fp32 也只该补分离模型（BUG-5292）。
          final Set<String> fp32 = <String>{
            for (final AsrModelFile f in store.pack.files)
              if (f.role == AsrModelRole.ctcModelFp32 ||
                  f.role == AsrModelRole.ctcWeightsFp32)
                f.fileName,
          };
          expect(
            downloaded.intersection(fp32),
            isEmpty,
            reason: '识别文件已在盘：歌曲素材只补人声分离模型（BUG-5292）',
          );
          for (final String name in fp32) {
            expect(
              File(p.join(store.dir.path, name)).existsSync(),
              isFalse,
              reason: '不应落下 fp32 识别权重 $name',
            );
          }
        }
        expect(
          store.fileFor(AsrModelRole.vocalSeparator).lengthSync(),
          store.pack.fileForRole(AsrModelRole.vocalSeparator).expectedBytes,
          reason: '人声分离模型经 app 下载入口落盘',
        );
        expect(
          await port.isReady(audioProfile: AsrAudioProfile.song),
          isTrue,
          reason: 'plan(song).modelReady',
        );

        // ── 2. 找曲目 ──
        final List<MusicServerAlbum> albums =
            (await browser.listAlbums()).items;
        final MusicServerAlbum album = albums.firstWhere(
          (MusicServerAlbum a) => a.title == _kAlbum,
        );
        final List<MusicServerTrack> tracks = await browser.albumTracks(
          album.id,
        );
        final MusicServerTrack track = tracks.firstWhere(
          (MusicServerTrack t) => t.title == _kTrack,
        );
        debugPrint(
          '[srv-asr] album="${album.title}" artist="${album.artist}" '
          'track="${track.title}" durationMs=${track.durationMs}',
        );
        expect(album.artist, _kArtist);

        // ── 3. 取音频 + 管线（与 UI 入口同一条）──
        final MusicPlayItem item = musicServerPlayItem(
          browser,
          track,
          albumTitle: album.title,
        );
        final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
          root: musicPluginAsrAudioRootUnder(
            await AppPaths.supportRootDirectory(),
          ),
        );
        final ({File audio, bool staged}) got = await musicAsrAudioFileOf(
          await musicServerAsrAudioInput(
            item.serverTrack!,
            servers: musicServerBindingLoader!,
          ),
          item: item,
          stager: stager,
          onProgress: (_) {},
          cancel: Completer<void>().future,
        );
        final int wavBytes = await got.audio.length();
        debugPrint(
          '[srv-asr] staged ${got.audio.path} ($wavBytes bytes, '
          '~${(wavBytes - 44) / 32000} s of 16 kHz mono)',
        );
        expect(wavBytes, greaterThan(30 * 32000), reason: '36 s 的曲目至少 30 s');

        final AppVideoSubtitleTarget target =
            await MusicSubtitleTargets(
              database: db,
              lyrics: appModel.musicLyrics,
            ).forRemoteTracks(
              tracks: <MusicRemoteAsrTrack>[
                (item: item, audio: got.audio, staged: got.staged),
              ],
              title: item.title,
              key: 'music:track:${item.trackUid}',
            );
        expect(target.unavailable, isEmpty);
        expect(target.episodes, hasLength(1));
        final AppVideoSubtitleJob job = appVideoSubtitleService(
          appModel,
        ).start(target, const AppVideoSubtitleOptions());
        bool finished = false;
        unawaited(job.done.then((_) => finished = true));
        final DateTime deadline = DateTime.now().add(
          const Duration(minutes: 15),
        );
        while (!finished && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(seconds: 1));
        }
        debugPrint(
          '[srv-asr] asr job: status=${job.status} '
          'recognizer=${job.recognizerId} '
          'registered=${job.registeredBookUids} error=${job.errorMessage}',
        );
        await captureFlutterFrame(tester, 'server-asr-job-done', settle: false);
        expect(finished, isTrue, reason: '管线应在 15 分钟内跑完');
        expect(job.errorMessage, isNull);
        expect(job.registeredBookUids, <String>[item.trackUid]);

        // ── 4. 读回产物（该曲 uid 的 asr 歌词行）并与参考台词比对 ──
        final MusicLyricRow? row =
            await (db.select(db.musicLyrics)..where(
                  ($MusicLyricsTable t) =>
                      t.trackUid.equals(item.trackUid) &
                      t.source.equals(MusicLyricsSource.asr),
                ))
                .getSingleOrNull();
        expect(row, isNotNull, reason: '生成字幕应登记成该曲的 asr 歌词行');
        final String srt = utf8.decode(row!.raw, allowMalformed: true);
        final List<String> lines = _srtTextLines(srt);
        for (final String line in lines) {
          debugPrint('[srv-asr] cue: $line');
        }
        final String produced = lines.join(' ');
        final String reference = _kReferenceLines.join(' ');
        final Set<String> sharedChars = _japaneseChars(
          produced,
        ).intersection(_japaneseChars(reference));
        final Set<String> sharedBigrams = _japaneseBigrams(
          produced,
        ).intersection(_japaneseBigrams(reference));
        debugPrint(
          '[srv-asr] format=${row.format} cues=${lines.length} '
          'chars=${_japaneseChars(produced).length} '
          'sharedChars=${sharedChars.length} ${sharedChars.join()} '
          'sharedBigrams=${sharedBigrams.length} ${sharedBigrams.join(',')}',
        );
        expect(
          _japaneseChars(produced).length,
          greaterThanOrEqualTo(20),
          reason: '应识别出日语文字',
        );
        expect(
          sharedChars.length,
          greaterThanOrEqualTo(20),
          reason: '与参考台词共享足够多的不同假名 / 汉字',
        );
        expect(
          sharedBigrams.length,
          greaterThanOrEqualTo(8),
          reason: '与参考台词共享足够多的相邻字符组合（不只是零散常见假名）',
        );
      },
    );
  });
}
