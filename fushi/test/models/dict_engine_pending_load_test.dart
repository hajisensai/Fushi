// 词典引擎「排期 + 用前结算」的行为测试。
//
// 背景（用户报告：一次性导入很多词典后，点开 app 转圈转一半自己退出）。这一层修
// 的是两个与词典数量成正比的启动成本：
//
//   * 旧实现里每写一次词典元数据就**就地全量重建**引擎——卸掉所有词典的文件映射
//     再逐本装回来。写元数据是逐本发生的（导入每本、启动期类型自愈每本），于是
//     总代价是 O(N²)：导第 100 本要把前 99 本卸了再装回去。
//   * 装载是同步 FFI，一口气装完 N 本期间主 isolate 完全不动，连 Timer 都不触发，
//     于是 AppModel 的 12 秒启动超时和 main.dart 的 20 秒逃生 UI 双双失效——两层
//     看门狗都是 Timer。用户看到的就是一直转圈、没有任何逃生口。
//
// 这里测的是引擎侧的状态机（不碰真 FFI：装载动作只在结算时才发生，而结算需要
// native 库；所以断言集中在「什么时候算有待办、待办怎么合并、代次怎么作废」这些
// 纯 Dart 的不变式上）。装载本身的正确性由 native ctest 覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

void main() {
  tearDown(() {
    // 每条用例后清干净静态状态，别让待办漏给下一条。
    FushiDicts.dropPendingForTest();
  });

  group('scheduleTyped 只排期、不装载', () {
    test('排期后有待办，且没有立刻装载', () {
      FushiDicts.scheduleTyped(termPaths: <String>['/nonexistent/a']);
      expect(FushiDicts.hasPendingDicts, isTrue, reason: '排期必须留下待办，否则结算时机无从判断');
    });

    test('连续排期只保留最后一次（批量写入的 N 次塌成 1 次装载）', () {
      // 这正是 O(N²) 消失的地方：中间那些集合从没被任何人观察到。
      for (int i = 0; i < 50; i++) {
        FushiDicts.scheduleTyped(termPaths: <String>['/nonexistent/$i']);
      }
      expect(FushiDicts.hasPendingDicts, isTrue);
      expect(FushiDicts.debugPendingTermPathsForTest(),
          equals(<String>['/nonexistent/49']),
          reason: '只有最后一次意图应该存活');
    });

    test('空集合同样要排期（删掉最后一本词典必须让引擎变空，BUG-171）', () {
      FushiDicts.scheduleTyped();
      expect(FushiDicts.hasPendingDicts, isTrue,
          reason: '空集合被当成「没事发生」的话，删完最后一本词典后旧索引还在，'
              '查词仍会命中已删词典');
      expect(FushiDicts.debugPendingTermPathsForTest(), isEmpty);
    });
  });

  group('待办的清除时机', () {
    test('releaseAllMappings 连待办一起清', () {
      // 删词典目录前要释放映射；此时若把待办留着，删完目录后任何一次查词都会把
      // 「含已删词典」的那份排期重放回引擎——映射又长回来，目录也就删不掉了。
      FushiDicts.scheduleTyped(termPaths: <String>['/nonexistent/a']);
      FushiDicts.releaseAllMappings();
      expect(FushiDicts.hasPendingDicts, isFalse);
    });

    test('disposeInstance 也清待办', () {
      FushiDicts.scheduleTyped(termPaths: <String>['/nonexistent/a']);
      FushiDicts.disposeInstance();
      expect(FushiDicts.hasPendingDicts, isFalse);
    });
  });

  group('isInitialized 覆盖「已排期但还没装」', () {
    test('只排期也算已初始化', () {
      FushiDicts.disposeInstance();
      expect(FushiDicts.isInitialized, isFalse);
      FushiDicts.scheduleTyped(termPaths: <String>['/nonexistent/a']);
      expect(FushiDicts.isInitialized, isTrue,
          reason: '待办本身就说明集合已知，调用方接着会经 instance 触发结算；'
              '这里判 false 会让查词走「引擎没准备好」的空结果分支');
    });
  });
}
