# Hibiki 椤圭洰娣卞害璐ㄩ噺瀹℃煡鎶ュ憡

**鏃ユ湡**: 2026-05-21
**瀹℃煡鑼冨洿**: 鍏ㄤ唬鐮佸簱 鈥?鏋舵瀯銆佸疄鐜般€佸伐绋嬭鑼冦€佸畨鍏ㄣ€佹€ц兘銆佸彲缁存姢鎬?
**瀹℃煡鏂规硶**: 6 璺苟琛屾繁搴︽壂鎻?+ 鏍稿績鏂囦欢閫愯瀹¤
**浠ｇ爜搴撹妯?*: ~200 Dart 鏂囦欢 / ~85K 琛岋紙涓诲簲鐢級+ 118 鏂囦欢锛坧ackages锛?
---

## 绗竴杞細鍏ㄥ眬鏋舵瀯涓庤嚧鍛介闄?
### Scope

鍏ㄤ唬鐮佸簱鏋舵瀯灞傞潰鎵弿锛歚app_model.dart`銆佹暟鎹簱灞傘€侀槄璇诲櫒 WebView銆佸瓧鍏?FFI銆丆reator/Anki銆佸紓姝?閿欒澶勭悊妯″紡銆?
---

## Findings

---

### HBK-AUDIT-001 鈥?AppModel 涓婂笣瀵硅薄

**Severity**: 馃敶 CRITICAL
**Status**: open
**鏂囦欢**: `hibiki/lib/src/models/app_model.dart` (4,045 琛?

**鏍瑰洜**: `AppModel` 鏄竴涓吀鍨嬬殑涓婂笣瀵硅薄锛圙od Object锛夛紝鍗曚釜 `ChangeNotifier` 鎵胯浇浜嗘暣涓簲鐢ㄧ殑鎵€鏈夊叏灞€鐘舵€侊細

| 鑱岃矗 | 琛屾暟浼扮畻 |
|------|----------|
| 涓婚/棰滆壊瀹氬埗 | ~300 琛?|
| 鍋忓ソ瀛樺彇锛?0+ getter/setter 瀵癸級 | ~600 琛?|
| 瀛楀吀绠＄悊锛堝鍏?鎺掑簭/鎼滅储/鍘嗗彶锛?| ~800 琛?|
| 濯掍綋婧愮鐞?| ~300 琛?|
| 鍒濆鍖?杩佺Щ | ~300 琛?|
| 涔︽灦/MediaItem 缂撳瓨 | ~200 琛?|
| 闊抽/TTS/鏈夊０涔︽ˉ鎺?| ~200 琛?|
| 瀵煎嚭/鏂囦欢绠＄悊 | ~200 琛?|
| Profile 绯荤粺 | ~100 琛?|
| 鍗＄墖鍒涘缓杈呭姪 | ~150 琛?|
| 鏉傞」 | ~800 琛?|

**鍏抽敭鎸囨爣**:
- 31 涓?`late final` 澹版槑 鈥?涓ユ牸渚濊禆鍒濆鍖栭『搴?- 54 娆?`notifyListeners()` 璋冪敤 鈥?浠讳綍灞炴€у彉鏇撮兘瑙﹀彂鍏ㄦ爲閲嶅缓
- 28 涓?`catch` 鍧楋紝鍏朵腑 3 涓?`catch (_) {}` 瀹屽叏鍚炲櫖寮傚父
- 10 涓?`dynamic` 绫诲瀷浣跨敤

**褰卞搷**:
1. **鎬ц兘**: 鏀逛竴涓亸濂藉氨 `notifyListeners()` 鈫?鍏ㄩ儴 `Consumer<AppModel>` 閲嶅缓锛屽寘鎷笌璇ュ亸濂芥棤鍏崇殑 widget
2. **鍙祴璇曟€?*: 鏃犳硶鍗曠嫭娴嬭瘯瀛楀吀閫昏緫銆佷富棰橀€昏緫銆佸亸濂介€昏緫 鈥?蹇呴』瀹炰緥鍖栨暣涓?AppModel
3. **骞跺彂瀹夊叏**: 澶氫釜寮傛鏂规硶鍚屾椂淇敼 `_prefCache`銆乣_dictionariesCache`銆乣_mediaItemsCache` 绛夊叡浜彲鍙樼姸鎬侊紝鏃犻攣鏃犲悓姝?4. **鐢熷懡鍛ㄦ湡**: 31 涓?`late final` 濡傛灉鍒濆鍖栭『搴忔墦涔?鈫?`LateInitializationError` 宕╂簝锛屼笖閿欒淇℃伅鏃犳硶瀹氫綅鏄摢涓瓧娈?
**淇寤鸿**: 鎷嗗垎涓虹嫭绔嬬殑 Riverpod Provider/Notifier锛?- `ThemeNotifier` 鈥?涓婚/棰滆壊
- `PreferencesRepository` 鈥?鍋忓ソ璇诲啓锛堝彲娉ㄥ叆 mock DB锛?- `DictionaryRepository` 鈥?瀛楀吀 CRUD + 鎼滅储
- `MediaHistoryRepository` 鈥?濯掍綋鍘嗗彶
- `ProfileRepository`锛堝凡瀛樺湪锛岄渶瀹屽叏瑙ｈ€︼級

**楠岃瘉鏂瑰紡**: 鎷嗗垎鍚庡崟鍏冩祴璇曟瘡涓?Repository锛岄獙璇?`notifyListeners` 绮剧‘鍒板瓙妯″潡銆?
---

### HBK-AUDIT-002 鈥?闃呰鍣ㄧ姸鎬佹満绔炴€佹潯浠讹紙浣嶇疆淇濆瓨 vs 瀵艰埅锛?
**Severity**: 馃敶 CRITICAL
**Status**: open
**鏂囦欢**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2189-2551`

**鏍瑰洜**: 浣嶇疆淇濆瓨浣跨敤 500ms debounce Timer锛屽鑸搷浣滅洿鎺ヤ慨鏀?`_currentChapter`锛屼袱鑰呮棤鍚屾鏈哄埗銆?
**绔炴€佸満鏅?*:
1. 鐢ㄦ埛鍦ㄧ 3 绔?50% 浣嶇疆锛宒ebounce timer 寰呰Е鍙?2. 鐢ㄦ埛蹇€熻烦杞埌绗?5 绔?3. `_currentChapter = 5`锛宍_initialProgress` 鏇存柊
4. 500ms 鍚?timer 瑙﹀彂 `_persistPosition()`锛屼娇鐢ㄥ凡琚慨鏀圭殑 `_currentChapter`
5. 浣嶇疆琚敊璇繚瀛樹负绗?5 绔狅紙鐢ㄦ埛鍙槸鐭殏缁忚繃锛?
**褰卞搷**: 鐢ㄦ埛闃呰浣嶇疆涓㈠け锛屼笅娆℃墦寮€涔︾洿鎺ヨ烦鍒伴敊璇珷鑺傘€?
**淇寤鸿**: 鍦?`_debouncedSaveReaderPosition` 涓崟鑾峰綋鍓?section 鍜?progress 鍒伴棴鍖呭眬閮ㄥ彉閲忥紝鑰岄潪渚濊禆瀹炰緥鍙橀噺銆?
---

### HBK-AUDIT-003 鈥?WebView Controller 鐢熷懡鍛ㄦ湡绔炴€?
**Severity**: 馃敶 CRITICAL
**Status**: open
**鏂囦欢**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:1091-1130`

**鏍瑰洜**: `_applyStylesLive()` 绛夋柟娉曞厛妫€鏌?`_controller != null`锛岀劧鍚庢墽琛屽涓?`await`锛屾湡闂?`dispose()` 鍙兘琚皟鐢ㄣ€?
```
_applyStylesLive() 寮€濮?鈫?_controller != null 鉁?    鈫?await _syncSettingsFromHive() (100+ ms)
        鈫?鐢ㄦ埛杩斿洖 鈫?dispose() 琚皟鐢?鈫?_controller 澶辨晥
    鈫?_controller!.evaluateJavascript() 鈫?CRASH
```

