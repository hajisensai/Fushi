import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_local_sidecar_audio.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoExternalAudioTrack;
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sidecar_audio_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> touch(String rel) async {
    final File f = File(p.joinAll(<String>[tmp.path, ...rel.split('/')]));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(const <int>[0]);
  }

  test('本地视频旁 / 子目录里的外挂音轨被发现成播放器要挂的绝对路径音轨', () async {
    await touch('Movie.mkv');
    await touch('Movie.jpn.mka');
    await touch('Movie.ja.ass');
    await touch('Audio 5.1/Movie_Eng_Audio_5.1.mka');
    await touch('Extras/Other.mka');

    final List<RemoteVideoExternalAudioTrack> got =
        await discoverLocalSidecarAudioTracks(p.join(tmp.path, 'Movie.mkv'));

    expect(
      got.map((RemoteVideoExternalAudioTrack t) => t.url).toList(),
      <String>[
        p.join(tmp.path, 'Movie.jpn.mka'),
        p.join(tmp.path, 'Audio 5.1', 'Movie_Eng_Audio_5.1.mka'),
      ],
    );
    expect(
      got.map((RemoteVideoExternalAudioTrack t) => t.language).toList(),
      <String?>['jpn', 'eng'],
    );
    expect(got[1].label, 'Eng Audio 5.1');
    for (final RemoteVideoExternalAudioTrack t in got) {
      expect(File(t.url).existsSync(), isTrue);
    }
  });

  test('目录不存在时返回空表', () async {
    expect(
      await discoverLocalSidecarAudioTracks(
        p.join(tmp.path, 'missing', 'a.mkv'),
      ),
      isEmpty,
    );
  });
}
