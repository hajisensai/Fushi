import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';

/// 歌词页里不依赖 AppModel 的判据：查词暂停、查词起点、播放项 → 歌词曲目、插值时钟。
void main() {
  test('查词暂停：设置开着且在播才暂停', () {
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: true, playing: true),
      isTrue,
    );
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: false, playing: true),
      isFalse,
    );
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: true, playing: false),
      isFalse,
    );
  });

  test('查词起点：从命中字符到行尾，越界夹住', () {
    const KaraokeLookupHit hit = KaraokeLookupHit(
      lineIndex: 0,
      syllableIndex: 2,
      charIndexInLine: 2,
      lineText: '夜に駆ける',
      globalRect: Rect.zero,
    );
    expect(musicLyricsLookupTerm(hit), '駆ける');
    expect(
      musicLyricsLookupTerm(
        const KaraokeLookupHit(
          lineIndex: 0,
          syllableIndex: 0,
          charIndexInLine: 99,
          lineText: 'ab',
          globalRect: Rect.zero,
        ),
      ),
      '',
    );
  });

  test('CUE 虚拟曲目的起点带进歌词曲目（不认 sidecar / 内嵌）', () {
    final MusicLyricsTrackRef ref = musicLyricsTrackRefOf(
      const MusicPlayItem(
        trackUid: 'u',
        path: '/m/full.flac',
        title: 'T',
        startMs: 60000,
        endMs: 120000,
        durationMs: 60000,
      ),
    );
    expect(ref.isCueTrack, isTrue);
    expect(ref.durationMs, 60000);
  });

  test('插值时钟：在播时外推、封顶、暂停定住', () {
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(milliseconds: 80),
        playing: true,
      ),
      const Duration(milliseconds: 10080),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(seconds: 30),
        playing: true,
      ),
      const Duration(seconds: 12),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(seconds: 1),
        playing: false,
      ),
      const Duration(seconds: 10),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 59),
        sinceLastEvent: const Duration(seconds: 2),
        playing: true,
        duration: const Duration(seconds: 60),
      ),
      const Duration(seconds: 60),
    );
  });
}