**褰卞搷**: 鐢ㄦ埛蹇€熼€€鍑洪槄璇诲櫒鏃跺穿婧冦€?
**淇寤鸿**: 鎵€鏈?`evaluateJavascript()` 璋冪敤鍖呰９ try-catch 鎹曡幏 `PlatformException`锛坈ontroller disposed锛夛紝鎴栧湪姣忎釜 await 鐐瑰悗閲嶆柊妫€鏌?`mounted && _controller != null`銆?
---

### HBK-AUDIT-004 鈥?JavaScript 妯℃澘瀛楃涓茶浆涔変笉瀹屾暣

**Severity**: 馃敶 HIGH
**Status**: open
**鏂囦欢**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:1113-1129`

**鏍瑰洜**: CSS 娉ㄥ叆鍒?JS 妯℃澘瀛楃涓叉椂鍙浆涔変簡 `\`, `` ` ``, `$`锛屼絾鏈鐞?`${}` 妯″紡銆?
```dart
final String escaped = css
    .replaceAll('\\', '\\\\')
    .replaceAll('`', '\\`')
    .replaceAll('\$', '\\\$');
// 娉ㄥ叆鍒? el.textContent = `$escaped`;
```

濡傛灉 CSS 鍖呭惈 `${...}` 褰㈠紡鐨勫唴瀹癸紙铏界劧涓嶅父瑙侊紝浣嗚嚜瀹氫箟 CSS 鐢ㄦ埛鍙緭鍏ワ級锛屽彲鑳藉鑷?JS 鎵ц銆?
**褰卞搷**: 鑷畾涔?CSS 鍔熻兘瀛樺湪 XSS 椋庨櫓锛堣櫧鐒舵槸鏈湴 WebView锛岄潪杩滅▼鏀诲嚮闈紝浣嗕粛鍙鑷撮槄璇诲櫒琛屼负寮傚父锛夈€?
**淇寤鸿**: 浣跨敤 `JSON.encode(css)` 鐢熸垚瀹夊叏瀛楃涓诧紝鎴栫敤 Blob URL 鏇夸唬妯℃澘瀛楃涓叉敞鍏ャ€?
---

### HBK-AUDIT-005 鈥?瀛楀吀 ZIP 瑙ｅ帇鏃犲唴瀛橀檺鍒?
**Severity**: 馃敶 HIGH
**Status**: open
**鏂囦欢**: `packages/hibiki_dictionary/lib/src/formats/yomichan_dictionary_format.dart:120-145`

**鏍瑰洜**: Dart fallback 瑙ｅ帇璺緞 `writeAsBytesSync(file.content as List<int>)` 灏嗘暣涓枃浠跺唴瀹瑰姞杞藉埌鍐呭瓨銆?
**褰卞搷**: 瀵煎叆 1GB+ 瀛楀吀 ZIP 鏃?RAM 宄板€?2GB+锛屼腑绔墜鏈虹洿鎺?OOM 宕╂簝銆?
**淇寤鸿**: 鏀圭敤娴佸紡瑙ｅ帇锛屾垨鑷冲皯鍦ㄨВ鍘嬪墠妫€鏌?`uncompressedSize` 骞舵嫆缁濊秴闄愭枃浠躲€?
---

### HBK-AUDIT-006 鈥?C++ 瀵煎叆鍣ㄦ棤璧勬簮涓婇檺

**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `native/hoshidicts/hoshidicts_src/importer.cpp:200-250`

**鏍瑰洜**: 鏃犳渶澶ф潯鐩暟銆佹渶澶ф潯鐩ぇ灏忋€佹渶澶у瓧鍏告€诲ぇ灏忛檺鍒躲€俫lossary 鍜?frequency 鏁扮粍鏃犵晫銆?
**褰卞搷**: 鎭舵剰鏋勯€犵殑瀛楀吀 ZIP 鍙€氳繃娴烽噺鏉＄洰瑙﹀彂 OOM銆?
**淇寤鸿**: 娣诲姞纭檺鍒讹細鍗曟枃浠舵渶澶?100K 鏉＄洰锛屽崟鏉＄洰 expression 鏈€澶?64KB锛岄鐜囨潯鐩渶澶?1000/term銆?
---

### HBK-AUDIT-007 鈥?闃呰鍣ㄥ鏍囧織鐘舵€佹満锛堥潪鍘熷瓙锛?
**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:1467-1617`

**鏍瑰洜**: 闃呰鍣ㄤ娇鐢ㄥ涓嫭绔嬪竷灏旀爣蹇楃鐞嗙姸鎬侊細`_readerContentReady`銆乣_hasEverLoaded`銆乣_restoreInFlight`銆乣_restoreExpectedGeneration`銆傝繖浜涙爣蹇椾箣闂存病鏈夊師瀛愭€т繚璇併€?
蹇€熷鑸満鏅細
1. 鍔犺浇绗?1 绔?(gen=1) 鈫?璁剧疆 `_restoreExpectedGeneration=1`
2. 蹇€熻烦杞 2 绔?(gen=2) 鈫?璁剧疆 `_restoreExpectedGeneration=2`
3. 绗?1 绔犵殑 `onLoadStop` 瑙﹀彂 (gen=1)锛屼絾 generation 涓嶅尮閰?鈫?闈欓粯璺宠繃
4. 杩涘害杞鍦ㄩ敊璇姸鎬佷笅鍚姩/鍋滄

**褰卞搷**: 蹇€熷鑸椂杩涘害杞涓嶇ǔ瀹氾紝鍙兘瀵艰嚧绔犺妭鍐呬綅缃笉鍑嗙‘銆?
**淇寤鸿**: 鐢ㄦ灇涓剧姸鎬佹満鏇夸唬澶氬竷灏旀爣蹇楋細
```dart
enum ReaderState { idle, loading, restoring, ready, error }
```

---

### HBK-AUDIT-008 鈥?Stream/Timer 璧勬簮娉勬紡椋庨櫓

