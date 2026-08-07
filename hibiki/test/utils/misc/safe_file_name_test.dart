import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/safe_file_name.dart';

void main() {
  group('safeWindowsFileName', () {
    test(r'反斜杠也被替换（BUG-1125 回归：id 含 \ 时旧手写版会当成路径分隔符）', () {
      expect(safeWindowsFileName(r'cloud\video:01'), 'cloud_video_01');
      expect(safeWindowsFileName(r'a\b/c'), 'a_b_c');
    });

    test('九个 Windows 保留字符全部替换为 _', () {
      expect(
        safeWindowsFileName(r'a\b/c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
    });

    test(r'控制字符 \x00-\x1f 替换为 _', () {
      expect(safeWindowsFileName('a\x00b\x1fc\nd\te'), 'a_b_c_d_e');
    });

    test('安全字符（日文/空格/点/下划线）原样保留——既有磁盘产物文件名不漂移', () {
      expect(
        safeWindowsFileName('響け！ユーフォニアム 第1話.mp4'),
        '響け！ユーフォニアム 第1話.mp4',
      );
      expect(
        safeWindowsFileName('video_playlist_list_abc123'),
        'video_playlist_list_abc123',
      );
    });

    test('不折叠连续替换结果、不 trim（折叠/trim 由调用方按既有契约叠加）', () {
      expect(safeWindowsFileName('a//b'), 'a__b');
      expect(safeWindowsFileName(' a '), ' a ');
    });
  });
}
