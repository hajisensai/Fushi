import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-290 / TODO-385 守卫：错误日志「上传到云端」按钮的显示由非空端点门控
/// （`showUploadLogAction => isLogUploadConfigured(kLogUploadEndpoint)`，无平台判断）。
/// CI/release 构建拿到的是入库的空占位 `log_upload_secret.dart` → 端点为空 →
/// 按钮在所有平台（含 Windows）永久隐藏。根因是出包的 workflow 从未注入
/// log_upload 真值密钥（对比 google_oauth_secret 每个 job 都注入）。
///
/// 此守卫钉死契约：**任何注入 google_oauth_secret 的 job 必须对称地注入
/// log_upload_secret**，否则将来加新平台 job 时又会漏注入导致按钮重新消失。
void main() {
  const List<String> workflows = <String>[
    'build-multiplatform.yml',
    'release.yml',
    'release-desktop.yml',
  ];

  String readWorkflow(String relativePath) {
    final File file = File('../.github/workflows/$relativePath');
    expect(file.existsSync(), isTrue,
        reason: 'expected workflow at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  /// 统计某子串出现次数。
  int countOf(String haystack, String needle) {
    int count = 0;
    int from = 0;
    while (true) {
      final int idx = haystack.indexOf(needle, from);
      if (idx < 0) break;
      count++;
      from = idx + needle.length;
    }
    return count;
  }

  for (final String name in workflows) {
    test('$name: log_upload secret 注入与 google_oauth 注入数量对称', () {
      final String workflow = readWorkflow(name);
      final int oauthSteps =
          countOf(workflow, 'Provide gitignored Google OAuth secret stub');
      final int logSteps =
          countOf(workflow, 'Provide gitignored log upload secret stub');
      expect(oauthSteps, greaterThan(0),
          reason: '$name 应至少有一个 google_oauth 注入步骤（基准范式）');
      expect(
        logSteps,
        oauthSteps,
        reason: '$name：每个 google_oauth 注入 job 必须对称注入 log_upload，'
            '否则该平台构建的「上传日志」按钮会因端点空而永久隐藏（BUG-290）',
      );
    });

    test('$name: log_upload 注入步骤接到真实 secret 并写两个常量', () {
      final String workflow = readWorkflow(name);
      // 引用 GitHub repo secret（未配置时回退空占位，按钮隐藏，向后兼容）。
      expect(workflow,
          contains(r'LOG_UPLOAD_ENDPOINT: ${{ secrets.LOG_UPLOAD_ENDPOINT }}'));
      expect(workflow,
          contains(r'LOG_UPLOAD_TOKEN: ${{ secrets.LOG_UPLOAD_TOKEN }}'));
      // 写穿真实密钥文件（不是 example），且两个常量都写。
      expect(workflow,
          contains('dst=hibiki/lib/src/utils/misc/log_upload_secret.dart'));
      expect(workflow, contains('const String kLogUploadEndpoint = %s;'));
      expect(workflow, contains('const String kLogUploadToken = %s;'));
      // 未配置 secret 时回退到入库空占位，保证 fresh CI 仍可编译、不暴露端点。
      expect(
          workflow,
          contains('cp hibiki/lib/src/utils/misc/'
              'log_upload_secret.example.dart "\$dst"'));
    });
  }
}