**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2756-2773`

**鏍瑰洜**: `_subscribeNotificationStreams()` 姣忔琚皟鐢ㄦ椂鍒涘缓鏂拌闃咃紝浣嗗鏋?`_initAudioFeatures()` 琚娆¤皟鐢紙琛?667, 749锛夛紝鏃ц闃呯殑 `ctrl` 闂寘寮曠敤琚硠婕忋€?
鍏ㄥ眬缁熻锛?- 15 澶?`catch (_) {}` 瀹屽叏鍚炲櫖寮傚父锛堣瑙侀檮褰?A锛?- 10 澶?`StreamSubscription` 澹版槑锛岄儴鍒嗙己灏戝搴?`cancel()`
- `reader_hoshi_page.dart` 涓?4 澶?`catch (_) {}` 鈥?闃呰鍣ㄦ渶鍏抽敭璺緞涓婄殑闈欓粯澶辫触

**淇寤鸿**: 鍦ㄩ噸鏂拌闃呭墠鏂█鏃ц闃呭凡鍙栨秷銆傛坊鍔?`@mustCallSuper` dispose 妫€鏌ャ€?
---

### HBK-AUDIT-009 鈥?Creator/Anki 澶ц妯′唬鐮侀噸澶?
**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: 澶氭枃浠?
**閲嶅娓呭崟**:

| 閲嶅鍖哄煙 | 鏂囦欢 | 閲嶅琛屾暟 |
|----------|------|----------|
| AudioField 鈫?AudioSentenceField | `fields/audio_field.dart`, `fields/audio_sentence_field.dart` | **300+ 琛?(95%鐩稿悓)** |
| AnkiConnect 鈫?AnkiDroid `mineEntry()` | `ankiconnect_repository.dart`, `anki_repository.dart` | **100+ 琛?(90%鐩稿悓)** |
| 3 涓?Cloze 瀛楁 | `cloze_before_field.dart`, `cloze_after_field.dart`, `cloze_inside_field.dart` | **~40 琛岀粨鏋勭浉鍚?* |
| 3 涓?Meaning 鍙樹綋瀛楁 | `collapsed_meaning_field.dart`, `expanded_meaning_field.dart`, `hidden_meaning_field.dart` | **~45 琛岄€昏緫鐩稿悓** |
| PickImage 鈫?PickAudio 澧炲己 | `pick_image_enhancement.dart`, `pick_audio_enhancement.dart` | **~70 琛屾ā寮忕浉鍚?* |

**鎬昏**: ~555+ 琛屽彲娑堥櫎鐨勯噸澶嶃€?
**褰卞搷**: 淇涓€涓?bug 闇€瑕佸湪 2-3 涓枃浠朵腑鍚屾淇敼銆侫udioField 鍜?AudioSentenceField 灏ゅ叾鍗遍櫓 鈥?375 琛屽嚑涔庣浉鍚岀殑浠ｇ爜锛屼换浣曢煶棰戞挱鏀惧櫒鐨?bug 淇閮藉繀椤诲仛涓ゆ銆?
**淇寤鸿**:
1. 鎻愬彇 `AudioPlayerField` 鍩虹被锛孉udioField 鍜?AudioSentenceField 鍙繚鐣欐瀯閫犲嚱鏁板樊寮?2. 灏?`mineEntry()` 閫氱敤閫昏緫涓婃彁鍒?`BaseAnkiRepository`
3. Cloze 瀛楁鏀逛负鍙傛暟鍖栧伐鍘?
---

### HBK-AUDIT-010 鈥?鍋忓ソ绯荤粺绫诲瀷涓嶅畨鍏ㄧ殑瀛楃涓插簭鍒楀寲

**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `hibiki/lib/src/media/media_source.dart:110-137`, `packages/hibiki_core/lib/src/database/database.dart:246-253`

**鏍瑰洜**: 鎵€鏈夊亸濂藉€奸€氳繃 `value.toString()` 瀛樺偍锛岃鍙栨椂閫氳繃鍚彂寮忕寽娴嬫仮澶嶇被鍨嬶細

```dart
if (raw == 'true') 鈫?bool
else if (int.tryParse(raw) != null) 鈫?int
else if (double.tryParse(raw) != null) 鈫?double
else 鈫?String
```

**闂鍦烘櫙**:
- 瀛楃涓插€?`"123"` 琚弽搴忓垪鍖栦负 `int 123`
- 瀛楃涓插€?`"true"` 琚弽搴忓垪鍖栦负 `bool true`
- `double` 鍊?`1.0` 缁?`toString()` 鍚庡彉涓?`"1.0"`锛岃鍥炴槸 `double`锛屼絾 `1` 鍙樹负 `int`

**褰卞搷**: 绫诲瀷婕傜Щ瀵艰嚧 `getPreference<T>` 鍦ㄨ繍琛屾椂绫诲瀷妫€鏌ュけ璐ワ紝闈欓粯杩斿洖 `defaultValue`锛岀敤鎴疯缃涪澶变絾涓嶆姤閿欍€?
**淇寤鸿**: 瀛樺偍鏃堕檮甯︾被鍨嬫爣璁帮紝濡?`"b:true"`, `"i:123"`, `"d:1.0"`, `"s:123"` 鎴栦娇鐢?JSON銆?
---

### HBK-AUDIT-011 鈥?CI/CD 缂哄け鍏抽敭鐜妭

**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `.github/workflows/main.yml`

**鐜扮姸**:
- 鉁?`flutter analyze`
- 鉁?`flutter test`锛?06 涓崟鍏冩祴璇曟枃浠?/ ~8,300 琛岋級
- 鉂?鍙瀯寤?**debug** APK锛屼笉鏋勫缓 release
- 鉂?鏃犱唬鐮佽鐩栫巼鎶ュ憡
- 鉂?鏃犻泦鎴愭祴璇曪紙4 涓泦鎴愭祴璇曟枃浠舵湭鍦?CI 杩愯锛?- 鉂?鏃?release signing 楠岃瘉
- 鉂?鏃?dependency audit / vulnerability scan

**褰卞搷**: release-only 鐨?bug锛堝 tree-shaking 绉婚櫎琚弽灏勫紩鐢ㄧ殑浠ｇ爜銆丳roGuard 闂锛夊湪 CI 涓嶄細琚崟鑾枫€?
**淇寤鸿**: 娣诲姞 `flutter build apk --release`锛堥渶瑕?CI 涓婇厤缃鍚嶅瘑閽ワ級锛屾坊鍔?`flutter test --coverage`锛屾坊鍔?`dart pub outdated` 妫€鏌ャ€?
---

### HBK-AUDIT-012 鈥?鏁版嵁搴撻檷绾х瓥鐣ユ槸鍏ㄥ垹閲嶅缓

**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `packages/hibiki_core/lib/src/database/database.dart:73-80`

```dart
if (from > to) {
  for (final table in allTables) {
    await customStatement(
      'DROP TABLE IF EXISTS "${table.actualTableName}"',
    );
  }
  await m.createAll();
  return;
}
```

**鏍瑰洜**: schema 鐗堟湰闄嶇骇鏃讹紙濡傜敤鎴峰畨瑁呮棫鐗堟湰 APK锛夛紝鐩存帴 DROP ALL TABLES 閲嶅缓銆?
**褰卞搷**: 鐢ㄦ埛鍥為€€鐗堟湰鍚?**鎵€鏈夋暟鎹涪澶?* 鈥?涔︽灦銆侀槄璇讳綅缃€佸瓧鍏稿巻鍙层€佸亸濂藉叏娌′簡銆傛病鏈夎鍛婏紝娌℃湁澶囦唤銆?
**淇寤鸿**: 闄嶇骇鏃惰嚦灏戝厛澶囦唤 `hibiki.db` 涓?`hibiki.db.bak.{version}`锛屾垨鎷掔粷闄嶇骇骞舵彁绀虹敤鎴枫€?
---

### HBK-AUDIT-020 鈥?CreatorModel 鏃?dispose()锛堝唴瀛樻硠婕忥級

**Severity**: 馃敶 CRITICAL
**Status**: open
**鏂囦欢**: `hibiki/lib/src/models/creator_model.dart:27-42`

**鏍瑰洜**: `CreatorModel` 缁ф壙 `ChangeNotifier` 浣?*娌℃湁瀹炵幇 `dispose()` 鏂规硶**銆?
瀹炰緥鍐呮寔鏈夛細
- ~20 涓?`TextEditingController`锛堟瘡涓?Field 涓€涓級
- ~20 涓?`ValueNotifier<bool>`锛堥攣瀹氱姸鎬侊級
- 1 涓?`ScrollController`

杩欎簺鎺у埗鍣ㄥ湪 `CreatorModel` 琚?Riverpod `ChangeNotifierProvider` 閿€姣佹椂涓嶄細琚竻鐞嗐€?
**褰卞搷**: 姣忔 Provider 閲嶅缓閮芥硠婕?~40 涓?Flutter 鎺у埗鍣ㄥ璞°€傝櫧鐒?Provider 涓嶉绻侀噸寤猴紝浣嗚繖鏄‘瀹氭€х殑鍐呭瓨娉勬紡銆?
**淇寤鸿**:
```dart
@override
void dispose() {
  scrollController.dispose();
  for (final c in _controllersByField.values) c.dispose();
  for (final n in _lockNotifiersByField.values) n.dispose();
  super.dispose();
}
```

---

### HBK-AUDIT-021 鈥?鏁版嵁搴撶己灏戝叧閿煡璇㈢储寮?
**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `packages/hibiki_core/lib/src/database/database.dart`

**鐜扮姸**: 鍙湁 4 涓嚜瀹氫箟绱㈠紩锛? 涓?profile 鐩稿叧 + 1 涓?bookmarks锛夈€?
**缂哄け绱㈠紩**:
- `media_items.media_type_identifier` 鈥?`getMediaItemsByType()` 鍏ㄨ〃鎵弿
- `media_items.media_source_identifier` 鈥?`getMediaItemsBySource()` 鍏ㄨ〃鎵弿
- `audio_cues.book_uid` 鈥?cue 鏌ヨ鍏ㄨ〃鎵弿
- `search_history_items.history_key` 鈥?鎼滅储鍘嗗彶鏌ヨ鍏ㄨ〃鎵弿

**褰卞搷**: 鏁版嵁閲忓皯鏃朵笉鏄庢樉锛屼絾 media_items 鍜?audio_cues 闅忎娇鐢ㄥ闀匡紝鏌ヨ鎬ц兘浼氱嚎鎬ч€€鍖栥€?
---

### HBK-AUDIT-022 鈥?5 灞傚亸濂界紦瀛橈紝鏃犲け鏁堟満鍒?
**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `app_model.dart:216`, `media_source.dart:92`, `database.dart:234`

**鐜扮姸**: 鍋忓ソ鏁版嵁瀛樺湪 5 涓嫭绔嬪瓨鍌?缂撳瓨灞傦細

| 灞?| 浣嶇疆 | 鍚屾鏈哄埗 |
|----|------|----------|
| 1. Drift `preferences` 琛?| `database.dart` | 鍦伴潰鐪熺浉 |
| 2. AppModel `_prefCache` | `app_model.dart:216` | 鍚姩鍔犺浇涓€娆★紝`_setPref` 鍚屾鏇存柊 |
| 3. MediaSource `_preferences` | `media_source.dart:92` | 姣忎釜 source 鐙珛缂撳瓨锛屽垵濮嬪寲鏃跺姞杞?|
| 4. Profile `profile_settings` 琛?| `database.dart` | 鐙珛琛紝涓嶈蛋 `_prefCache` |
| 5. SharedPreferences | `ttu_migration.dart` | 浠呰縼绉荤敤 |

**闂**: `_setPref()` 鏇存柊灞?1 鍜屽眰 2锛屼絾涓嶈Е鍙戝眰 3 鐨?`MediaSource._preferences` 鏇存柊銆侾rofile 鍒囨崲闇€瑕佹墜鍔ㄨ皟鐢?`refreshPreferencesFromDb()`锛屽鏋滈仐婕忥紝source 璇诲埌鏃у亸濂姐€?
---

### HBK-AUDIT-023 鈥?鏁版嵁搴撴煡璇㈢己灏戝叧閿簨鍔″寘瑁?
**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `packages/hibiki_core/lib/src/database/database.dart`

**闂**: `deleteEpubBook` 鎵ц 3 涓?DELETE 鎿嶄綔浣嗘棤鏄惧紡浜嬪姟锛?
```dart
await _database.deleteMediaItemByUniqueKey(item.uniqueKey);
await _database.upsertMediaItem(_mediaItemToCompanion(item));
await _database.trimMediaHistory(...);
```

濡傛灉涓棿姝ラ澶辫触锛屾暟鎹簱澶勪簬涓嶄竴鑷寸姸鎬併€傝縼绉?v10/v12 鐨?orphan cleanup 鍚屾牱鏈寘瑁瑰湪浜嬪姟涓€?
---

### HBK-AUDIT-025 鈥?闃呰鍣?_initBook() fire-and-forget + 寮傛闂撮殭缂?mounted 妫€鏌?
**Severity**: 馃敶 CRITICAL
**Status**: open
**鏂囦欢**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:155, 220-294`

