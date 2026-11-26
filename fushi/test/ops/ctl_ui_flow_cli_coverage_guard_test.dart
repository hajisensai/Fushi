import 'dart:io';

import 'package:test/test.dart';

/// 「界面里的导入 / 导出 / 选文件再做」流程必须进操作目录（CLI / AI / MCP 同一份），
/// 或写明为什么不进（拍板台 PGpPujl99g：CLI 要能做 app 里能点的操作）。
///
/// 扫描对象：`lib/`（`lib/src/ops/` 以外）里公开的 `Future<…> pickAnd*/import*/export*(`
/// 声明——这类函数几乎都是一个用户能点的「把东西搬进 / 搬出 app」的动作。它的名字
/// 在 `lib/src/ops/` 里出现过（路由直接调它）就算接上了；否则必须在 [_notRouted]
/// 登记一条，值以下列前缀之一开头：
/// - `covered:` 路由用别的入口做了同一件事（写明 CLI 命令）；
/// - `ui-only:` 只能由界面完成（写明为什么）；
/// - `internal:` 不是用户动作（同步 / 迁移 / 平台管线内部调用）；
/// - `pending <bug slug>:` 还没接，已登记待补（`docs/bugs/BUG-*-<slug>.md` 必须存在；
///   用 slug 不用号：撞号时 settle 会改号，slug 不变）。
///
/// 同名声明在不止一个文件里出现（`importFile`、`exportPackage`、接口与实现成对……）
/// 时，名字本身分不出是哪一个：`ops/` 里出现了这个名字，只能说明其中某一个接上了。
/// 这类名字按文件判：某个 `ops/` 文件既提到这个名字、又 import 了声明它的文件，才算
/// 那个文件里的接上了；其余的必须按 `'<lib/… 路径>#<名字>'` 逐个登记，裸名字登记不算
/// （否则一条 `internal:` 会把以后别处新写的同名用户流程一起放过）。
///
/// 新写这样一个流程却没接路由也没登记，这里就红：要么同时接 ctl 路由 + CLI 命令 +
/// 操作描述，要么在这里写明理由。接上之后把条目删掉（留着也会红）。
const Map<String, String> _notRouted = <String, String>{
  // ── 已由别的路由覆盖 ──────────────────────────────────────────────────
  'exportProfileToJson':
      'covered: fushi_cli profile export（/api/admin/profiles/:id/export）',
  'importProfileFromJson':
      'covered: fushi_cli profile import（/api/admin/profiles/import）',
  'importAndSwitchProfile':
      'covered: fushi_cli profile import + profile activate',
  'pickAndOpenMangaAudioPackageImport':
      'covered: fushi_cli tts import-package（tts.manga.import-package，界面版只多一步选文件再开导入页）',
  'importFromDirectory':
      'covered: fushi_cli dict import（/api/admin/dictionaries/import）',
  'importFromFile':
      'covered: fushi_cli dict import（/api/admin/dictionaries/import）',
  'importRecommendedPackFile':
      'covered: fushi_cli dict pack-import（/api/admin/dictionary-pack/import）',
  'importLocalAudioDbFile':
      'covered: 设置动作的 CLI 入口（settings/audio_sources_cli.dart，fushi_cli config run）',
  'importShaderFile':
      'covered: 设置动作的 CLI 入口（media/video/video_settings_cli.dart）',
  'importLuaScriptFile':
      'covered: 设置列表项 video.player.mpv_lua_scripts_list 的 cliList（fushi_cli config items）',
  'importFolder':
      'covered: fushi_cli library import <路径…>（ctl_library_import.dart）',
  'importFromInbox': 'covered: fushi_cli library import <路径…>（收件箱只是界面上的一个默认目录）',
  'importInboxDirectory': 'covered: fushi_cli library import <路径…>',
  'importLocalFolderOnce': 'covered: fushi_cli library import <目录>',
  'importLocalFolderOnceAt':
      'covered: fushi_cli library import <目录> / library source add + scan',
  'importBatchPaths': 'covered: fushi_cli library import --kind manga <路径…>',
  'importMangaBatchFolder':
      'covered: fushi_cli library import --kind manga <目录>',
  'importMangaBatchPaths':
      'covered: fushi_cli library import --kind manga <路径…>',
  'importMangaFromPdf': 'covered: fushi_cli library import --kind manga <pdf>',
  'importMangaAudioManifest':
      'covered: fushi_cli tts import（tts.manga.import，共用 checkMangaAudioManifest）',
  'pickAndImportMangaAudio': 'covered: fushi_cli tts import（tts.manga.import）',
  'importRemoteBookFolder':
      'internal: 云同步拉书时由 sync_orchestrator 调用（fushi_cli sync run）',
  'importRemoteBooks':
      'internal: 云同步拉书时由 sync_orchestrator 调用（fushi_cli sync run）',
  'lib/src/reader/font_download_service.dart#importFile':
      'covered: 自定义字体导入的底层，CustomFontLibrary.importFile 经 fushi_cli config fonts 路由调用',
  'lib/src/pages/implementations/video_fushi/playback_remote.part.dart#importSubtitle':
      'covered: VideoPlayerRemoteControl.importSubtitle 的实现，fushi_cli video 字幕导入经接口调到这里',
  // ── 不是用户动作 ──────────────────────────────────────────────────────
  'lib/src/media/tracking/plugin/tracking_plugin_manager.dart#exportPackage':
      'internal: 追踪插件经互联共享时打包（interconnect_source_share_*）',
  'lib/src/sync/interconnect_source_share_kinds.dart#exportPackage':
      'internal: 互联共享源 / 插件时的打包端口',
  'lib/src/models/local_audio_manager.dart#importFile':
      'internal: 本地音频库导入的底层（用户入口 importLocalAudioDbFile 另行登记）',
  'exportPresetIconToFile': 'internal: 应用图标换肤的平台管线（main.dart / app_icon_apply）',
  'importLogin': 'internal: Bangumi 旧 token 迁移到插件追踪器',
  'importSyncedLocalAudioDb': 'internal: 同步拉下本地音频库后的落地',
  'importMediaServerProgress':
      'internal: 媒体服务器作品入库（MediaServerVideoLibrary.addToLibrary）里把服务器观看状态补进新入库行的一步（BUG-5455），不是单独的用户动作',
  'lib/src/media/music/music_audio_intake_port.dart#importAudioFiles':
      'internal: 音乐导入端口给视频侧的纯音频入口（用户入口 importMusicFiles 另行登记）',
  'lib/src/media/music/music_audio_intake.dart#importAudioFiles':
      'internal: 音乐导入端口的底层实现（用户入口 importMusicFiles 另行登记）',
  'importDiscoveryPdf':
      'internal: 发现页下载队列自动入库 / 书架一包书解包后的 PDF 导入端口（用户直接导 PDF 走 fushi_cli library import <pdf>）',
  'exportBatch': 'ui-only: 旧版只读后的一次性迁移向导（migration_page），不是日常操作',
  'importPastedTextBook':
      'ui-only: 输入是剪贴板粘贴的文本；CLI 等价做法是存成 .txt 后 fushi_cli library import',
  // ── 待补（docs/bugs/BUG-*-cli-ui-only-ops-gaps.md 盘点清单） ────────────────────────────────────────
  'lib/src/media/music/music_audio_intake_port.dart#importMusicFiles':
      'covered: 端口接口声明；实现 MusicAudioIntake.importMusicFiles 经 fushi_cli music import 调用',
  'importFiles': 'pending cli-ui-only-ops-gaps: 歌词可视化素材包导入图片',
  'importIptvChannels': 'pending cli-ui-only-ops-gaps: IPTV 播放列表导入频道',
  'pickAndApplyVideoFrameCover': 'pending cli-ui-only-ops-gaps: 视频取帧当封面',
  'exportTranscribedSrt': 'pending cli-ui-only-ops-gaps: 有声书转录结果导出 SRT',
  'exportWindowRecording':
      'internal: 制卡管线内部取录制帧拼片段（gal_hook_mining_coordinator），用户入口是 fushi_cli game mine',
  'exportTtsAudiobookM4b': 'pending cli-ui-only-ops-gaps: TTS 有声书导出 M4B',
  'exportClip':
      'pending cli-ui-only-ops-gaps: 漫画有声书播放条导出当前句片段视频（MangaReadAloud.exportClip）',
  'importSyncedBookFile': 'pending cli-ui-only-ops-gaps: 阅读历史云端列表里下载单本书',
};

