import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1184 / TODO-1185 守卫（源码扫描，不依赖真机/真浏览器）。两份扩展镜像
/// （随 app 打包的 `assets/` 与真源 `tools/`）都守，且必须逐字节一致。
///
/// TODO-1184：制卡队列永不清 + 无限循环 —— 根因是出队判据只认 `success`，`duplicate`
///   （卡已存在再制命中 Anki 查重）被判非 ok 永久滞留 → 队列永不清。修复：出队判据放宽为
///   `success || duplicate`（经 hibikiClassifyMineResp 分类），并加逐项删除 UI。
///   TODO-1221 后续：页面右下角常驻队列 chip 已删，队列 UI（列表 + 逐项删除）统一迁到浏览器
///   工具栏图标 popup（`vendor/action-popup.js`）；出队分类器仍在 content.js，逐项删除守卫
///   随之指向 action-popup.js 的 hibikiFilterQueue/removeItem/hp-del（语义契约「队列可逐项
///   删除」不变，仅承载点迁移）。
/// TODO-1185：查词弹窗撑满全屏 —— 根因是 `#entries-container` 只有 position/z-index 无宽高
///   约束。修复：content.css 给 `#entries-container` 补 width/max-height/overflow-y 有界约束。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。两份镜像分别在 assets/ 与 ../tools/。
  final File assetsContent = File('assets/browser_extension/content.js');
  final File toolsContent = File('../tools/browser-extension/content.js');
  final File assetsActionPopup =
      File('assets/browser_extension/vendor/action-popup.js');
  final File toolsActionPopup =
      File('../tools/browser-extension/vendor/action-popup.js');
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
          // TODO-1303：判据从单行 return 改成多行块（success 但单词音频落空时先弹
          // toast 再 return 'done'）。守卫改鲁棒语义——success||duplicate 组合谓词存在，
          // 且其块内（notConfigured 分支之前）return 'done'——语义不变。
          final int classifyIdx =
              src.indexOf('function hibikiClassifyMineResp(');
          final int doneBranchIdx = src.indexOf(
              "if (r === 'success' || r === 'duplicate')", classifyIdx);
          final int notConfiguredIdx =
              src.indexOf("if (r === 'notConfigured')", classifyIdx);
          expect(doneBranchIdx, greaterThan(classifyIdx),
              reason: '${content.path} 缺 success||duplicate 组合出队判据（队列永不清根因）');
          expect(notConfiguredIdx, greaterThan(doneBranchIdx),
              reason:
                  '${content.path} notConfigured 判据应在 success||duplicate 之后');
          expect(
            src
                .substring(doneBranchIdx, notConfiguredIdx)
                .contains("return 'done';"),
            isTrue,
            reason:
                '${content.path} success||duplicate 块内未 return done（duplicate 会滞留=队列永不清根因）',
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
      });
    }

    // TODO-1221：逐项删除 UI 已从页面浮层 chip 迁到工具栏图标 popup（action-popup.js）。
    // 语义契约「队列可逐项删除」不变，守卫指向新承载点：纯剔除函数 hibikiFilterQueue +
    // 逐项删除 removeItem + 删除按钮 hp-del（点击调 removeItem(id)）。
    for (final File popup in <File>[assetsActionPopup, toolsActionPopup]) {
      group('action-popup.js ${popup.path}', () {
        test('文件存在', () {
          expect(popup.existsSync(), isTrue, reason: 'missing ${popup.path}');
        });

        test('逐项删除 UI：列表渲染 + 删除按钮调 removeItem(id)（剔除走 hibikiFilterQueue）', () {
          final String src = popup.readAsStringSync();
          // 纯剔除函数（读-改-写核心，node 测试也守）。
          expect(src.contains('function hibikiFilterQueue('), isTrue,
              reason: '${popup.path} 缺队列剔除纯函数 hibikiFilterQueue');
          // 逐项删除入口。
          expect(src.contains('async function removeItem('), isTrue,
              reason: '${popup.path} 缺逐项删除 removeItem');
          // 删除按钮。
          expect(src.contains("del.className = 'hp-del';"), isTrue,
              reason: '${popup.path} 缺逐项删除按钮 hp-del');
          // 按钮点击调 removeItem(id)。
          expect(src.contains('if (id) removeItem(id);'), isTrue,
              reason: '${popup.path} 删除按钮未调 removeItem(id)');
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
      // PR#83（弹窗尺寸精细化）：弹窗宽/高不再直接取 popupMaxWidth/Height，改由
      // extensionPopupEffectiveSize 解析——用户解锁「扩展独立尺寸」用扩展自己的键，
      // 否则回退 app 内 popupMaxWidth/Height（effectiveLookupSize 纯函数）。守卫仍
      // 咬「弹窗尺寸变量源自用户配置、非硬编码 400×360」，只把符号更到有效尺寸解析入口。
      expect(src.contains('extensionPopupEffectiveSize.width.round()'), isTrue,
          reason:
              'app_model 未经 extensionPopupEffectiveSize 生成弹窗宽度变量（应源自用户配置尺寸）');
      expect(src.contains('extensionPopupEffectiveSize.height.round()'), isTrue,
          reason:
              'app_model 未经 extensionPopupEffectiveSize 生成弹窗高度变量（应源自用户配置尺寸）');
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
    test('action-popup.js', () {
      expect(assetsActionPopup.readAsBytesSync(),
          toolsActionPopup.readAsBytesSync(),
          reason: 'action-popup.js 两份镜像不一致');
    });
  });
}