**鏍瑰洜**: `_initBook()` 鍦?`initState()` 涓璋冪敤浣嗕笉 await銆傝鏂规硶鍐呴儴鏈?10+ 涓?`await` 鐐癸紙`_resolveAndApplyProfile`銆乣EpubStorage` 鎿嶄綔銆乣_resolveAudioSlot` 绛夛級锛屽叾闂村彧鍦ㄦ渶鏈熬锛堣 296锛夊仛浜?`if (mounted)` 妫€鏌ャ€?
```dart
@override
void initState() {
  super.initState();
  _initBook();  // 鈫?fire-and-forget, 鏃?await
}

Future<void> _initBook() async {
  // 10+ await 鎿嶄綔...
  // 琛?220-294: 澶ч噺鐘舵€佷慨鏀癸紝鏃?mounted 妫€鏌?  if (mounted) { setState(() {}); }  // 鈫?浠呮渶鍚庢鏌?}
```

**褰卞搷**: 濡傛灉鐢ㄦ埛鍦ㄩ槄璇诲櫒鍒濆鍖栬繃绋嬩腑蹇€熻繑鍥烇紙dispose 琚皟鐢級锛屼腑闂寸殑 `await` 鎭㈠鍚庝細淇敼宸查噴鏀剧殑 widget 鐘舵€?鈫?`setState() called after dispose()` 宕╂簝銆?
**淇寤鸿**: 鍦ㄦ瘡涓?`await` 涔嬪悗娣诲姞 `if (!mounted) return;` 瀹堝崼锛屾垨灏嗘暣涓垵濮嬪寲閫昏緫鎻愬彇鍒伴潪 Widget 鐨?Controller 涓€?
---

### HBK-AUDIT-024 鈥?911 涓?null assertion (`!`) 鍒嗗竷鍏ㄤ唬鐮?
**Severity**: 馃煝 LOW
**Status**: open
**鏂囦欢**: 鍏ㄤ唬鐮佸簱

**缁熻**:
- 911 涓?`!` null assertion
- 573 涓?`as` 绫诲瀷杞崲
- 66 涓枃浠朵娇鐢?`dynamic` 鍏抽敭瀛?
**鐑偣**: `reader_hoshi_page.dart` 鍜?`audiobook_controller.dart` 涓?`!` 瀵嗗害鏈€楂樸€俙ttu_migration.dart` 涓?`as` 杞崲鏈€瀵嗛泦锛?3 澶勶紝閬楃暀 JSON 澶勭悊锛屽彲鎺ュ彈锛夈€?
**褰卞搷**: null assertion 澶辫触浼氬鑷?`TypeError` 宕╂簝锛屼笖閿欒淇℃伅鍙樉绀?`Null check operator used on a null value`锛屾棤娉曞畾浣嶆槸鍝釜鍙橀噺銆備絾澶ч儴鍒嗕娇鐢ㄥ満鏅湁閫昏緫淇濊瘉闈?null锛屽睘浜?Dart 绫诲瀷绯荤粺鐨勪娇鐢ㄤ範鎯€?
---

### HBK-AUDIT-013 鈥?`jidoujisho` 閬楃暀鍛藉悕涓?`hibiki` 娣锋潅

**Severity**: 馃煝 LOW
**Status**: open
**鏂囦欢**: 鍏ㄤ唬鐮佸簱

**鐜扮姸**: UI 缁勪欢灞備娇鐢?`Jidoujisho*` 鍓嶇紑锛堝 `JidoujishoBottomSheet`銆乣JidoujishoDropdown`銆乣JidoujishoSelectableText` 绛?8+ 涓枃浠讹級锛屾暟鎹ā鍨嬩娇鐢?`JidoujishoTextSelection`锛岃€屽簲鐢ㄥ眰浣跨敤 `Hibiki*`/`Hoshi*` 鍓嶇紑銆?
**褰卞搷**: 鏂拌础鐚€呭洶鎯戯紝涓や釜鍛藉悕绌洪棿鐨勮涔夎竟鐣屼笉娓呮櫚銆備笉褰卞搷鍔熻兘锛屼絾褰卞搷浠ｇ爜鑰冨彜鏁堢巼銆?
**淇寤鸿**: 浣庝紭鍏堢骇銆傚湪涓嬩竴娆℃秹鍙婅繖浜涚粍浠剁殑閲嶆瀯鏃剁粺涓€鍛藉悕銆?
---

### HBK-AUDIT-014 鈥?EPUB 瀵煎叆鍐呭瓨宄板€?
**Severity**: 馃煛 MEDIUM
**Status**: open
**鏂囦欢**: `hibiki/lib/src/epub/epub_parser.dart:98-121`, `epub_importer.dart:138`

**鏍瑰洜**: `readAsBytes()` 灏嗘暣涓?EPUB 鍔犺浇鍒板唴瀛橈紝鐒跺悗浼犵粰 compute isolate锛?
```dart
final Uint8List bytes = await file.readAsBytes();  // 鍏ㄩ噺璇诲彇
return import(db: db, bytes: bytes, ...);           // 浼犵粰 isolate
```

**褰卞搷**: 500MB EPUB 瀵煎叆鏃?RAM 宄板€?500MB+銆備腑绔墜鏈?RAM 閫氬父 4-6GB锛岀郴缁?+ Flutter 寮曟搸宸插崰 2-3GB锛屽彲瑙﹀彂 OOM killer銆?
**淇寤鸿**: 浣跨敤鏂囦欢璺緞鑰岄潪瀛楄妭鏁扮粍浼犵粰 isolate锛屽湪 isolate 鍐呮祦寮忓鐞嗐€?
---

### HBK-AUDIT-015 鈥?閿欒鏃ュ織绯荤粺闄愬埗

**Severity**: 馃煝 LOW
**Status**: open
**鏂囦欢**: `hibiki/lib/src/utils/misc/error_log_service.dart`

**鐜扮姸**:
- 鉁?鏈夐泦涓紡閿欒鏃ュ織锛坄ErrorLogService.instance.log()`锛?- 鉁?鍐呭瓨闄愬埗 200 鏉★紝鏂囦欢闄愬埗 512KB
- 鉂?绾枃鏈牸寮忥紝鏃犵粨鏋勫寲瀛楁锛堟棤 device info銆佹棤 app version銆佹棤 user action context锛?- 鉂?鏃犺繙绋嬩笂鎶ワ紙鏃?Crashlytics/Sentry锛?- 鉂?`_appendToFile` 浣跨敤 `writeAsStringSync` 鈥?涓荤嚎绋嬪悓姝?I/O
- 鉂?4 澶?`catch (_) {}` 鈥?鏃ュ織绯荤粺鏈韩鐨勯敊璇鍚炲櫖

