import 'package:fushi_engine/media/video/metadata/video_web_download_classifier.dart';
import 'package:test/test.dart';

void main() {
  group('isYtDlpYoutubeDownloadPath 识别 yt-dlp 默认命名', () {
    for (final String path in <String>[
      // 反馈 m2pSnkT2mn 的两条 vlog（来源库「影视」）按 yt-dlp 默认模板落盘的样子。
      r'D:\影视\【韓国ソウル旅行①】女子2人で食べて買って韓国日本… [dQw4w9WgXcQ].mp4',
      '/media/影视/北京ユニバに初めて行ったら、列横入りされすぎて [jNQXAC9IVRw].webm',
      'Me at the zoo [jNQXAC9IVRw].mkv',
      // id 含 `-` / `_`、末位是 0/4/8。
      'Some vlog [a-_Zz09xY_0].mp4',
      'Some vlog [-_-_-_-_-_4].mp4',
      'Some vlog [ABCDEFGHIJ8].mp4',
      // 未合并的分轨文件 `.f137` / `.f251-1`。
      'Title [dQw4w9WgXcQ].f137.mp4',
      'Title [dQw4w9WgXcQ].f251-1.webm',
      // 标题里本身带方括号。
      '[歌ってみた] 夜に駆ける [dQw4w9WgXcQ].mp4',
    ]) {
      test('命中：$path', () {
        expect(isYtDlpYoutubeDownloadPath(path), isTrue);
      });
    }
  });

  group('isYtDlpYoutubeDownloadPath 不误判番剧 / 影视发布文件名', () {
    for (final String path in <String>[
      // 字幕组 CRC（8 位十六进制）。
      '[SubsPlease] Sousou no Frieren - 01 (1080p) [F02B9CEE].mkv',
      '[Erai-raws] Kusuriya no Hitorigoto - 01 [1080p][Multiple Subtitle][9A4D6C2B].mkv',
      // 分辨率 / 片源 / 编码标签。
      '[Lilith-Raws] Sousou no Frieren - 01 [Baha][WEB-DL][1080p][AVC AAC][CHT][MP4].mp4',
      '[Nekomoe kissaten][Oshi no Ko][01][1080p][JPSC].mp4',
      '[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3][01][1080P][BDRip].mkv',
      '[Sakurato] Spy x Family [01][HEVC-10bit 1080p AAC][CHS&CHT].mkv',
      'Movie (2020) [BD].mkv',
      'Show - 01 [1080p].mkv',
      // 恰好 11 位、但以 p 结尾（videoId 末位不可能是 p）。
      '[VCB-Studio] Bocchi the Rock! [01][Ma10p_1080p][x265_flac].mkv',
      'Bocchi the Rock! - 01 [Hi10p_1080p].mkv',
      'Show S01E01 [WEBDL-1080p].mkv',
      // 恰好 11 位、末位合法，但内容是发布记号。
      'Show - 01 [WEB_1080p60].mkv',
      'Show - 01 [x265_AAC_JA].mkv',
      'Show - 01 [HEVC_Opus_A].mkv',
      // 连写的方括号（前面不是空白）。
      '[Group][Title][dQw4w9WgXcQ].mp4',
      // 只有 id、没有标题。
      '[dQw4w9WgXcQ].mp4',
      'dQw4w9WgXcQ.mp4',
      // id 不贴扩展名。
      'Title [dQw4w9WgXcQ] extra.mp4',
      // 长度不对（10 / 12 位）。
      'Title [dQw4w9WgXc].mp4',
      'Title [dQw4w9WgXcQA].mp4',
      // Kodi 惯例命名。
      'Frieren (2023)/Season 01/Frieren - S01E01 - The Journey\'s End.mkv',
      // 方括号在目录名里、文件名里没有。
      '/media/Title [dQw4w9WgXcQ]/episode 01.mkv',
    ]) {
      test('不命中：$path', () {
        expect(isYtDlpYoutubeDownloadPath(path), isFalse);
      });
    }
  });
}
