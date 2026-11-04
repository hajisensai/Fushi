import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi/src/media/audiobook/srt_book_missing_audio.dart';
import 'package:fushi/src/sync/settings_sync.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// 反馈 IHgBrvHizT：断链书卡的「不再提示」与「转成纯字幕书」都可撤销、都保留原路径。
class _MemoryPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

void main() {
  late FushiDatabase db;
  late SrtBookRepository repo;
  late _MemoryPrefs prefs;
  late Set<String> existing;
  late SrtBookMissingAudio missing;

  const List<String> brokenPaths = <String>['/gone/a.mp3', '/gone/b.mp3'];

  SrtBook book({required String uid, String bookKey = 'BK'}) => SrtBook()
    ..uid = uid
    ..title = 'T'
    ..srtPath = '/x/t.srt'
    ..importedAt = 1
    ..bookKey = bookKey
    ..audioPaths = List<String>.of(brokenPaths);

  Future<SrtBook> reload(String uid) async =>
      (await repo.listAll()).singleWhere((SrtBook b) => b.uid == uid);

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SrtBookRepository(db);
    prefs = _MemoryPrefs();
    existing = <String>{};
    missing = SrtBookMissingAudio(
      prefs: prefs,
      repository: repo,
      exists: existing.contains,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('dismiss hides the warning but keeps the audio paths; undismiss '
      'brings it back', () async {
    final SrtBook b = book(uid: 'srtbook_1');
    await repo.save(b);
    expect(missing.showsWarning(b), isTrue);

    await missing.dismiss(b);
    final SrtBook stored = await reload('srtbook_1');
    expect(stored.audioPaths, brokenPaths, reason: '不再提示不得动音频路径');
    expect(missing.hasMissingAudio(stored), isTrue);
    expect(missing.isDismissed(stored), isTrue);
    expect(missing.showsWarning(stored), isFalse);

    await missing.undismiss(stored);
    expect(missing.showsWarning(stored), isTrue);
  });

  test('a dismissal is bound to the exact path list: relocating to other '
      'paths that are also missing warns again', () async {
    final SrtBook b = book(uid: 'srtbook_2');
    await missing.dismiss(b);
    expect(missing.showsWarning(b), isFalse);
    b.audioPaths = <String>['/elsewhere/c.mp3'];
    expect(missing.showsWarning(b), isTrue);
  });

  test(
    'convert clears the row audio, stashes the paths, and the book no '
    'longer resolves an audiobook session; restore writes them back',
    () async {
      final SrtBook b = book(uid: 'srtbook_3', bookKey: 'K3');
      await repo.save(b);
      expect(missing.canConvertToSubtitleOnly(b), isTrue);

      expect(await missing.convertToSubtitleOnly(b), isTrue);
      final SrtBook converted = await reload('srtbook_3');
      expect(converted.audioPaths, isNull);
      expect(missing.hasMissingAudio(converted), isFalse);
      expect(missing.showsWarning(converted), isFalse);
      expect(missing.detachedAudioPaths(converted), brokenPaths);
      expect(
        await AudiobookSessionLauncher(db).resolve('K3'),
        isNull,
        reason: '转成纯字幕书后打开不应再起有声书会话',
      );

      expect(await missing.restoreAudio(converted), isTrue);
      final SrtBook restored = await reload('srtbook_3');
      expect(restored.audioPaths, brokenPaths);
      expect(missing.detachedAudioPaths(restored), isNull);
      expect(missing.showsWarning(restored), isTrue);
    },
  );

  test('restore is not offered once the row has audio again', () async {
    final SrtBook b = book(uid: 'srtbook_4');
    await repo.save(b);
    await missing.convertToSubtitleOnly(b);
    final SrtBook converted = await reload('srtbook_4');
    converted.audioPaths = <String>['/new/a.mp3'];
    expect(missing.detachedAudioPaths(converted), isNull);
  });

  test('EPUB audiobook pairing rows can only be dismissed, not converted', () {
    final SrtBook paired = book(uid: 'srtbook_epub_BK');
    expect(missing.hasMissingAudio(paired), isTrue);
    expect(missing.canConvertToSubtitleOnly(paired), isFalse);
  });

  test('healthy audio offers nothing', () async {
    existing.addAll(brokenPaths);
    final SrtBook b = book(uid: 'srtbook_5');
    expect(missing.showsWarning(b), isFalse);
    expect(missing.canConvertToSubtitleOnly(b), isFalse);
    expect(await missing.convertToSubtitleOnly(b), isFalse);
  });

  test('both pref keys stay on this device (never synced as settings)', () {
    expect(
      PortableSettingsPolicy.isPortable(
        SrtBookMissingAudio.dismissedPrefKey('srtbook_1'),
      ),
      isFalse,
    );
    expect(
      PortableSettingsPolicy.isPortable(
        SrtBookMissingAudio.detachedPathsPrefKey('srtbook_1'),
      ),
      isFalse,
    );
  });
}