**褰卞搷**: 鐢熶骇鐜鐢ㄦ埛閬囧埌宕╂簝鏃讹紝寮€鍙戣€呭彧鑳介潬鐢ㄦ埛鎵嬪姩瀵煎嚭鏃ュ織銆傛棩蹇楀啓鍏ュ鏋滃彂鐢熷湪鍏抽敭璺緞锛堝闃呰鍣ㄧ炕椤碉級锛屽悓姝?I/O 鍙兘閫犳垚鐭殏鍗￠】銆?
---

### HBK-AUDIT-016 鈥?鏈夊０涔﹀瓧骞?cue 鏁伴噺鏃犱笂闄?
**Severity**: 馃煝 LOW
**Status**: open
**鏂囦欢**: `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart:570`

**鏍瑰洜**: 瑙ｆ瀽瀛楀箷鏂囦欢鍚?`cues.length` 鏃犳牎楠屻€?
**褰卞搷**: 鎹熷潖鐨勫瓧骞曟枃浠跺彲鑳戒骇鐢?100K+ cue 鏉＄洰锛屽叏閮ㄥ啓鍏?SQLite `audio_cues` 琛紝瀵艰嚧鍚庣画鏌ヨ鍙樻參銆?
---

### HBK-AUDIT-017 鈥?闈欐€佸彲鍙樺瓧鍏告牱寮忕紦瀛樻棤椹遍€?
**Severity**: 馃煝 LOW
**Status**: open
**鏂囦欢**: `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart:185`

**鏍瑰洜**: `_stylesCache` 鏄?static Map锛岄殢瀛楀吀鏁伴噺绾挎€у闀匡紝鏃?LRU 椹遍€愩€?
**褰卞搷**: 瀵煎叆 100+ 瀛楀吀鏃讹紙鏋佺鍦烘櫙锛夛紝缂撳瓨鍙兘鍗犵敤鏁扮櫨 MB銆傛甯镐娇鐢ㄥ満鏅紙5-20 瀛楀吀锛夊奖鍝嶅彲蹇界暐銆?
---

### HBK-AUDIT-018 鈥?娴嬭瘯瑕嗙洊鍒嗘瀽

**Status**: open

**鐜扮姸**:
- 106 涓崟鍏冩祴璇曟枃浠?/ ~8,300 琛?鈥?鏁版嵁搴撳眰瑕嗙洊**鑹ソ**锛坢igration銆丆RUD銆佸苟鍙戝啓鍏ャ€佸閿€乸rofile 绛夊叏鏈夛級
- 4 涓泦鎴愭祴璇曟枃浠?鈥?瀛樺湪浣嗘湭鍦?CI 杩愯
- 鉂?**鏃?* AppModel 鍗曞厓娴嬭瘯锛?,045 琛屾牳蹇冮€昏緫闆舵祴璇曪級
- 鉂?**鏃?* 闃呰鍣ㄧ姸鎬佹満娴嬭瘯锛?,849 琛屽鏉傞€昏緫闆舵祴璇曪級
- 鉂?**鏃?* 瀛楀吀鎼滅储/瀵煎叆闆嗘垚娴嬭瘯
- 鉂?**鏃?* Creator/Anki 瀵煎嚭闆嗘垚娴嬭瘯
- 鉂?**鏃?* WebView JS 浜や簰娴嬭瘯

**椋庨櫓**: 鏁版嵁搴撳眰鏄敮涓€鏈変俊蹇冪殑鍖哄煙銆傞槄璇诲櫒銆丄ppModel銆佸瓧鍏哥郴缁熺殑浠讳綍閲嶆瀯閮芥槸鍦ㄦ病鏈夊畨鍏ㄧ綉鐨勬儏鍐典笅璧伴挗涓濄€?
---

### HBK-AUDIT-019 鈥?渚濊禆椋庨櫓

**Status**: open
**鏂囦欢**: `hibiki/pubspec.yaml`

| 椋庨櫓椤?| 璇︽儏 |
|--------|------|
| 6 涓?git 渚濊禆 | `blurrycontainer`, `material_floating_search_bar`, `receive_intent`, `ruby_text`, `spaces` 鈥?鍥哄畾 commit hash锛屼絾涓婃父椤圭洰鍧囦负涓汉 fork锛屾棤缁存姢淇濊瘉 |
| 5 涓?dependency_overrides | `ffi`, `freezed_annotation`, `gap`, `logging`, `wakelock_plus_platform_interface` 鈥?鐗堟湰鍐茬獊閫氳繃 override 鍘嬪埗鑰岄潪瑙ｅ喅 |
| `flutter_html: ^3.0.0-beta.2` | 浣跨敤 beta 鐗堜緷璧?|
| `dart_mappable: ^4.0.0-dev.1` | 浣跨敤 dev 鐗堜緷璧?|
| 2 涓湰鍦?package override | `file_picker`, `flutter_inappwebview_windows` 鈥?鎰忓懗鐫€涓婃父鐗堟湰鏈?bug锛岀淮鎶や簡鏈湴 fork |

**褰卞搷**: 5 涓?override 鎰忓懗鐫€ `pub upgrade` 鏃犳硶姝ｅ父宸ヤ綔锛屼緷璧栨洿鏂伴渶瑕佹墜鍔ㄩ€愪釜楠岃瘉銆俠eta/dev 渚濊禆鍦?Flutter 鍗囩骇鏃跺彲鑳界巼鍏堢牬鍧忋€?
---

