import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('R2 镜像先清理、再按 8GB 安全线上传，失败时回滚半成品', () {
    final String workflow = File(
      '../.github/workflows/mirror-releases.yml',
    ).readAsStringSync();

    expect(workflow, contains("MAX_BUCKET_BYTES: '8000000000'"));
    expect(
      workflow,
      contains('actions/checkout@11d5960a326750d5838078e36cf38b85af677262'),
    );
    expect(workflow, contains('node --test tool/r2_mirror_plan.test.mjs'));
    expect(workflow, contains("if: steps.capacity.outputs.allowed == 'true'"));
    expect(workflow, contains('Roll back partial upload on failure'));
    expect(workflow, contains('mirrored-rollback.json'));
    expect(workflow, contains('未知存量当 0'));
    // 空台账字面量只许出现在人工触发的引导步骤里，且必须先确认桶里没有台账
    // 才写。守卫按步骤切片，而不是全文禁止：全文禁止分不清「读失败时假装桶为空」
    // （必须 fail closed）和「显式引导一个空桶」（有存在性检查、拒绝覆盖）。
    const String emptyLedger = "echo '{\"schemaVersion\":2,\"releases\":[]}'";
    final String bootstrap = _step(
      workflow,
      'Bootstrap verified-empty R2 ledger',
    );
    final String readLedger = _step(workflow, 'Read current R2 ledger');
    expect(
      bootstrap,
      contains("github.event.inputs.bootstrap_empty_ledger == 'true'"),
      reason: '引导空台账只能由人工 dispatch 显式触发',
    );
    expect(
      bootstrap.indexOf('容量台账已经存在，拒绝覆盖'),
      allOf(greaterThan(-1), lessThan(bootstrap.indexOf(emptyLedger))),
      reason: '引导必须先查存在、拒绝覆盖，再写空台账',
    );
    expect(bootstrap, contains('本次不会上传任何 Release 资产'));
    expect(
      readLedger,
      isNot(contains('schemaVersion":2,"releases":[]')),
      reason: '台账读取失败必须 fail closed，不能假装桶为空',
    );
    expect(readLedger, contains('exit 1'));
    expect(
      emptyLedger.allMatches(workflow).length,
      1,
      reason: '空台账字面量只许在引导步骤出现一次，别的步骤不得自造空台账',
    );

    final int prune = workflow.indexOf('Prune old releases before uploading');
    final int upload = workflow.indexOf('Upload assets and commit ledger');
    expect(prune, greaterThan(0));
    expect(
      upload,
      greaterThan(prune),
      reason: '必须先释放旧版本容量，再开始上传，不能用上传后的 prune 制造日峰值',
    );

    expect(
      workflow,
      isNot(contains('Cache Reserve')),
      reason: '零付费方案只允许 R2 免费层，不启用付费 Cache Reserve',
    );
  });

  test('镜像只在发布清单确认资产就位后动手，且镜不全就红', () {
    // v2.2.4：release published 13:14 触发镜像，Android 包 13:44、桌面包 14:52 才上传，
    // 于是只镜像到 3 个 bridge apk 却报 success —— fushi.moe 的「Cloudflare 镜像」
    // 三天都在 302 去 GitHub。这条守卫钉住修复后的两个不变式：就位再动手、镜不全就红。
    final String workflow = File(
      '../.github/workflows/mirror-releases.yml',
    ).readAsStringSync();

    // 唤醒通道：一个指向 update-manifest 分支的 push 触发器一度写在 workflow 里，
    // 实测是**死代码**——两条独立原因任一成立就够：GitHub 对 push 事件是从被推送的
    // 那个 ref 读 `.github/workflows/` 决定跑什么，而 update-manifest 是只放 6 个
    // JSON 的孤儿分支（上面没有 workflow 文件）；而且清单是 GITHUB_TOKEN 推的，
    // 它的 push 不级联新 run。实测 `actions/runs?branch=update-manifest` 的
    // total_count 至今为 0。所以这条触发器必须不在，唤醒只能走显式 dispatch。
    expect(
      workflow,
      isNot(contains('branches: [update-manifest]')),
      reason: '这条 push 触发器是死的（孤儿分支上没有 workflow 文件 + '
          'GITHUB_TOKEN 的 push 不级联），留着只会让人以为镜像会自己醒过来',
    );
    expect(
      workflow,
      contains('assert_complete:'),
      reason: '自动唤醒必须能声明「按清单校验完整性」，否则它和人工补救一样绕过就位门，'
          '下游那条完整性断言就永远拿不到输入',
    );
    expect(
      File('../tool/publish_update_manifest.sh').readAsStringSync(),
      contains('gh workflow run mirror-releases.yml'),
      reason: '清单落地才是「这批资产已上传完」的信号，唤醒必须挂在那一刻；'
          'workflow_dispatch 是 GITHUB_TOKEN 无级联规则的明文例外',
    );
    expect(
      _step(workflow, 'Checkout'),
      isNot(contains(r'ref: ${{ github.event.repository.default_branch }}')),
      reason: '钉默认分支会让 release 路径签出 main 的 tip 而不是被打 tag 的那个 '
          'commit；develop 领先 main 273 个提交时，手动 dispatch 还会因为 main 上'
          '没有判据脚本直接 ENOENT 打红',
    );

    final String target = _step(workflow, 'Resolve target release');
    expect(target, contains('latest-stable-fushi.json?ref=update-manifest'));
    expect(
      target,
      contains('node tool/r2_mirror_readiness.mjs'),
      reason: '就位判据必须走带单测的脚本，不要再内联进 workflow',
    );
    expect(
      target,
      contains('node --test tool/r2_mirror_readiness.test.mjs'),
      reason: '判据脚本的单测要在用它之前跑，和 r2_mirror_plan 同规格',
    );
    expect(
      File('../tool/r2_mirror_readiness.mjs').existsSync(),
      isTrue,
      reason: 'workflow 引用的判据脚本必须真的在仓库里',
    );
    // 「不就位就 exit 0」不能是永久状态：镜像三天只镜到 bridge 包却报 success，
    // 正是这么躺过来的。published 很久了仍未就位 = 发布链路没写完清单、或唤醒断了，
    // 两者都必须响。
    expect(
      target,
      contains('Mirror readiness stalled'),
      reason: '就位门必须有陈旧兜底，否则「本次不镜像」可以静默绿到天荒地老',
    );

    final String build = _step(workflow, 'Build bounded mirror manifest');
    expect(
      build,
      contains('expected-assets.txt'),
      reason: '镜像集合要拿发布清单登记的名单核对，而不是「有几个算几个」',
    );
    expect(
      build,
      contains('发布清单登记的资产没进镜像集合'),
      reason: '缺资产必须让 job 红，不能再产出一次「成功但没用」的镜像',
    );
    expect(
      build,
      contains('oversize-assets.txt'),
      reason: '超单文件上限的资产要落盘并进 summary，别隐身在日志里',
    );
  });
}

/// 切出 workflow 里名为 [name] 的一个 step（从它的 `- name:` 到下一个 `- name:`）。
/// 步骤不存在时直接失败，免得后面的负向断言对空串真空通过。
String _step(String workflow, String name) {
  final int start = workflow.indexOf('- name: $name');
  expect(start, greaterThan(-1), reason: 'workflow 里必须有步骤「$name」');
  final int next = workflow.indexOf('\n      - name: ', start + 1);
  return workflow.substring(start, next == -1 ? workflow.length : next);
}
