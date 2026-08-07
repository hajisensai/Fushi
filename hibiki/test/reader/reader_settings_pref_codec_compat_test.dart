import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1116 守卫：ReaderSettings 读侧必须兼容 PrefCodec 类型标签值。
///
/// 同一 `src:reader_ttu:*` DB key 有两个历史写入方：
/// - ReaderSettings._set → 裸 `toString()`（'false' / '22.0'）；
/// - ReaderHibikiSource 在 `readerSettings == null` 窗口的
///   `?? setPreference(...)` 回退 → PrefCodec 标签值（'b:false' / 'd:22.0'）。
///
/// 修复前 ReaderSettings._parseValue 只认裸值：读到标签值时 bool/int/double
/// 静默回落默认（用户偏好丢失），String 更糟——整串 's:xxx' 被当值吃进（污染）。
/// 修复后 _parseValue 委托 PrefCodec.decodeUntyped（严格超集：标签 + 裸值都认，
/// 裸值分支与旧启发式逐行等价）。
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = _testDb();
    MediaSource.setDatabase(db);
    ReaderHibikiSource.readerSettings = null;
  });

  tearDown(() async {
    ReaderHibikiSource.readerSettings = null;
    await db.close();
  });

  test('(a) 回退路径双写复现：setReaderFontSize 落标签值，ReaderSettings 重启后必须读回', () async {
    // readerSettings == null → 走 MediaSource.setPreference 回退，
    // 落 PrefCodec 标签值到 ReaderSettings 的同一 DB key。
    await ReaderHibikiSource.instance.setReaderFontSize(30);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_ttu:ttu_font_size'], 'd:30.0',
        reason: '回退路径写 PrefCodec 标签值（复现双编码前提）');

    // 模拟重启：新 ReaderSettings 实例从 DB 加载。修复前 _parseValue 不认
    // 'd:30.0' → fontSize 回落默认 22；修复后必须读回 30。
    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();
    expect(restored.fontSize, 30.0,
        reason: '标签 double 值必须被 ReaderSettings 读回（修复前丢为默认 22）');
  });

  test('(b) bool 标签值：b:false → showTopProgressBar == false', () async {
    await db.setPref('src:reader_ttu:show_top_progress_bar', 'b:false');

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(settings.showTopProgressBar, isFalse,
        reason: '修复前标签 bool 解析失败回落默认 true');
  });

  test('(c) int 标签值：i:600 → wheelPageTurnInterval == 600', () async {
    await db.setPref('src:reader_ttu:wheel_page_turn_interval', 'i:600');

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(settings.wheelPageTurnInterval, 600,
        reason: '修复前标签 int 解析失败回落默认 450');
  });

  test('(d) String 标签值：s:horizontal-tb → writingMode 不吃进污染串', () async {
    await db.setPref('src:reader_ttu:ttu_writing_mode', 's:horizontal-tb');

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(settings.writingMode, 'horizontal-tb',
        reason: '修复前整串 "s:horizontal-tb" 被当值采纳（类型匹配不回落）');
  });

  test('(e) 旧裸值行为不回归：26.5 / false / vertical-rl 逐值不变', () async {
    await db.setPref('src:reader_ttu:ttu_font_size', '26.5');
    await db.setPref('src:reader_ttu:show_top_progress_bar', 'false');
    await db.setPref('src:reader_ttu:ttu_writing_mode', 'vertical-rl');

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(settings.fontSize, 26.5, reason: '裸 double 与修复前一致');
    expect(settings.showTopProgressBar, isFalse, reason: '裸 bool 与修复前一致');
    expect(settings.writingMode, 'vertical-rl', reason: '裸 String 与修复前一致');
  });

  test('(f) z: 显式 null 标签 → 回落默认值不崩', () async {
    await db.setPref('src:reader_ttu:ttu_font_size', 'z:');
    await db.setPref('src:reader_ttu:show_top_progress_bar', 'z:');

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(settings.fontSize, 22.0, reason: 'null 解码结果类型不符 → 默认 22');
    expect(settings.showTopProgressBar, isTrue, reason: 'null → 默认 true');
  });
}