## 楂橀闄╅棶棰樺垪琛紙鎸変紭鍏堢骇鎺掑簭锛?
| 浼樺厛绾?| 缂栧彿 | 闂 | 褰卞搷 |
|--------|------|------|------|
| P0 | HBK-AUDIT-002 | 闃呰鍣ㄤ綅缃繚瀛樼珵鎬?| 鐢ㄦ埛鏁版嵁涓㈠け |
| P0 | HBK-AUDIT-003 | WebView controller 鐢熷懡鍛ㄦ湡绔炴€?| 宕╂簝 |
| P0 | HBK-AUDIT-012 | 鏁版嵁搴撻檷绾у叏鍒犻噸寤?| 鐢ㄦ埛鏁版嵁涓㈠け |
| P0 | HBK-AUDIT-020 | CreatorModel 鏃?dispose() | 纭畾鎬у唴瀛樻硠婕?|
| P0 | HBK-AUDIT-025 | _initBook() 寮傛闂撮殭缂?mounted 妫€鏌?| setState-after-dispose 宕╂簝 |
| P1 | HBK-AUDIT-001 | AppModel 涓婂笣瀵硅薄 | 鎬ц兘/鍙淮鎶ゆ€?骞跺彂瀹夊叏 |
| P1 | HBK-AUDIT-005 | 瀛楀吀 ZIP 瑙ｅ帇鏃犲唴瀛橀檺鍒?| OOM 宕╂簝 |
| P1 | HBK-AUDIT-004 | JS 妯℃澘瀛楃涓茶浆涔変笉瀹屾暣 | XSS/琛屼负寮傚父 |
| P2 | HBK-AUDIT-007 | 闃呰鍣ㄥ鏍囧織鐘舵€佹満 | 蹇€熷鑸紓甯?|
| P2 | HBK-AUDIT-008 | Stream/Timer 娉勬紡椋庨櫓 | 鍐呭瓨娉勬紡 |
| P2 | HBK-AUDIT-010 | 鍋忓ソ绫诲瀷涓嶅畨鍏ㄥ簭鍒楀寲 | 璁剧疆闈欓粯涓㈠け |
| P2 | HBK-AUDIT-009 | Creator/Anki 浠ｇ爜閲嶅 | 缁存姢鎴愭湰缈诲€?|
| P2 | HBK-AUDIT-011 | CI/CD 缂哄け release build | 鐢熶骇 bug 閫冮€?|
| P2 | HBK-AUDIT-014 | EPUB 瀵煎叆鍐呭瓨宄板€?| 澶ф枃浠?OOM |
| P2 | HBK-AUDIT-021 | 鏁版嵁搴撶己灏戝叧閿煡璇㈢储寮?| 鏌ヨ鎬ц兘閫€鍖?|
| P2 | HBK-AUDIT-022 | 5 灞傚亸濂界紦瀛樻棤澶辨晥鏈哄埗 | 鍋忓ソ涓嶄竴鑷?|
| P2 | HBK-AUDIT-023 | 鍏抽敭鎿嶄綔缂哄皯浜嬪姟鍖呰９ | 鏁版嵁涓嶄竴鑷?|
| P3 | HBK-AUDIT-006 | C++ 瀵煎叆鍣ㄦ棤璧勬簮涓婇檺 | 鎭舵剰杈撳叆 OOM |
| P3 | HBK-AUDIT-016 | 瀛楀箷 cue 鏃犱笂闄?| 鏁版嵁搴撹啫鑳€ |
| P3 | HBK-AUDIT-015 | 閿欒鏃ュ織鍚屾 I/O | 寰崱椤?|
| P3 | HBK-AUDIT-017 | 瀛楀吀鏍峰紡缂撳瓨鏃犻┍閫?| 鏋佺鍦烘櫙鍐呭瓨 |
| P3 | HBK-AUDIT-024 | 911 涓?null assertion | 宕╂簝鏃堕毦瀹氫綅 |
| P3 | HBK-AUDIT-013 | 鍛藉悕涓嶄竴鑷?| 鍙鎬?|
| P3 | HBK-AUDIT-019 | 渚濊禆椋庨櫓 | 鍗囩骇鍥伴毦 |
| 鈥?| HBK-AUDIT-018 | 娴嬭瘯瑕嗙洊缂哄彛 | 閲嶆瀯鏃犲畨鍏ㄧ綉 |

---

## 涓暱鏈熸灦鏋勯闄?
### 1. AppModel 鎷嗗垎鎴愭湰鎸囨暟澧為暱
AppModel 姣忓鍔犱竴涓姛鑳藉氨澶氫竴瀵?getter/setter + notifyListeners銆傚綋鍓?54 娆?notify 鎰忓懗鐫€ UI 宸茬粡琚繃搴﹂噸寤恒€? 涓湀鍚庡鏋滆揪鍒?80+ notify锛屾€ц兘闂灏嗕粠銆屽伓灏斿崱銆嶅彉鎴愩€屾寔缁崱銆嶃€?*鎷嗗垎绐楀彛姝ｅ湪鍏抽棴** 鈥?鐜板湪鎷嗘垚鏈害 1 鍛紝6 涓湀鍚庣害 3 鍛ㄣ€?
### 2. 闃呰鍣?3,849 琛屽崟鏂囦欢涓嶅彲鎸佺画
`reader_hoshi_page.dart` 闆嗘垚浜?WebView 绠＄悊銆佺姸鎬佹満銆侀煶棰戞ˉ鎺ャ€佷綅缃仮澶嶃€佹牱寮忔敞鍏ャ€佽祫婧愭嫤鎴€佹墜鍔垮鐞嗐€備换浣曞崟涓€鍔熻兘鐨勪慨鏀归兘闇€瑕佺悊瑙ｆ暣涓?3,849 琛岀殑涓婁笅鏂囥€?*宸茶繘鍏ャ€岀涓€澶勫潖涓夊銆嶇殑鍖洪棿**銆?
### 3. 澶氬钩鍙版墿灞曠殑闅愭€ч殰纰?worktree 涓凡鏈?`phase2-3-multiplatform` 鍒嗘敮銆備絾褰撳墠浠ｇ爜涓?~20 澶?`Platform.isAndroid` / `Platform.isIOS` 鍒嗘敮鏁ｅ竷鍦?AppModel銆乵ain.dart銆乵edia_source.dart 涓€俻ackages 灞傦紙hibiki_core, hibiki_dictionary 绛夛級铏藉凡鍒嗙锛屼絾 AppModel 浠嶇洿鎺ュ紩鐢ㄥ钩鍙扮壒瀹?API锛圗xternalPath銆丏eviceInfoPlugin銆乄akelockPlus锛夈€傚骞冲彴闇€瑕佸厛瑙ｅ喅 AppModel 鎷嗗垎銆?
### 4. WebView 鈫?Dart 鐘舵€佸悓姝ヨ剢寮?褰撳墠渚濊禆 JS handler 鍥炶皟 + generation number 鍖归厤鏉ュ悓姝?WebView 鍜?Dart 鐘舵€併€傛病鏈夊舰寮忓寲鐨勬秷鎭崗璁垨 ACK 鏈哄埗銆傜綉缁滃欢杩燂紙鏈湴 WebView 涓嶆秹鍙婄綉缁滐紝浣?JS 鎵ц寤惰繜锛夋垨 GC 鏆傚仠閮藉彲鑳藉鑷?generation 涓嶅尮閰嶃€?
---

## 鎶€鏈€哄湴鍥?
```
hibiki/
鈹溾攢鈹€ lib/
鈹?  鈹溾攢鈹€ src/models/
鈹?  鈹?  鈹溾攢鈹€ app_model.dart ............ 馃敶 4,045 琛屼笂甯濆璞?[P1: 鎷嗗垎]
鈹?  鈹?  鈹斺攢鈹€ creator_model.dart ........ 馃敶 鏃?dispose() [P0: 淇]
鈹?  鈹溾攢鈹€ src/pages/implementations/
鈹?  鈹?  鈹斺攢鈹€ reader_hoshi_page.dart .... 馃敶 3,849 琛? 绔炴€?+ 寮傛闂撮殭 [P0+P1]
鈹?  鈹溾攢鈹€ src/creator/fields/
鈹?  鈹?  鈹溾攢鈹€ audio_field.dart .......... 馃煛 涓?audio_sentence_field 95% 閲嶅
鈹?  鈹?  鈹斺攢鈹€ audio_sentence_field.dart . 馃煛 [P2: 鎻愬彇鍩虹被]
鈹?  鈹溾攢鈹€ src/media/media_source.dart ... 馃煛 鍋忓ソ搴忓垪鍖栫被鍨嬩笉瀹夊叏 [P2]
鈹?  鈹斺攢鈹€ src/utils/misc/
鈹?      鈹斺攢鈹€ error_log_service.dart .... 馃煝 鍚屾 I/O + 鍚炲紓甯?[P3]
鈹溾攢鈹€ pubspec.yaml ...................... 馃煛 6 git 渚濊禆 + 5 override [P3]
鈹?packages/
鈹溾攢鈹€ hibiki_core/src/database/
鈹?  鈹斺攢鈹€ database.dart ................. 馃敶 闄嶇骇鍏ㄥ垹 [P0] + 缂虹储寮?[P2]
鈹溾攢鈹€ hibiki_dictionary/src/
鈹?  鈹溾攢鈹€ formats/*.dart ................ 馃煛 ZIP 瑙ｅ帇鏃犲唴瀛橀檺鍒?[P1]
鈹?  鈹斺攢鈹€ engine/hoshidicts.dart ........ 馃煝 鏍峰紡缂撳瓨鏃犻┍閫?[P3]
鈹斺攢鈹€ hibiki_anki/src/
    鈹溾攢鈹€ ankiconnect/ .................. 馃煛 mineEntry 涓?ankidroid 閲嶅
    鈹斺攢鈹€ ankidroid/ .................... 馃煛 [P2: 涓婃彁鍒?base]
```

