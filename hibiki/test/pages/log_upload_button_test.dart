import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

void main() {
  // 上传门控接到真实端点常量（端点真值在 gitignored log_upload_secret.dart，
  // 仿 google_oauth_secret）。不依赖其具体值，只验证门控与端点严格一致：
  // 配了端点才显示按钮，没配就隐藏，fresh clone（端点空）即编译且不暴露端点。
  test('showUploadLogAction 与端点配置严格一致（门控接线正确）', () {
    expect(showUploadLogAction, isLogUploadConfigured(kLogUploadEndpoint));
  });

  // 源码守卫：入库的模板必须是空占位，绝不能把真实端点/token 提交进 git。
  test('log_upload_secret.example.dart 入库模板不含真实凭据', () {
    final String tmpl = File(
      'lib/src/utils/misc/log_upload_secret.example.dart',
    ).readAsStringSync();
    expect(tmpl, contains("kLogUploadEndpoint = ''"));
    expect(tmpl, contains("kLogUploadToken = ''"));
    // 模板里不应出现真实域名（防误把真值写进入库模板）。
    expect(tmpl.contains('logs.wrds.xyz'), isFalse);
  });
}
