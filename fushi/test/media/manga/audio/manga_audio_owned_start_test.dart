// HBK-AUDIT-215：漫画阅读器起成品音频时会话归属绑在页面去留上。起播要等播放器加载，
// 读者在这期间退出阅读器：退出路径只处理已接管的会话，迟到的加载以前会装进全局会话，
// 留下没人接管的暂停迷你条，还可能顶掉别的书。[startMangaAudioSessionOwned] 钉住：
// 页面已不要了就不起（不顶掉别的书）；起到一半页面走了就停掉这次装上的那份。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_start_request.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_session.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart'
    show MediaPlayIntent;
import 'package:fushi_audio/fushi_audio.dart';

import '../../../helpers/fake_just_audio.dart';

class _Companion implements AudiobookSessionCompanion {
  bool disposed = false;

  @override
  bool skipLine(int delta) => false;

  @override
  void dispose() => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FloatingLyricChannel.platformOverride = false);
  tearDown(() => FloatingLyricChannel.platformOverride = null);

  AudiobookSession makeSession() {
    final AudiobookSession session = AudiobookSession(
      audioHandler: () => null,
      showFloatingLyric: () => false,
      showMediaNotification: () => false,
      floatingLyricVisibleLines: () => 1,
      floatingLyricStyle: () => const FloatingLyricStyle(
        fontSize: 16,
        textColor: 0,
        bgColor: 0,
        buttonTextColor: 0,
        buttonBgColor: 0,
        highlightColor: 0,
        activeColor: 0,
      ),
      floatingLyricClickLookup: () => false,
      onFloatingLyricLookup: (_, __, ___) {},
      controlStreams: AudioControlStreams(
        playIntentStream: const Stream<MediaPlayIntent>.empty(),
        seekStream: const Stream<Duration>.empty(),
        skipNextStream: const Stream<void>.empty(),
        skipPreviousStream: const Stream<void>.empty(),
        toggleFloatingLyricStream: const Stream<void>.empty(),
      ),
      database: () => null,
      studyIdleTimeout: () => const Duration(minutes: 10),
    );
    addTearDown(session.dispose);
    return session;
  }

  File audioFile(String name) {
    final File f = File('${Directory.systemTemp.path}/$name');
    if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f;
  }

  AudiobookSessionStartRequest request(
    String key, {
    AudiobookSessionCompanionFactory? companion,
  }) => AudiobookSessionStartRequest(
    info: SessionBookInfo(
      bookKey: key,
      audiobook: Audiobook()
        ..bookKey = key
        ..audioPaths = const <String>[]
        ..alignmentFormat = 'srt'
        ..alignmentPath = '',
      title: 'Book $key',
      mediaIdentifier: 'fushi://book/$key',
    ),
    audioFiles: <File>[audioFile('fushi-owned-start-$key.mp3')],
    prefs: const SessionPrefs(
      followAudio: true,
      delayMs: 0,
      speed: 1.0,
      positionMs: 0,
      imagePauseSec: 0,
      volume: 1.0,
    ),
    persist: SessionPersistCallbacks(
      onPositionWrite: (_, __) async {},
      onDelayPersist: (_) async {},
      onSpeedPersist: (_) async {},
      onVolumePersist: (_) async {},
      onImagePausePersist: (_) async {},
      onFollowAudioPersist: (_) async {},
    ),
    companion: companion,
  );

  test('页面仍在：装上会话并返回这次建的伴随对象', () async {
    installFakeJustAudio();
    final AudiobookSession session = makeSession();
    final _Companion companion = _Companion();
    final AudiobookSessionCompanion? created =
        await startMangaAudioSessionOwned(
          session,
          request(
            'manga',
            companion: (AudiobookPlayerController _) => companion,
          ),
          wanted: () => true,
        );
    expect(created, same(companion));
    expect(session.book?.bookKey, 'manga');
    expect(session.companion, same(companion));
  });

  test('起播前页面已退出：不起会话，正在播的别的书不被顶掉', () async {
    installFakeJustAudio();
    final AudiobookSession session = makeSession();
    await session.start(
      info: request('other').info,
      audioFiles: request('other').audioFiles,
      prefs: request('other').prefs,
      persist: request('other').persist,
    );
    bool built = false;
    final AudiobookSessionCompanion? created =
        await startMangaAudioSessionOwned(
          session,
          request(
            'manga',
            companion: (AudiobookPlayerController _) {
              built = true;
              return _Companion();
            },
          ),
          wanted: () => false,
        );
    expect(created, isNull);
    expect(built, isFalse);
    expect(session.book?.bookKey, 'other');
  });

  test('播放器加载期间页面退出：停掉这次装上的会话，不留没人接管的迷你条', () async {
    installFakeJustAudio();
    final AudiobookSession session = makeSession();
    bool pageAlive = true;
    final _Companion companion = _Companion();
    final AudiobookSessionCompanion? created =
        await startMangaAudioSessionOwned(
          session,
          request(
            'manga',
            companion: (AudiobookPlayerController _) {
              // 伴随对象在播放器加载完之后才建：此时读者已经退出了阅读器。
              pageAlive = false;
              return companion;
            },
          ),
          wanted: () => pageAlive,
        );
    expect(created, isNull);
    expect(session.isActive, isFalse);
    expect(session.book, isNull);
    expect(session.companion, isNull);
    expect(companion.disposed, isTrue);
  });
}