---

## 鍙淮鎶ゆ€ц瘎鍒?
| 缁村害 | 璇勫垎 | 璇存槑 |
|------|------|------|
| 浠ｇ爜缁勭粐 | 5/10 | package 鍒嗙鎬濊矾姝ｇ‘锛屼絾 AppModel 涓婂笣瀵硅薄涓ラ噸鎷栧悗鑵?|
| 绫诲瀷瀹夊叏 | 7/10 | Dart 寮虹被鍨嬩綋绯讳娇鐢ㄨ緝濂斤紝`dynamic` 鐢ㄩ噺浣庯紙10 澶勶級锛屼絾鍋忓ソ搴忓垪鍖栧瓨鍦ㄧ被鍨嬫紓绉?|
| 閿欒澶勭悊 | 4/10 | 鏈夐泦涓紡鏃ュ織锛屼絾 15 澶?`catch (_) {}` + 6 澶?`.catchError((_) {})` 鏄畾鏃剁偢寮?|
| 璧勬簮绠＄悊 | 5/10 | 澶ч儴鍒?dispose 姝ｇ‘锛屼絾闃呰鍣ㄥ拰闊抽妗ユ帴瀛樺湪娉勬紡璺緞 |
| 娴嬭瘯瑕嗙洊 | 4/10 | 鏁版嵁搴撳眰浼樼锛屼絾鏍稿績涓氬姟閫昏緫锛圓ppModel銆侀槄璇诲櫒銆丆reator锛夐浂瑕嗙洊 |
| 渚濊禆鍋ュ悍 | 4/10 | 6 涓?git fork + 5 涓?override + 2 涓?beta/dev 渚濊禆 |
| CI/CD | 3/10 | 鍙湁 analyze + test + debug build锛屾棤 release 楠岃瘉/瑕嗙洊鐜?瀹夊叏鎵弿 |
| 鏂囨。 | 6/10 | CLAUDE.md + AGENTS.md 瑙勫垯璇﹀敖锛屼唬鐮佸唴娉ㄩ噴閫傞噺 |
| 鎬ц兘鎰忚瘑 | 6/10 | FFI 瀛楀吀鏌ヨ銆乄ebView 棰勭儹绛夊仛寰楀ソ锛屼絾 AppModel 鍏ㄦ爲 rebuild 鍜屽唴瀛樺嘲鍊兼槸鐩茬偣 |
| 瀹夊叏 | 5/10 | EPUB 璺緞閬嶅巻闃叉姢浼樼锛屼絾 JS 娉ㄥ叆銆佽祫婧愰檺鍒躲€侀檷绾ф暟鎹涪澶卞瓨鍦ㄧ己鍙?|

**缁煎悎鍙淮鎶ゆ€? 4.9/10** 鈥?銆屽崟浜虹淮鎶ゆ湡鐨勯」鐩紝鏈夎壇濂界殑鍩虹璁炬柦鎰忚瘑锛屼絾鏍稿績妯″潡锛圓ppModel銆侀槄璇诲櫒锛夌殑澶嶆潅搴﹀凡缁忚秴杩囦簡瀹夊叏缁存姢鐨勯槇鍊笺€傘€?
---

## 鏋舵瀯鍋ュ悍搴﹁瘎浠?
**鏋舵瀯鎴愮啛搴? Early Growth (鎴愰暱鍒濇湡)**

**浼樺娍**:
- Package 鍒嗙鏂瑰悜姝ｇ‘锛坔ibiki_core/dictionary/anki/audio/platform锛?- Drift SQLite 浣跨敤瑙勮寖锛圵AL銆佸閿€佺储寮曘€佽縼绉荤増鏈彿锛?- 鏁版嵁搴撴祴璇曡鐩栫巼楂橈紙migration銆乧oncurrent銆乫oreign key 鍏ㄦ湁锛?- FFI 鍐呭瓨绠＄悊鎬讳綋瑙勮寖锛坒inally 閲婃斁銆乮solate 闅旂锛?- EPUB 璺緞閬嶅巻闃叉姢鍒颁綅

