import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// TODO-1246 guard：单视频重开时「尊重字幕自带样式」开关（respectAssStyle）失效的根因是
/// DB 缓存的 [AudioCue] 不携带解析期样式 [AudioCue.markup]（瞬态，DB 往返丢弃）。修复在
/// [_loadSingle]：持久化字幕源是磁盘上的外挂文本档案时重解析档案拿回 markup，而非直接用
/// loadCues 的无样式 cue。
///
/// 本文件锁两件事：
/// 1. 行为层：证明「DB 往返丢 markup」这一缺陷，以及「重解析档案恢复 markup」这一修复机制。
///    （用真 parser + 真 repo + drift 内存库 + 临时档案，端到端。）
/// 2. 源码守卫：[_loadSingle] 确实在重解析外挂文本档案（media_kit 无法 headless，故守卫
///    调用点不变式，与 video_subtitle_persist_guard_test.dart 同法）。
const String _assWithStyles = '''
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Text_JP,FOT-Matisse ProN B,65,&H00FF00FF,&H001A3D77,&H0028549C,0,0,0,0,100,100,0,0,1,2.5,0,2,30,30,30,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.40,0:00:05.75,Text_JP,,0,0,0,,{\blur5}恋の歌だと声が伸びる
''';

void main() {
  test(
      'DB round-trip drops markup; re-parsing the external .ass file restores it '
      '(TODO-1246 respect-ass-style rehydration mechanism)', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('todo1246_ass_');
    addTearDown(() => tmp.delete(recursive: true));
    final File assFile = File('${tmp.path}/sub.ass');
    await assFile.writeAsString(_assWithStyles);

    // 外挂文本档案被识别为可重解析的文本字幕格式。
    expect(subtitleFormatForPath(assFile.path), SubtitleFormat.ass);

    // 1) 首解析：cue 带上 V4+ Styles 的 cueStyle（字体/主色/描边）。
    final String content = await assFile.readAsString();
    final List<AudioCue> parsed = await parseSubtitleContentAsync(
      SubtitleFormat.ass,
      content: content,
      bookUid: 'video/rehy',
    );
    expect(parsed, hasLength(1));
    final SubtitleCueStyle? firstStyle = parsed.single.markup?.cueStyle;
    expect(firstStyle, isNotNull,
        reason: 'AssParser must populate cueStyle from [V4+ Styles]');
    expect(firstStyle!.fontName, 'FOT-Matisse ProN B');
    expect(
        firstStyle.primaryColorArgb, 0xFFFF00FF); // BGR &H00FF00FF -> magenta
    expect(firstStyle.outlineColorArgb, 0xFF773D1A); // BGR &H001A3D77

    // 2) DB 往返：saveCues -> loadCues 丢掉 markup（缺陷所在，故不可只信 DB 缓存）。
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/rehy'),
      title: const Value('Rehy'),
      videoPath: const Value('/v.mkv'),
      subtitleSource: Value(assFile.path),
    ));
    await repo.saveSubtitleSelection(
      bookUid: 'video/rehy',
      subtitleSource: assFile.path,
      cues: parsed,
    );
    final List<AudioCue> fromDb = await repo.loadCues('video/rehy');
    expect(fromDb, hasLength(1));
    expect(fromDb.single.text, isNotEmpty, reason: 'text content survives DB');
    expect(fromDb.single.markup, isNull,
        reason: 'markup is transient and lost on DB round-trip — this is why '
            'reopening a single video used to break respectAssStyle');

    // 3) 修复机制：重解析磁盘档案恢复带 markup 的 cue。
    final List<AudioCue> rehydrated = await parseSubtitleContentAsync(
      SubtitleFormat.ass,
      content: await assFile.readAsString(),
      bookUid: 'video/rehy',
    );
    expect(rehydrated.single.markup?.cueStyle?.fontName, 'FOT-Matisse ProN B',
        reason: 're-parsing the external file recovers cueStyle so the '
            'respect-ass-style toggle has data to honor');
  });

  test(
      '_loadSingle re-parses external text subtitle files to recover markup '
      '(TODO-1246 call-site guard)', () {
    final String src = readVideoHibikiSource();

    // 助手存在且严格门控：仅磁盘上存在的外挂文本格式档案才可重解析（内嵌轨/哨兵/缺档不重解析）。
    final int helperAt =
        src.indexOf('String? _rehydratableExternalSubtitlePath(');
    expect(helperAt, greaterThanOrEqualTo(0),
        reason: 'missing _rehydratableExternalSubtitlePath helper');
    final int helperEnd = src.indexOf('\n  }', helperAt);
    final String helper = src.substring(helperAt, helperEnd);
    expect(helper.contains('subtitleFormatForPath(source) == null'), isTrue,
        reason: 'must reject embedded:<n> / non-text sources');
    expect(helper.contains('File(source).existsSync()'), isTrue,
        reason: 'must reject vanished files (nothing to re-parse)');

    // _loadSingle 用助手驱动重解析分支，走 _loadExternalSubtitleCues（文本档案廉价重解析，
    // 不触发内嵌轨 ffmpeg 重抽取）。
    final int start = src.indexOf('Future<void> _loadSingle(');
    expect(start, greaterThanOrEqualTo(0));
    final int end =
        src.indexOf('_relocateSingleMediaPaths(VideoBookRow row)', start);
    final String body = src.substring(start, end);
    expect(
        body.contains('_rehydratableExternalSubtitlePath(externalSub)'), isTrue,
        reason:
            '_loadSingle must decide rehydration from the persisted source');
    expect(body.contains('_loadExternalSubtitleCues(rehydratePath'), isTrue,
        reason:
            'rehydration must re-parse the external file to restore markup');
  });

  test(
      'SubtitleSource.isEmbeddedPersisted only matches embedded:<n> sentinels '
      '(TODO-1246 embedded rehydration discriminator)', () {
    expect(SubtitleSource.isEmbeddedPersisted('embedded:0'), isTrue);
    expect(SubtitleSource.isEmbeddedPersisted('embedded:3'), isTrue);
    // 外挂绝对路径 / 关闭哨兵 / 空 / null 都不是内嵌轨。
    expect(SubtitleSource.isEmbeddedPersisted('/movies/S01E01.ass'), isFalse);
    expect(SubtitleSource.isEmbeddedPersisted('C:/movies/S01E01.ass'), isFalse);
    expect(SubtitleSource.isEmbeddedPersisted(SubtitleSource.offSentinel),
        isFalse);
    expect(SubtitleSource.isEmbeddedPersisted(''), isFalse);
    expect(SubtitleSource.isEmbeddedPersisted(null), isFalse);
    // 与实际持久化值往返一致：内嵌源 toPersistedValue → isEmbeddedPersisted 真。
    const SubtitleSource embedded = SubtitleSource.embedded(
      streamIndex: 2,
      label: 'JP',
      codec: 'ass',
    );
    expect(SubtitleSource.isEmbeddedPersisted(embedded.toPersistedValue()),
        isTrue);
  });

  test(
      '_loadSingle re-parses embedded text tracks (cache hit, no ffmpeg) to '
      'recover markup on reopen (TODO-1246 embedded call-site guard)', () {
    // 根因守卫：单视频重开时 DB 缓存的内嵌轨 cue 无 markup（瞬态，DB 往返丢弃）→
    // respectAssStyle 拿不到 cueStyle → 「尊重字幕自带样式」对内嵌轨完全不生效。修复须让
    // _loadSingle 在持久化源是 embedded:<n> 且 DB 有文本 cue 时经 _restorePersistedSubtitle
    // 重解析已抽取的缓存档案恢复 markup（与播放列表换集同路径，命中缓存不触发 ffmpeg 重抽取）。
    final String src = readVideoHibikiSource();
    final int start = src.indexOf('Future<void> _loadSingle(');
    expect(start, greaterThanOrEqualTo(0));
    final int end =
        src.indexOf('_relocateSingleMediaPaths(VideoBookRow row)', start);
    final String body = src.substring(start, end);

    // 门控判据：仅内嵌轨 + DB 有文本 cue（cues 非空）+ 非外挂档案分支时才重解析，避免
    // 抢图形轨（cues 为空 → 落 cues.isEmpty 分支经 libmpv 渲染，BUG-122 不倒退）。
    expect(body.contains('SubtitleSource.isEmbeddedPersisted(externalSub)'),
        isTrue,
        reason: 'embedded rehydration must gate on embedded:<n> persisted');
    expect(body.contains('cues.isNotEmpty'), isTrue,
        reason:
            'only re-parse when DB has text cues (graphic tracks keep libmpv path)');
    // 走 _restorePersistedSubtitle（内嵌轨重解析路径），不新起 ffmpeg 抽取分支。
    expect(
        body.contains('rehydrateEmbedded') &&
            body.contains('_restorePersistedSubtitle('),
        isTrue,
        reason:
            'embedded rehydration must reuse _restorePersistedSubtitle (cache reparse)');
  });
}
