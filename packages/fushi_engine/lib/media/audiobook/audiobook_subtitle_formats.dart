/// 有声书字幕格式的**唯一真相源**：能被 `parseCuesForFormat` 解析成 cue 的扩展名
/// （不带点，小写）。
///
/// 集合的迭代顺序就是「同一主干有多份字幕时挑哪份」的格式优先级：
/// `srt > vtt > ass > ssa > lrc`（本机导入扫同名字幕 `findSidecars` 一直用的顺序；
/// Audiobookshelf 服务器字幕的推荐与它同序）。
///
/// 导入 / 重新导入对话框的选择器、同名字幕扫描、拖放分类、发现页下载分类、对齐
/// matcher 门控、Audiobookshelf 服务器文件识别都引用这一份，不再各写一份（守卫
/// `fushi/test/media/audiobook/audiobook_subtitle_formats_guard_test.dart`）。
library;

const Set<String> kAudiobookSubtitleExtensions = <String>{
  'srt',
  'vtt',
  'ass',
  'ssa',
  'lrc',
};

/// [ext] 是否为有声书字幕扩展名；带不带前导点、大小写都行。
bool isAudiobookSubtitleExtension(String ext) => kAudiobookSubtitleExtensions
    .contains(ext.toLowerCase().replaceFirst(RegExp(r'^\.'), ''));
