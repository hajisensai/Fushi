import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1184 / TODO-1185 守卫（源码扫描，不依赖真机/真浏览器）。两份扩展镜像
/// （随 app 打包的 `assets/` 与真源 `tools/`）都守，且必须逐字节一致。
///
/// TODO-1184：制卡队列永不清 + 无限循环 —— 根因是出队判据只认 `success`，`duplicate`
///   （卡已存在再制命中 Anki 查重）被判非 ok 永久滞留 → 队列永不清。修复：出队判据放宽为
///   `success || duplicate`（经 hibikiClassifyMineResp 分类），并加逐项删除 UI。
/// TODO-1185：查词弹窗撑满全屏 —— 根因是 `#entries-container` 只有 position/z-index 无宽高
///   约束。修复：content.css 给 `#entries-container` 补 width/max-height/overflow-y 有界约束。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。两份镜像分别在 assets/ 与 ../tools/。
  final File assetsContent = File('assets/browser_extension/content.js');
  final File toolsContent = File('../tools/browser-extension/content.js');
  final File assetsCss = File('assets/browser_extension/vendor/content.css');
  final File toolsCss = File('../tools/browser-extension/vendor/content.css');
  // 服务端主题下发弹窗尺寸的真值源（app_model.browserExtensionThemeColors）。
  final File appModel = File('lib/src/models/app_model.dart');

  group('TODO-1184 制卡队列出队判据 + 逐项删除守卫', () {
    for (final File content in <File>[assetsContent, toolsContent]) {
      group('content.js ${content.path}', () {
        test('文件存在', () {
          expect(content.existsSync(), isTrue,
              reason: 'missing ${content.path}');
        });

        test('出队分类器把 success 与 duplicate 都归为 done（队列才会清）', () {
          final String src = content.readAsStringSync();
          expect(src.contains('function hibikiClassifyMineResp('), isTrue,
              reason: '${content.path} 缺 hibikiClassifyMineResp 分类器');
          // duplicate 必须与 success 同归 done，否则永久滞留 = 队列永不清。
          expect(
            src.contains(
                "if (r === 'success' || r === 'duplicate') return 'done';"),
            isTrue,
            reason: '${content.path} 出队判据未含 duplicate（队列永不清根因）',
          );
          // notConfigured 留队（提示配 Anki），error/网络失败留队重试。
          expect(
              src.contains("if (r === 'notConfigured') return 'unconfigured';"),
              isTrue,
              reason: '${content.path} 未把 notConfigured 归为 unconfigured');
        });

        test('YouTube/Netflix 两条生成路径都走分类器出队', () {
          final String src = content.readAsStringSync();
          expect(
              'resolve(hibikiClassifyMineResp(resp));'.allMatches(src).length,
              greaterThanOrEqualTo(2),
              reason: '${content.path} 生成路径未统一走分类器（应 >=2 处）');
          // 只有 done 才 push okIds 被剔除。
          expect(
              "if (cls === 'done') { done++; okIds.push(q.id); }"
                  .allMatches(src)
                  .length,
              greaterThanOrEqualTo(2),
              reason: '${content.path} 出队未门控到 cls===done');
          // 旧的「仅 success 才出队」硬判据不得残留。
          expect(src.contains("resp.data.result === 'success'"), isFalse,
              reason: '${content.path} 仍残留「仅 success 出队」硬判据（duplicate 会滞留）');
        });

        test('逐项删除 UI：展开列表 + 删除按钮调 hibikiRemoveQueued([id])', () {
          final String src = content.readAsStringSync();
          expect(src.contains('function hibikiRenderQueueList('), isTrue,
              reason: '${content.path} 缺可展开队列列表渲染');
          expect(src.contains("className = 'hibiki-queue-row-del'"), isTrue,
              reason: '${content.path} 缺逐项删除按钮');
          expect(src.contains('hibikiRemoveQueued([id])'), isTrue,
              reason: '${content.path} 删除按钮未调 hibikiRemoveQueued([id])');
        });
      });
    }
  });

  group('TODO-1185 查词弹窗容器有界（不再撑满全屏）', () {
    for (final File css in <File>[assetsCss, toolsCss]) {
      test(
          'content.css ${css.path} #entries-container 有 max-height + overflow-y',
          () {
        final String src = css.readAsStringSync();
        expect(src.contains('max-height: min('), isTrue,
            reason: '${css.path} #entries-container 缺 max-height 约束');
        expect(src.contains('overflow-y: auto;'), isTrue,
            reason: '${css.path} #entries-container 缺 overflow-y 内部滚动');
        // TODO-1185 follow-up：弹窗宽/高必须消费**服务端真喂**的变量名
        // （browserExtensionThemeColors 下发 --hibiki-popup-max-width /
        //  --hibiki-popup-max-height），否则查词响应下发的用户配置尺寸永远落不到
        //  弹窗上（历史 bug：content.css 曾读 --hibiki-popup-width，服务端只发
        //  --hibiki-popup-max-width → 宽度死锁 400px）。默认 400×360 兜底保留。
        expect(src.contains('var(--hibiki-popup-max-width, 400px)'), isTrue,
            reason: '${css.path} 弹窗宽度未消费服务端下发的 --hibiki-popup-max-width');
        expect(src.contains('var(--hibiki-popup-max-height, 360px)'), isTrue,
            reason: '${css.path} 弹窗高度未消费服务端下发的 --hibiki-popup-max-height');
        // 旧的不匹配变量名不得复活（服务端从不发 --hibiki-popup-width）。
        expect(src.contains('var(--hibiki-popup-width,'), isFalse,
            reason: '${css.path} 残留服务端从不下发的 --hibiki-popup-width（宽度死锁根因）');
      });
    }
  });

  group('TODO-1185 follow-up 服务端下发弹窗尺寸变量名与 CSS 消费一致', () {
    test('app_model.browserExtensionThemeColors 下发 max-width/height 两变量', () {
      final String src = appModel.readAsStringSync();
      // 服务端在查词响应 theme 字段里把用户配置的 popupMaxWidth/Height 作为这两个
      // CSS 变量下发；content.js hibikiRender 逐项 setProperty 到 #entries-container，
      // content.css 用同名 var(...) 消费 → 扩展弹窗跟随 app 内弹窗尺寸设置。
      expect(src.contains("'--hibiki-popup-max-width':"), isTrue,
          reason: 'app_model 未下发 --hibiki-popup-max-width（扩展宽度无法跟随配置）');
      expect(src.contains("'--hibiki-popup-max-height':"), isTrue,
          reason: 'app_model 未下发 --hibiki-popup-max-height（扩展高度无法跟随配置）');
      expect(src.contains('popupMaxWidth.round()'), isTrue,
          reason: 'app_model 未用用户配置 popupMaxWidth 生成弹窗宽度变量');
      expect(src.contains('popupMaxHeight.round()'), isTrue,
          reason: 'app_model 未用用户配置 popupMaxHeight 生成弹窗高度变量');
    });

    for (final File content in <File>[assetsContent, toolsContent]) {
      test('content.js ${content.path} 把 theme 每项 setProperty 到弹窗容器', () {
        final String src = content.readAsStringSync();
        // 通用 theme 应用循环：--hibiki-popup-max-* 与 --md-* 同路径下发生效，
        // 无需为弹窗尺寸单开一条并行路径（单一真相源=theme 映射）。
        expect(src.contains('c.style.setProperty(k, theme[k])'), isTrue,
            reason: '${content.path} 缺 theme 逐项 setProperty（弹窗尺寸/主题下发生效点）');
      });
    }
  });

  group('两份镜像逐字节一致', () {
    test('content.js', () {
      expect(assetsContent.readAsBytesSync(), toolsContent.readAsBytesSync(),
          reason: 'content.js 两份镜像不一致');
    });
    test('content.css', () {
      expect(assetsCss.readAsBytesSync(), toolsCss.readAsBytesSync(),
          reason: 'content.css 两份镜像不一致');
    });
  });
}
