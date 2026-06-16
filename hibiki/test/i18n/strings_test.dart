import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';

void main() {
  group('Chinese reader settings labels', () {
    test('uses compact labels for furigana modes', () {
      final strings = AppLocale.zhCn.translations;

      expect(strings.ttu_furigana_partial, '部分');
      expect(strings.ttu_furigana_toggle, '切换');
      expect(
        strings.ttu_furigana_mode_hint,
        '',
      );
    });
  });

  group('Chinese video clip export labels', () {
    test('uses clip export wording consistently', () {
      final strings = AppLocale.zhCn.translations;
      final String formerPixelCaptureTerm =
          String.fromCharCodes(<int>[0x5f55, 0x5c4f]);

      expect(strings.video_clip_export, '片段导出');
      expect(strings.video_clip_export_start, '开始片段导出');
      expect(strings.video_clip_export_stop, '停止并导出片段');
      expect(strings.video_clip_exporting, '正在导出片段…');
      expect(strings.video_clip_export_remote_download_required,
          contains('下载到本机'));
      expect(
          strings.video_clip_export, isNot(contains(formerPixelCaptureTerm)));
      expect(
        strings.video_clip_export_start,
        isNot(contains(formerPixelCaptureTerm)),
      );
      expect(
        strings.video_clip_export_stop,
        isNot(contains(formerPixelCaptureTerm)),
      );
    });
  });
}
