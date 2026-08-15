import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1667 守卫：本地音频库导入必须走「真实路径」选择器，不得回到裸
/// `FilePicker.platform.pickFiles()`。
///
/// 为什么值得一条守卫：安卓上 file_picker 会把选中文件**整份同步复制进 app cache**
/// （`FileUtils.openFileStream`）再返回缓存路径，随后 `LocalAudioManager.importFile`
/// 又复制一份进库目录 → 峰值需要 **2 倍库体积的内部存储**。而本地音频库正是全 app
/// 体积最大的导入物（Yomitan 本地音频服务器的 android.db 常见 1~6 GB，本机真库
/// 6.2 GB），6 GB 的库要 12 GB、全程只有一个转圈 → 多数手机直接失败或看起来永久卡死。
/// 视频 / 书 / 有声书 / 漫画 / 字幕 / 制卡音频早就统一走 `pickRealFilePath*`，
/// 本地音频库是最后一条漏网的——别再漏回去。
void main() {
  String read(String relative) {
    final File file = File(relative);
    expect(file.existsSync(), isTrue, reason: '守卫目标文件不存在：$relative');
    return file.readAsStringSync();
  }

  const String wiring = 'lib/src/settings/settings_schema_lookup.dart';
  const String dialog =
      'lib/src/pages/implementations/dictionary_settings_dialog_page.dart';
  const String picker = 'lib/src/media/import/real_path_directory_picker.dart';

  test('本地音频库导入走带出处的真实路径选择器', () {
    final String source = read(wiring);
    expect(source.contains('pickRealFilePathDetailed('), isTrue,
        reason: '本地音频库导入必须走 pickRealFilePathDetailed（安卓 SAF 真实路径、零复制）');
  });

  test('本地音频库导入不再直接调 file_picker', () {
    final String source = read(wiring);
    expect(source.contains('FilePicker.platform.pickFiles'), isFalse,
        reason: '裸 pickFiles 在安卓会先把整份 android.db 复制进 app cache，'
            '叠加 importFile 的第二次复制 = 2 倍体积');
    expect(source.contains('package:file_picker/file_picker.dart'), isFalse,
        reason: '本文件不该再依赖 file_picker');
  });

  test('引用与否由路径出处决定，不是按平台猜', () {
    final String source = read(wiring);
    expect(source.contains('picked.isRealPath'), isTrue,
        reason: '能不能引用必须看选择器实际交回的是真实路径还是 cache 临时副本');
    // 拿到的是 cache 临时副本时必须降级为复制（引用一个会被系统清掉的文件 = 悬空）。
    expect(source.contains('reference && canReference'), isTrue,
        reason: '出处不是真实路径时必须降级为复制');
    expect(source.contains('t.local_audio_reference_unavailable'), isTrue,
        reason: '降级必须对用户可见，不能静默改变用户选择');
  });

  test('选择器如实交出路径出处', () {
    final String source = read(picker);
    expect(source.contains('class PickedFilePath'), isTrue);
    expect(source.contains('isRealPath'), isTrue);
    // 安卓无全文件访问时回退 file_picker，那条路径是 cache 副本，必须标 false。
    expect(source.contains('isRealPath: false'), isTrue,
        reason: 'file_picker 回退分支必须如实标记为「非真实路径」');
  });

  test('引用开关不再被 isDesktopPlatform 硬门控', () {
    final String source = read(dialog);
    expect(source.contains('_referenceOriginal && isDesktopPlatform'), isFalse,
        reason: '安卓授予全文件访问后走 SAF 解析真实路径、不产生副本，'
            '「移动端只能拿缓存副本」的旧前提已不成立');
  });
}