final RegExp _flowDecl = RegExp(
  r'Future<[^;{=]*?>\s+((?:pickAnd|import|export)[A-Z]\w*)\s*\(',
);

final RegExp _reasonShape = RegExp(
  r'^(covered|ui-only|internal): \S|^pending ([a-z0-9-]+): \S',
);

/// `lib/` 下的源文件路径（正斜杠、相对 `fushi/`）。
String _posix(String path) => path.replaceAll(r'\', '/');

/// [file]（`lib/…` 路径）被别的文件 import 时写的 URI。
String _packageUri(String file) => 'package:fushi/${file.substring(4)}';

void main() {
  final Directory lib = Directory('lib');
  final Map<String, String> sources = <String, String>{
    for (final FileSystemEntity e in lib.listSync(recursive: true))
      if (e is File && e.path.endsWith('.dart') && !e.path.endsWith('.g.dart'))
        _posix(e.path): e.readAsStringSync(),
  };
  bool isOps(String path) => path.startsWith('lib/src/ops/');
  final Map<String, String> opsSources = <String, String>{
    for (final MapEntry<String, String> e in sources.entries)
      if (isOps(e.key)) e.key: e.value,
  };

  /// 流程名 → 声明它的文件（`ops/` 以外）。
  final Map<String, Set<String>> flows = <String, Set<String>>{};
  for (final MapEntry<String, String> e in sources.entries) {
    if (isOps(e.key)) continue;
    for (final RegExpMatch m in _flowDecl.allMatches(e.value)) {
      flows.putIfAbsent(m.group(1)!, () => <String>{}).add(e.key);
    }
  }
  bool ambiguous(String name) => flows[name]!.length > 1;

  /// [file] 里声明的 [name] 有没有接上路由：唯一声明时 `ops/` 提到名字即可；同名
  /// 声明不止一处时，提到名字的 `ops/` 文件还必须 import [file]。
  bool routed(String name, String file) {
    final RegExp mention = RegExp('\\b$name\\b');
    final String uri = _packageUri(file);
    return opsSources.values.any(
      (String text) =>
          mention.hasMatch(text) && (!ambiguous(name) || text.contains(uri)),
    );
  }

  /// [file] 里的 [name] 对应的登记键；没有登记为 null。
  String? registrationOf(String name, String file) {
    if (!ambiguous(name)) return _notRouted.containsKey(name) ? name : null;
    final String key = '$file#$name';
    return _notRouted.containsKey(key) ? key : null;
  }

  test('扫描器自检：已接路由的流程与登记的流程都扫得到', () {
    expect(flows, contains('importMangaAudioManifest'));
    expect(
      flows.values.fold<int>(0, (int n, Set<String> files) => n + files.length),
      greaterThan(_notRouted.length),
    );
    expect(
      flows.entries.where(
        (MapEntry<String, Set<String>> e) =>
            e.value.any((String f) => routed(e.key, f)),
      ),
      isNotEmpty,
    );
    // 同名多处声明的自检：字体库的 importFile 接了路由，本地音频库的同名函数没接，
    // 两者必须被分开判断（按名字判就会互相掩护）。
    expect(ambiguous('importFile'), isTrue);
    expect(
      routed('importFile', 'lib/src/reader/custom_font_library.dart'),
      isTrue,
    );
    expect(
      routed('importFile', 'lib/src/models/local_audio_manager.dart'),
      isFalse,
    );
  });

  test('导入 / 导出 / 选文件流程要么接了路由，要么登记了理由', () {
    final List<String> missing = <String>[
      for (final MapEntry<String, Set<String>> e in flows.entries)
        for (final String file in e.value)
          if (!routed(e.key, file) && registrationOf(e.key, file) == null)
            ambiguous(e.key)
                ? '$file#${e.key}（同名声明不止一处，按「路径#名字」登记）'
                : '${e.key}（$file）',
    ];
    expect(
      missing,
      isEmpty,
      reason:
          '新的界面流程没进操作目录：接 ctl 路由 + CLI 命令 + op 描述，'
          '或在 _notRouted 写明理由。\n${missing.join('\n')}',
    );
  });

  test('登记表没有过期条目（接上路由或删掉函数后要删登记）', () {
    for (final String key in _notRouted.keys) {
      final int hash = key.indexOf('#');
      final String name = hash < 0 ? key : key.substring(hash + 1);
      final String? file = hash < 0 ? null : key.substring(0, hash);
      expect(flows.containsKey(name), isTrue, reason: '$key 已不存在，删掉登记');
      final Set<String> declared = flows[name]!;
      if (file == null) {
        expect(
          declared,
          hasLength(1),
          reason:
              '$name 在 ${declared.join('、')} 都有声明，裸名字登记分不出是哪个：改按「路径#名字」逐个登记',
        );
        expect(
          routed(name, declared.single),
          isFalse,
          reason: '$name 已接路由，删掉登记',
        );
      } else {
        expect(declared, contains(file), reason: '$key：$file 里已没有 $name，删掉登记');
        expect(
          declared.length,
          greaterThan(1),
          reason: '$name 只剩 $file 一处声明，改用裸名字登记',
        );
        expect(routed(name, file), isFalse, reason: '$key 已接路由，删掉登记');
      }
    }
  });

  test('理由格式正确；pending 指向的 BUG 文件存在', () {
    final List<String> bugFiles = <String>[
      for (final FileSystemEntity e in Directory('../docs/bugs').listSync())
        e.uri.pathSegments.last,
    ];
    for (final MapEntry<String, String> e in _notRouted.entries) {
      final RegExpMatch? m = _reasonShape.firstMatch(e.value);
      expect(m, isNotNull, reason: '${e.key}：${e.value}');
      final String? bug = m!.group(2);
      if (bug != null) {
        expect(
          bugFiles.any(
            (String f) => RegExp('^BUG-\\d+-$bug\\.md\$').hasMatch(f),
          ),
          isTrue,
          reason: '${e.key} 指向的 $bug 没有 docs/bugs/BUG-*-$bug.md',
        );
      }
    }
  });
}
