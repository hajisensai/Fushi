import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';

/// TODO-1306 单一真相源守卫：拖入分类用的 [isImportableDropUrl] 必须与流媒体导入的
/// 权威判据 [isPlayableStreamUrl]（url_stream_video.dart）对同一批样本判定一致——否则
/// 「拖进来被识别为可导入 URL」与「导入时被接受为可播流」会漂移（拖入识别了却导入拒绝，
/// 或反之），出现拖了没反应/半截入库的诡异行为。
void main() {
  const List<String> samples = <String>[
    'https://youtu.be/abc',
    'http://example.com/live.m3u8',
    'https://cdn.test/movie.mp4',
    'HTTPS://UPPER.test/x',
    'https://host',
    'http://', // 无 host
    'https://', // 无 host
    'file:///x/a.mkv',
    'ftp://h/x',
    r'C:\movies\a.mkv',
    '/home/u/a.epub',
    r'\server\share\a.mkv',
    'not a url',
    '',
    '   ',
    'https://x.test/v?a=1#frag',
    '  https://leading.space/x  ',
  ];

  test('isImportableDropUrl agrees with isPlayableStreamUrl on all samples',
      () {
    for (final String s in samples) {
      expect(
        isImportableDropUrl(s),
        isPlayableStreamUrl(s),
        reason: 'drop-url 判据与 stream-url 判据漂移，样本："$s"',
      );
    }
  });
}
