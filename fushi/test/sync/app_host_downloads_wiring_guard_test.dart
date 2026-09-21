import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 源码守卫：app 当互联 host 时必须把代下载 / 订阅 / 通用任务三面接进
/// [FushiSyncServer]（设计 §3.3）。
///
/// 为什么要钉：这三条端点此前只在无头 fushi_server 接线，app 侧的
/// `FushiSyncServerController` 构造 server 时没传 `downloads` / `subscriptions` /
/// `hostJobs`，对端探能力位时没有这些字段、UI 里「下载到 电脑」根本不出现——而
/// 本地与 CI 全绿，因为没有任何测试沿真实装配路径跑。少传一个参数就是回到那个
/// 状态，widget 测试探不到（host 是 AppModel 整会话持有的，测试从不 start）。
void main() {
  String read(String path) => maskComments(File(path).readAsStringSync());

  test('AppModel 把三面工厂交给 FushiSyncServerController', () {
    final String src = read('lib/src/models/app_model.dart');
    expect(src, contains('downloadsFactory: () => appDownloadHost'));
    expect(src,
        contains('subscriptionsFactory: () => appDownloadHost.subscriptions'));
    expect(src, contains('hostJobsFactory: () async {'));
    expect(src, contains('AsrHostJobRunner('),
        reason: '通用任务面至少要挂 ASR runner，否则 /api/jobs 的 kinds 为空');
  });

  test('FushiSyncServerController 把三面传给 FushiSyncServer', () {
    final String src = read('lib/src/sync/fushi_server_controller.dart');
    expect(src, contains('downloads: _downloadsFactory?.call()'));
    expect(src, contains('subscriptions: _subscriptionsFactory?.call()'));
    expect(src, contains('hostJobs: hostJobs'));
    expect(src, contains('await _hostJobsFactory?.call()'),
        reason: '任务管理器要 load() 磁盘记录后再挂，工厂必须被 await');
  });

  test('AppDownloadHost 的落点 / 后端判据来自 AppModel 同一真相源', () {
    final String src = read('lib/src/models/app_model.dart');
    expect(src, contains('backendTarget: currentVideoDownloadBackendTarget'));
    expect(src, contains('readyBackend: () => readyVideoDownloadBackend'));
    final String actions =
        read('lib/src/pages/implementations/download_actions.dart');
    expect(actions, contains('appModel.readyVideoDownloadBackend != null'),
        reason: '下载页「添加任务」与 host 能力位必须是同一个就绪判据');
  });
}
