// AI 功能模块（ModuleId.ai）的入口守卫：每个 AI 入口在渲染前都经过唯一 UI 判据
// `isAiModuleEnabled`，运行时由 `PreferencesRepository.aiFeatureAssignments` 兜底。
//
// 入口散在十几个文件里，新加一处「让 AI 帮忙」很容易忘了接模块门——编译不报、测试
// 不红，只是用户关了 AI 还看得见按钮。所以这里**反向枚举**：扫 lib/ 找出每一处
// AI 入口的构造 / 接线点，要求它在同一个文件里经过判据；不是手抄一份文件名单。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一类 AI 入口：[site] 匹配到的每一处接线都要有一处 [gate] 与之对应。
class _EntrySite {
  const _EntrySite(this.name, this.site, this.gate, {this.definitionFile});

  final String name;
  final RegExp site;
  final RegExp gate;

  /// 入口自己的定义文件（声明处不是接线点，跳过）。
  final String? definitionFile;
}

final List<_EntrySite> _sites = <_EntrySite>[
  _EntrySite(
    'galgame 文本处理编辑器的「让 AI 帮忙」',
    RegExp(r'GalTextProcessEditorPage\('),
    RegExp(r'aiEnabled:\s*isAiModuleEnabled\('),
    definitionFile: 'gal_text_process_editor_page.dart',
  ),
  _EntrySite(
    'Lapis 样式编辑器的「让 AI 帮忙」',
    RegExp(r'LapisStyleEditorPage\('),
    RegExp(r'aiEnabled:\s*isAiModuleEnabled\('),
    definitionFile: 'lapis_style_editor_page.dart',
  ),
  _EntrySite(
    '刮削任务面板的「AI 识别」',
    RegExp(r'showVideoSourceScrapeTaskPanel\('),
    RegExp(r'showAiIdentify:\s*isAiModuleEnabled\('),
    definitionFile: 'video_source_scrape_dialog.dart',
  ),
  _EntrySite(
    '合集详情页排序菜单的「AI 排序」',
    // 透传（`widget.collectionAiSettings`）不是新入口，只认真正求值的接线点。
    RegExp(r'collectionAiSettings:(?!\s*widget\.)'),
    RegExp(r'collectionAiSettings:\s*isAiModuleEnabled\('),
  ),
  _EntrySite(
    '库页顶栏的「AI 整理」',
    RegExp(r'onAiOrganize:(?!\s*widget\.)'),
    RegExp(r'onAiOrganize:\s*isAiModuleEnabled\('),
  ),
  _EntrySite(
    '库页多选的「AI 整理所选」',
    RegExp(r't\.library_organize_selection_action'),
    RegExp(r'if \(isAiModuleEnabled\([^\n]*\)\)\s*FushiIconButton\('),
  ),
  _EntrySite(
    '漫画 OCR 的 AI 档位面板',
    RegExp(r'aiModeGetter:'),
    RegExp(r'aiModeGetter:\s*isAiModuleEnabled\('),
    definitionFile: 'manga_ocr_settings_section.dart',
  ),
];

/// 自己判门（不经调用方传参）的入口文件：文件里必须出现判据。
const Map<String, String> _selfGatedFiles = <String, String>{
  'lib/src/pages/implementations/custom_theme_page.dart': '自定义主题的 AI 卡',
  'lib/src/pages/implementations/dictionary_settings_dialog_page.dart':
      '词典样式编辑器的「让 AI 帮忙」',
  'lib/src/pages/implementations/discovery_ai_acquire_action.dart':
      '发现页的「AI 下载」（小说 / 漫画 / 游戏）',
  'lib/src/pages/implementations/home_page.dart': '视频发现的「AI 下视频」',
};

String _read(String path) => File(path).readAsStringSync();

void main() {
  final List<File> libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();

  for (final _EntrySite entry in _sites) {
    test('${entry.name}：每处接线都经过 isAiModuleEnabled', () {
      int sites = 0;
      for (final File file in libFiles) {
        final String path = file.path.replaceAll(r'\', '/');
        if (entry.definitionFile != null &&
            path.endsWith('/${entry.definitionFile}')) {
          continue;
        }
        final String source = file.readAsStringSync();
        final int found = entry.site.allMatches(source).length;
        if (found == 0) continue;
        sites += found;
        expect(
          entry.gate.allMatches(source).length,
          greaterThanOrEqualTo(found),
          reason:
              '$path 里有 $found 处 ${entry.name} 接线，'
              '但没有都按 ${entry.gate.pattern} 接 AI 模块门',
        );
      }
      expect(sites, greaterThan(0), reason: '一处接线都没扫到 = 守卫空转（入口改名了？）');
    });
  }

  test('自己判门的 AI 入口文件都调用 isAiModuleEnabled', () {
    _selfGatedFiles.forEach((String path, String name) {
      expect(
        _read(path),
        contains('isAiModuleEnabled('),
        reason: '$name（$path）没有经过 AI 模块判据',
      );
    });
  });

  test('「设置 › AI」归 AI 模块，判据只写在 module_registry 一处', () {
    final String registry = _read('lib/src/models/module_registry.dart');
    expect(
      registry,
      matches(RegExp(r'SettingsDestinationId\.ai\s*=>\s*ModuleId\.ai,')),
    );
    expect(
      registry,
      matches(
        RegExp(r'bool isAiModuleEnabled\(ModuleVisibility visibility\) =>'),
      ),
    );
  });

  test('运行时兜底：生效指派在 AI 模块关闭时投影成空', () {
    final String prefs = _read('lib/src/models/preferences_repository.dart');
    expect(
      prefs,
      matches(
        RegExp(
          r'AiFeatureAssignments get aiFeatureAssignments => '
          r'moduleEnabled\(ModuleId\.ai\)',
        ),
      ),
    );
    // 设置页编辑必须读真实存的指派，否则模块关着时保存会清空用户配置。
    expect(
      _read('lib/src/pages/implementations/ai_provider_settings_section.dart'),
      contains('prefsRepo.storedAiFeatureAssignments'),
    );
  });
}
