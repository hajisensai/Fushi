import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-290 / TODO-385 守卫：错误日志「上传到云端」按钮的显示由非空端点门控
/// （`showUploadLogAction => isLogUploadConfigured(kLogUploadEndpoint)`，无平台判断）。
/// CI/release 构建拿到的是入库的空占位 `log_upload_secret.dart` → 端点为空 →
/// 按钮在所有平台（含 Windows）永久隐藏。根因是出包的 workflow 从未注入
/// log_upload 真值密钥（对比 google_oauth_secret 每个 job 都注入）。
///
/// ## 2026-08-13（BUG-1588）：守卫对象从「每个 workflow 的 inline 步骤」改为
/// composite action
///
/// 原先这条守卫逐个 workflow 数「log_upload 注入次数必须等于 google_oauth 注入
/// 次数」，因为那时每个 job 都各抄一份。抄到第 11 份时 TMDB 已经漂成 3 个变体、
/// 两条发布 workflow 一处都没有（BUG-1588）。现在四段注入收进
/// `.github/actions/provide-baked-secrets`，「对称」由结构保证：同一个 action 里
/// 要么两段都在、要么都不在。
///
/// 于是本守卫改守两件事：真相源里 log_upload 与 google_oauth **并存**，且
/// log_upload 那段仍然写穿真实密钥文件的两个常量、缺 secret 时回退空占位。
/// 「每个构建 job 都用上这个 action」由
/// `baked_secret_stub_parity_guard_test.dart` 负责，不在这里重复。
void main() {
  final File actionFile =
      File('../.github/actions/provide-baked-secrets/action.yml');

  test('前置：密钥注入的真相源存在', () {
    expect(actionFile.existsSync(), isTrue,
        reason: '缺 ${actionFile.absolute.path}。注入被搬走了？把本守卫指向新'
            '位置，别让它静默跑空——BUG-290 的按钮消失没有任何构建期症状。');
  });

  final String action =
      actionFile.existsSync() ? actionFile.readAsStringSync() : '';

  test('log_upload 注入与 google_oauth 注入并存于同一个真相源', () {
    expect(
        action, contains('- name: Provide gitignored Google OAuth secret stub'),
        reason: '基准范式（google_oauth 注入）都不在了，说明这个文件已经不是'
            '密钥注入的真相源，本守卫失去锚点。');
    expect(
      action,
      contains('- name: Provide gitignored log upload secret stub'),
      reason: '真相源里有 google_oauth 注入却没有 log_upload 注入：所有平台'
          '构建的「上传日志」按钮都会因端点为空而永久隐藏（BUG-290）。',
    );
  });

  test('log_upload 注入接到真实 secret 并写两个常量', () {
    // 引用 GitHub repo secret（未配置时回退空占位，按钮隐藏，向后兼容）。
    expect(action,
        contains(r'LOG_UPLOAD_ENDPOINT: ${{ inputs.log-upload-endpoint }}'));
    expect(
        action, contains(r'LOG_UPLOAD_TOKEN: ${{ inputs.log-upload-token }}'));
    // 写穿真实密钥文件（不是 example），且两个常量都写。
    expect(action,
        contains('dst=fushi/lib/src/utils/misc/log_upload_secret.dart'));
    expect(action, contains('const String kLogUploadEndpoint = %s;'));
    expect(action, contains('const String kLogUploadToken = %s;'));
    // 未配置 secret 时回退到入库空占位，保证 fresh CI 仍可编译、不暴露端点。
    expect(
        action,
        contains('cp fushi/lib/src/utils/misc/'
            'log_upload_secret.example.dart "\$dst"'));
  });

  test('调用方把真实 repo secret 接进 action 输入', () {
    final Directory workflowsDir = Directory('../.github/workflows');
    expect(workflowsDir.existsSync(), isTrue);
    final List<String> callers = <String>[];
    for (final File f in workflowsDir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.yml') && !f.path.endsWith('.yaml')) continue;
      final String text = f.readAsStringSync();
      if (!text.contains('uses: ./.github/actions/provide-baked-secrets')) {
        continue;
      }
      final String name = f.uri.pathSegments.last;
      if (!text.contains(
          r'log-upload-endpoint: ${{ secrets.LOG_UPLOAD_ENDPOINT }}')) {
        callers.add('  $name 用了 action 但没把 LOG_UPLOAD_ENDPOINT 接进去');
      }
    }
    expect(callers, isEmpty,
        reason: '输入没接上 secret 时 action 会拿到空串，等于没注入——'
            '症状与「从未注入」完全一致：\n${callers.join("\n")}');
  });
}