**鍔ｅ娍**:
- AppModel 涓婂笣瀵硅薄闃荤浜?package 鍒嗙鐨勪环鍊煎彂鎸?- 闃呰鍣ㄥ崟鏂囦欢 3,849 琛岋紝鐘舵€佹満鏃犲舰寮忓寲
- 寮傛閿欒鍚炲櫖妯″紡骞挎硾鍒嗗竷
- CI 鍙仛鏈€浣庨檺搴﹂獙璇?- 鏍稿績閫昏緫闆舵祴璇曡鐩?
**姝ｉ潰鍙戠幇锛堝紓姝?璧勬簮瀹℃煡纭锛?*:
- 鉁?鎵€鏈?`StreamSubscription` 鍦?`dispose()` 涓纭彇娑?- 鉁?鎵€鏈?`Timer` / `Timer.periodic` 鍦?`dispose()` 涓纭彇娑?- 鉁?`FocusNode`銆乣ScrollController`銆乣TextEditingController` 閲婃斁鎬讳綋姝ｇ‘
- 鉁?`addListener` / `removeListener` 閰嶅姝ｇ‘
- 鉁?`Completer` 浣跨敤姝ｇ‘锛屾湁 `isCompleted` 瀹堝崼闃叉鍙岄噸瀹屾垚
- 鉁?`runZonedGuarded` + `FlutterError.onError` 鍏ㄥ眬閿欒杈圭晫瀹屽杽
- 鉁?EPUB 璺緞閬嶅巻闃叉姢锛坄p.isWithin()` 妫€鏌ワ級浼樼
- 鉁?FFI 鍐呭瓨绠＄悊浣跨敤 `try-finally` + `calloc.free()` 瑙勮寖
- 鉁?AudiobookController dispose 瀹屾暣锛? 涓?stream subscription + player锛?
**缁撹**: 椤圭洰鏈夎壇濂界殑鎶€鏈洿瑙夛紙閫夋嫨 Drift 鑰岄潪 SharedPreferences銆佺敤 Isolate 鍋氶噸璁＄畻銆佺敤 C++ FFI 鍋氬瓧鍏告煡璇級锛屼絾**鎵ц绾緥涓嶄竴鑷?* 鈥?鏁版嵁搴撳眰鍜岃祫婧愰噴鏀剧殑涓ヨ皑绋嬪害杩滈珮浜?AppModel 鍜岄槄璇诲櫒鐘舵€佺鐞嗗眰銆傝繖鏄吀鍨嬬殑銆孉I 杈呭姪寮€鍙?+ 鍗曚汉缁存姢銆嶆ā寮忥細鍩虹璁炬柦灞傦紙琚粩缁嗗鏌ヨ繃鐨勶級璐ㄩ噺楂橈紝涓氬姟閫昏緫灞傦紙蹇€熻凯浠ｇ殑锛夎川閲忎綆銆?
---

## 鎺ㄨ崘閲嶆瀯椤哄簭

### Phase 0: 绱ф€ヤ慨澶嶏紙2-3 澶╋級
1. **HBK-AUDIT-002**: 淇浣嶇疆淇濆瓨绔炴€侊紙闂寘鎹曡幏灞€閮ㄥ彉閲忥級
2. **HBK-AUDIT-003**: WebView controller 璋冪敤鍖呰９ try-catch
3. **HBK-AUDIT-012**: 鏁版嵁搴撻檷绾у墠澶囦唤
4. **HBK-AUDIT-020**: CreatorModel 娣诲姞 dispose()锛? 琛屼慨澶嶏級
5. **HBK-AUDIT-025**: _initBook() 寮傛闂撮殭娣诲姞 mounted 瀹堝崼

### Phase 1: 瀹夊叏鍔犲浐锛?-5 澶╋級
4. **HBK-AUDIT-004**: JS 娉ㄥ叆鏀圭敤 JSON 缂栫爜
5. **HBK-AUDIT-005**: ZIP 瑙ｅ帇娣诲姞澶у皬妫€鏌?6. **HBK-AUDIT-011**: CI 娣诲姞 release build + coverage

### Phase 2: 缁撴瀯鎬ц繕鍊猴紙1-2 鍛級
7. **HBK-AUDIT-001**: AppModel 鎷嗗垎锛圱hemeNotifier銆丳referencesRepo銆丏ictionaryRepo锛?8. **HBK-AUDIT-009**: Creator 瀛楁鎻愬彇鍩虹被锛孉nki mineEntry 涓婃彁
9. **HBK-AUDIT-010**: 鍋忓ソ搴忓垪鍖栨坊鍔犵被鍨嬫爣璁?
### Phase 3: 闃呰鍣ㄦ不鐞嗭紙2-3 鍛級
10. **HBK-AUDIT-007**: 鐘舵€佹満褰㈠紡鍖栵紙enum + 杞崲鍑芥暟锛?11. 鎷嗗垎 `reader_hoshi_page.dart` 涓猴細
    - `ReaderHoshiPage` (鐢熷懡鍛ㄦ湡/璺敱)
    - `ReaderWebViewController` (WebView 绠＄悊)
    - `ReaderPositionManager` (浣嶇疆淇濆瓨/鎭㈠)
    - `ReaderAudioBridge` (鏈夊０涔﹂泦鎴?
    - `ReaderStyleInjector` (CSS/鏍峰紡绠＄悊)

---

## 濡傛灉缁х画褰撳墠妯″紡锛屾湭鏉?3-6 涓湀鏈€鍙兘鍑虹幇鐨勯棶棰?
1. **AppModel 鎬ц兘鍧嶅** (2-3 涓湀): 闅忕潃鍔熻兘澧炲姞锛宍notifyListeners()` 棰戠巼涓婂崌锛孶I 閲嶅缓寮€閿€浠庡彲蹇界暐鍙樹负鍙劅鐭ャ€傜敤鎴蜂細鎶ュ憡銆屽垏鎹㈠亸濂藉悗鍏ㄩ儴鍗′竴涓嬨€嶃€?
2. **闃呰鍣ㄤ慨涓嶅姩** (1-2 涓湀): `reader_hoshi_page.dart` 姣忔淇?bug 閮芥湁 30%+ 姒傜巼寮曞叆鏂?bug锛屽洜涓?3,849 琛屼唬鐮佺殑鐘舵€佷氦浜掕矾寰勮秴鍑轰汉鑴戠紦瀛樸€傛煇娆°€屼慨澶嶇炕椤点€嶄細瀵艰嚧銆屼綅缃仮澶嶅潖浜嗐€嶃€?
3. **澶у瓧鍏稿鍏?OOM** (宸插彲澶嶇幇): 鐢ㄦ埛瀵煎叆 1GB+ 瀛楀吀 ZIP 鏃?OOM 宕╂簝銆傚綋鍓嶅彧鍦ㄥ皬瀛楀吀涓婃祴璇曢€氳繃銆?
4. **渚濊禆閿佹** (3-6 涓湀): Flutter 3.41.6 鈫?涓嬩竴涓ぇ鐗堟湰鍗囩骇鏃讹紝6 涓?git fork + 5 涓?override 浼氬鑷磋嚦灏?2-3 澶╃殑渚濊禆瑙ｅ啿绐佸伐浣溿€俙dart_mappable: ^4.0.0-dev.1` 杩涘叆 stable 鍚?API 鍙兘鍙樺寲銆?
5. **澶氬钩鍙拌鍒掑彈闃?* (姝ｅ湪鍙戠敓): Windows 閫傞厤宸插湪 worktree 涓繘琛岋紝浣?AppModel 瀵?Android API 鐨勭‖渚濊禆鎰忓懗鐫€姣忎釜鍋忓ソ閮介渶瑕佹坊鍔犲钩鍙板垎鏀紝宸ヤ綔閲忕嚎鎬у闀裤€?
6. **鍥炲綊澶辨帶** (鎸佺画): 鏃犻槄璇诲櫒/Creator 鑷姩鍖栨祴璇曟剰鍛崇潃姣忔鍙戠増閮芥槸鎵嬪姩鍥炲綊銆傞殢鐫€鍔熻兘澧炲姞锛屾墜鍔ㄦ祴璇曡鐩栫巼鎸佺画涓嬮檷銆?
---

## Next Scope

涓嬩竴杞鏌ュ皢鑱氱劍锛?1. `reader_hoshi_page.dart` 閫愬嚱鏁板鏌ワ紙WebView 璧勬簮鎷︽埅銆乷nLoadStop 瀹屾暣璺緞锛?2. Profile 绯荤粺锛坄profile_repository.dart`銆乣profile_view_model.dart`锛夆€?澶?Profile 鍒囨崲鐨勭姸鎬佷竴鑷存€?3. 鏈夊０涔︽挱鏀炬爮锛坄audiobook_play_bar.dart` 2,151 琛岋級鈥?鍙︿竴涓ぇ鏂囦欢鐑偣
4. 瀛楀吀鎼滅储鎬ц兘璺緞锛圚oshiDicts FFI 鈫?UI 娓叉煋瀹屾暣閾捐矾锛?
---

## 闄勫綍 A: 寮傚父鍚炲櫖娓呭崟

| 鏂囦欢 | 琛屽彿 | 妯″紡 | 椋庨櫓 |
|------|------|------|------|
| `app_model.dart` | 2748 | `catch (_) {}` | 鏈煡鎿嶄綔闈欓粯澶辫触 |
| `app_model.dart` | 2796 | `catch (_) {}` | 鏈煡鎿嶄綔闈欓粯澶辫触 |
| `app_model.dart` | 3749 | `catch (_) {}` | 鏈煡鎿嶄綔闈欓粯澶辫触 |
| `reader_hoshi_page.dart` | 277 | `catch (_) {}` | WebView 鍒濆鍖栧け璐ヨ鍚?|
| `reader_hoshi_page.dart` | 811 | `catch (_) {}` | 闃呰鍣ㄦ搷浣滃け璐ヨ鍚?|
| `reader_hoshi_page.dart` | 1720 | `catch (_) {}` | 鏍峰紡搴旂敤澶辫触琚悶 |
| `reader_hoshi_page.dart` | 2418 | `catch (_) {}` | 浣嶇疆鐩稿叧鎿嶄綔澶辫触琚悶 |
| `error_log_service.dart` | 58, 78, 114 | `catch (_) {}` | 鏃ュ織绯荤粺鑷韩閿欒琚悶 |
| `audiobook_play_bar.dart` | 1214 | `catch (_) {}` | 鎾斁鎺у埗澶辫触琚悶 |
| `highlight_bridge.dart` | 387 | `catch (_) {}` | 楂樹寒鎿嶄綔澶辫触琚悶 |
| `hoshi_settings_page.dart` | 239 | `catch (_) {}` | 璁剧疆鎿嶄綔澶辫触琚悶 |
| `update_checker.dart` | 52, 55 | `catch (_) {}` | 鏇存柊妫€鏌ュけ璐ヨ鍚?|
| `profile_view_model.dart` | 50 | `.catchError((_) {})` | Profile 蹇収澶辫触琚悶 |
| `app_model.dart` | 1791 | `.catchError((_) {})` | splash 棰滆壊璁剧疆澶辫触琚悶 |
| `audio_field.dart` | 118, 370 | `.catchError((Object _) {})` | 闊抽鎿嶄綔澶辫触琚悶 |
| `audio_sentence_field.dart` | 120, 372 | `.catchError((Object _) {})` | 闊抽鎿嶄綔澶辫触琚悶 |
