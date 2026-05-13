<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">قارئ ياباني غامر لنظام أندرويد</p>
<p align="center">EPUB · قاموس · Anki · مزامنة الكتب الصوتية</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <b>العربية</b> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## مقدمة

**hibiki** هو تطبيق قراءة على أندرويد لمتعلمي اللغة اليابانية.

## الميزات

### قراءة EPUB
- قارئ [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) مدمج يعرض EPUB عبر WebView
- انقر للبحث عن كلمة، حدد نصاً لتحليله
- خطوط مخصصة، سمات (فاتحة/داكنة)
- إحصائيات القراءة والعلامات المرجعية
- وضع التمرير المستمر / وضع الصفحات

### القاموس
- استيراد قواميس بصيغة [Yomitan](https://github.com/yomidevs/yomitan) (سابقاً Yomichan)
- بيانات نبرة النطق وتردد الكلمات
- بحث متوازٍ في عدة قواميس، سجل البحث
- تصريف Ve العكسي

### بطاقات Anki
- تصدير بنقرة واحدة إلى [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- ملء تلقائي لجمل السياق
- دعم التسجيل الصوتي، قص لقطات الشاشة
- ملفات تصدير متعددة، تعيين حقول مخصص
- إجراءات سريعة (Quick Actions) لإنشاء البطاقات بخطوة واحدة

### مزامنة الكتب الصوتية (Sasayaki)
- صيغ الترجمات: SRT / LRC / VTT / ASS
- محاذاة تلقائية للترجمات مع نص EPUB
- تمييز متزامن مع الصوت، تقليب صفحات تلقائي
- شريط التحكم بالتشغيل (التقدم، القفز، السرعة)

### أخرى
- 17 لغة واجهة
- ملفات تعريف مستخدمين متعددة
- وضع التصفح المتخفي
- مشاركة نص من تطبيقات أخرى للبحث المباشر

## اللغات المدعومة

تدعم الواجهة اللغات التالية:

| اللغة | الرمز |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## المكدس التقني

| الطبقة | التقنية |
|---|---|
| إطار العمل | Flutter 3.41.6 / Dart 3.11.4 |
| القارئ | ttu Ebook Reader (WebView, [fork](https://github.com/hdjsadgfwtg/ttu-fork)) |
| التخزين | Isar + Drift (SQLite) + hoshidicts (محرك قاموس C++ FFI) |
| NLP | Ve (التصريف العكسي) |
| إنشاء البطاقات | AnkiDroid API |
| التدويل | Slang |
| الحد الأدنى للإصدار | Android 8.0 (API 26) |

## البناء

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **يجب تطبيق تصحيحات pub cache قبل البناء الأول.** إذا تم مسح pub cache أو أُعيد تشغيل `pub get`، يجب إعادة تطبيق جميع التصحيحات. راجع [التبعيات والتصحيحات](#التبعيات-والتصحيحات) أدناه.

## التبعيات والتصحيحات

هذا المشروع مقفل على Flutter 3.41.6. بعض التبعيات الأصلية لم تُكيَّف بعد وتتطلب تصحيح الكود المصدري يدوياً في pub cache.

<details>
<summary><b>تصحيحات تغييرات Flutter API</b></summary>

| الحزمة | التغييرات |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; استبدال `imageCache.putIfAbsent` المحذوف |
| `flutter_blurhash` 0.7.0 | نفس التغييرات: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | إضافة `hide CarouselController` في import الداخلي لتجنب تعارض الأسماء |
| `fading_edge_scrollview` 3.0.0 | إصلاح `PageView.controller` nullable |

</details>

<details>
<summary><b>تصحيحات إزالة v1 Embedding</b></summary>

أزال Flutter 3.41.6 بالكامل واجهة v1 embedding API (`PluginRegistry.Registrar`). الإضافات التالية تحتاج إلى حذف المراجع ذات الصلة:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>تصحيحات Gradle / Kotlin</b></summary>

| الهدف | التغييرات |
|---|---|
| `android/build.gradle` afterEvaluate | فرض `compileSdkVersion 34` على المشاريع الفرعية؛ إزالة `-Werror` |
| `audio_session` 0.1.14 | إزالة `-Werror`، `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | إصلاح Kotlin null safety |
| `receive_intent` (git) | إصلاح Kotlin null safety |

</details>

<details>
<summary><b>تبعيات Git</b></summary>

| الحزمة | المصدر |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## هيكل المشروع

```
hibiki/
├── hibiki/                  # الدليل الرئيسي لتطبيق Flutter
│   ├── lib/
│   │   ├── i18n/            # التدويل (17 لغة)
│   │   ├── src/
│   │   │   ├── pages/       # الصفحات (رف الكتب، القارئ، القاموس، الإعدادات، إلخ)
│   │   │   ├── media/       # جسر الكتب الصوتية، تحليل الترجمات
│   │   │   ├── dictionary/  # محرك البحث في القاموس
│   │   │   ├── models/      # نماذج البيانات وإدارة الحالة
│   │   │   └── language/    # طبقة تجريد اللغة
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # مخرجات بناء ttu fork
│   └── android/
│       └── app/src/main/cpp/ # محرك قاموس C++ hoshidicts
├── docs/                    # وثائق التطوير
└── chisa/                   # مرجع الإصدارات المبكرة من jidoujisho
```

## شكر وتقدير

| المشروع | الوصف |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | أداة تعلم اللغة اليابانية الغامرة |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | قارئ ياباني لأندرويد |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | محرك قاموس C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | قارئ ياباني لنظام iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | حل مزامنة الكتب الصوتية |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | محرك عرض EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | نسخة مجتمع ttu (SvelteKit v2)، الأساس الأصلي لـ hibiki fork |
| [Yomitan](https://github.com/yomidevs/yomitan) | مصدر صيغة القاموس |

## الرخصة

[GNU General Public License v3.0](../../LICENSE)
