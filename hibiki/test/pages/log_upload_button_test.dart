import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

void main() {
  // 纯门控守卫：未注入 dart-define 时构建不展示上传按钮，
  // 保证 fresh clone / 默认构建零行为变化、不暴露端点。
  test('默认构建（无 dart-define）→ 上传按钮隐藏', () {
    expect(showUploadLogAction, isFalse);
    expect(isLogUploadConfigured(kLogUploadEndpoint), isFalse);
  });
}
