import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/pages/implementations/music/music_subtitle_actions.dart';
import 'package:path/path.dart' as p;

/// 歌词页「生成日语字幕」入口的门（反馈 NXOjldMQZd）：本机文件照旧；在线音源插件曲目在
/// 本机能转录、且插件取流已装配时也出入口（先取音频再转写）；其余远端曲目（服务器流 /
/// 网络来源）仍不出；本机不能转录时一律不出。
void main() {
  final bool Function() asrGate = musicSubtitleAsrSupported;
  final bool Function() streamGate = musicPluginAsrStreamReady;

  tearDown(() {
    musicSubtitleAsrSupported = asrGate;
    musicPluginAsrStreamReady = streamGate;
  });

  MusicPlayItem itemAt(String path) =>
      MusicPlayItem(trackUid: 'u', path: path, title: 't');

  final MusicPlayItem local = itemAt(
    p.join(p.current, 'music', 'drama', '01.flac'),
  );
  final MusicPlayItem plugin = itemAt(musicPluginTrackPath('asmr', 'RJ01'));
  final MusicPlayItem server = itemAt('https://srv.invalid/stream/a.flac');

  test('能转录 + 插件取流已装配：本机文件与插件曲目出入口，服务器流不出', () {
    musicSubtitleAsrSupported = () => true;
    musicPluginAsrStreamReady = () => true;
    expect(musicSubtitleGenerationAvailableForItem(local), isTrue);
    expect(musicSubtitleGenerationAvailableForItem(plugin), isTrue);
    expect(musicSubtitleGenerationAvailableForItem(server), isFalse);
  });

  test('插件取流未装配（合规门没过等）：插件曲目不出入口', () {
    musicSubtitleAsrSupported = () => true;
    musicPluginAsrStreamReady = () => false;
    expect(musicSubtitleGenerationAvailableForItem(plugin), isFalse);
    expect(musicSubtitleGenerationAvailableForItem(local), isTrue);
  });

  test('本机不能转录：一律不出', () {
    musicSubtitleAsrSupported = () => false;
    musicPluginAsrStreamReady = () => true;
    expect(musicSubtitleGenerationAvailableForItem(local), isFalse);
    expect(musicSubtitleGenerationAvailableForItem(plugin), isFalse);
  });

  test('曲库批量 / 详情页的路径门不因此放开插件曲目（那些入口按曲库行解析目标）', () {
    musicSubtitleAsrSupported = () => true;
    musicPluginAsrStreamReady = () => true;
    expect(musicSubtitleGenerationAvailable(plugin.path), isFalse);
  });
}
