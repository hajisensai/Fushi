import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：**用户可见文案里不得再出现「实验性」标注**。
///
/// 由来：视频功能当初挂过「实验性」横幅，稳定后按用户要求移除；随后文本钩子的横幅
/// 与设置页后缀也一并移除；最后用户要求「实验性的名字都砍掉」——设置页里那个共享的
/// `settings_experimental_suffix` 后缀（词典列数 / Yomitan API / 焦点导航 / 数据根
/// 位置四处叠加）、以及内嵌在 `desktop_clipboard_enabled_hint`、
/// `settings_destination_sync_backup` 值里的括注，全部删除。
///
/// 这条守卫扫的是 **i18n 源文件的值**，不是 key 名或代码标识符——`experimental` 作为
/// 内部字段名（如 `experimental_focus_navigation_enabled` 偏好键、
/// `experimentalFocusNavigationEnabled` getter）是**冻结的持久化名与实现细节**，
/// 用户看不见，不在本守卫范围内，也不该为了这条规则去改（改了要迁移偏好）。
///
/// 判据用多语言词根：只查英文会漏掉「実験的機能」「экспериментальный」这类。
void main() {
  // 各语言「实验性」的词根。命中任一即认定是实验性标注。
  const List<String> stems = <String>[
    'experiment', // en / nl(experimenteel) / id(eksperimental) 前缀
    'experimentell', // de
    'experimental', // es / pt-BR
    'expériment', // fr
    'sperimentale', // it
    '実験', // ja
    '실험', // ko
    '实验', // zh-CN
    '實驗', // zh-HK
    'эксперимент', // ru
    'ทดลอง', // th
    'deneysel', // tr
    'thử nghiệm', // vi
    'تجريب', // ar
  ];

  // 发布通道名称白名单。
  //
  // 「实验性功能」与「测试版/预发布版」是两件事：前者说功能不稳定（本次要删的），
  // 后者是发布通道名（beta / prerelease，必须留）。偏偏阿拉伯语的 تجريبي 和越南语的
  // thử nghiệm 同一个词根既表「实验性」又表「测试版」——上面按词根扫必然误伤这两个
  // key。按 key 名精确豁免，而不是把词根从清单里删掉（删词根会让这两种语言的真·
  // 实验性标注从此漏网）。
  const Set<String> releaseChannelKeys = <String>{
    'changelog_prerelease',
    'update_channel_beta',
  };

  test('17 个语言的 i18n 值里不得出现「实验性」标注', () {
    final Directory dir = Directory('lib/i18n');
    expect(dir.existsSync(), isTrue,
        reason: 'i18n 目录必须存在（cwd=${Directory.current.path}）');

    final List<File> files = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.i18n.json'))
        .toList();
    // 反空转：Slang 要求 17 个语言文件齐全，扫描面必须真的是这 17 个。
    expect(files.length, 17,
        reason: '应扫到 17 个语言文件，实际 ${files.length} 个');

    final List<String> offenders = <String>[];
    for (final File f in files) {
      final Map<String, dynamic> map =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      // 反空转：每个文件都必须有内容，否则「没命中」毫无意义。
      expect(map, isNotEmpty, reason: '${f.path} 解析出空表');
      map.forEach((String key, dynamic value) {
        if (value is! String) return;
        if (releaseChannelKeys.contains(key)) return;
        final String lower = value.toLowerCase();
        for (final String stem in stems) {
          if (lower.contains(stem)) {
            offenders.add('${f.uri.pathSegments.last} :: $key = $value');
            return;
          }
        }
      });
    }

    expect(
      offenders,
      isEmpty,
      reason: '用户可见文案不得再自称实验性功能，命中：\n${offenders.join('\n')}',
    );
  });
}
