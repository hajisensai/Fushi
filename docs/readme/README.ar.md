<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="شعار Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | **العربية**

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![تنزيل أحدث إصدار](https://img.shields.io/badge/%E2%AC%87%20%D8%AA%D9%86%D8%B2%D9%8A%D9%84%20%D8%A3%D8%AD%D8%AF%D8%AB%20%D8%A5%D8%B5%D8%AF%D8%A7%D8%B1-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![انضم إلى Discord](https://img.shields.io/badge/%D8%A7%D9%86%D8%B6%D9%85%20%D8%A5%D9%84%D9%89%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## دعم المنصّات

| المنصّة | الحالة | ملاحظات |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) أو أحدث |
| Windows | ✅ | اعتراض نصوص وأصوات الـ galgame يعمل على Windows فقط |
| macOS | ✅ | Apple Silicon فقط؛ أجهزة Mac بمعالجات Intel غير مدعومة |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | بلا اكتشاف أو مصادر عبر الإنترنت أو مركز تنزيلات (إرشادات App Store) |
| Linux | 🔧 البناء من المصدر | لا يوجد إصدار جاهز بعد؛ قارئ EPUB يحتاج إلى WPE WebKit |
| Fushi Server | 🧪 تجريبي ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | مضيف بلا واجهة رسومية لأنظمة Linux / Windows / macOS مع واجهة ويب — راجع [packages/fushi_server](../../packages/fushi_server/README.md) |

**نظام التصميم** — يعتمد **Material 3 Expressive** افتراضيًا على كل المنصّات؛ ويمكن اختيار نظام تصميم **Cupertino** (بأسلوب Apple) من *الإعدادات › المظهر › نظام التصميم*؛ ومع Cupertino تستخدم خلفية النافذة Mica على Windows 11 وvibrancy على macOS (ما لم يكن إعداد تقليل الشفافية أو التباين العالي في النظام مفعّلًا).

> تُحدَّد اللغات المتاحة للبحث في القاموس بناءً على القواميس المُستورَدة وجداول تحويل Yomitan، بشكل مستقلّ عن لغة الواجهة. تصل تحديثات iOS عبر TestFlight بعد المنصّات الأخرى ببضعة أيام.

### لغات الواجهة (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## التثبيت

نزّل أحدث إصدار من [موقع Fushi](https://fushi.moe/) — تتوفر حزمة APK لنظام Android ومثبّت Windows وإصدارات macOS (Apple Silicon فقط؛ أجهزة Mac بمعالجات Intel غير مدعومة)؛ ويُثبَّت iOS عبر [TestFlight](https://testflight.apple.com/join/j88d69jx). لا يوجد لنظام Linux إصدار جاهز للتطبيق بعد؛ ابنِه من المصدر. ويصدر Fushi Server بلا واجهة رسومية بشكل منفصل على [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> يتطلب Android 7.0 (API 24) أو أحدث.

## البناء

تحضير بأمر واحد (`flutter pub get` + apply patches)، ثم البناء:

```bash
# From the repository root
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Headless server (from packages/fushi_server; use `dart build cli`, not `dart compile exe`)
dart build cli
```

يَدمج `tool/bootstrap.sh` / `tool/bootstrap.ps1` كلًّا من `flutter pub get` و`ci/apply-patches.sh` في أمر واحد. هذا المشروع مثبَّت على Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`)؛ ولا تستطيع إصدارات Flutter الأقدم بناءه لأن Material وCupertino يُستخدمان كحزمتَي `material_ui` / `cupertino_ui`. بعض التبعيات المنبع مُضمَّنة ضمن `third_party/` أو مُرقَّعة بواسطة `ci/apply-patches.sh` — راجع [docs/agent/build.md](../agent/build.md) للتفاصيل، بما فيها تبعيات بناء سطح مكتب Linux.

<details>
<summary><b>حزمة التقنيات</b></summary>

| الطبقة | التقنية |
|---|---|
| إطار العمل | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`)، Riverpod |
| المنصّات | Android / Windows / macOS / iOS / Linux، إضافةً إلى خادم بلا واجهة رسومية |
| الواجهة | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| القارئ | محرّك ترقيم صفحات WebView (مُشتقّ من عائلة Hoshi Reader) |
| الفيديو | media_kit (نواة libmpv) + libplacebo |
| التخزين | Drift (SQLite, WAL) + fushidicts (محرّك قاموس C++ FFI) |
| معالجة اللغة الطبيعية | جداول تحويل Yomitan (التأصيل متعدّد اللغات) + kana_kit (تحويل الكانا)؛ التقسيم إلى وحدات عبر fushidicts FFI |
| الذكاء الاصطناعي على الجهاز | ONNX Runtime للتعرّف على الكلام (توليد الترجمات) وOCR المانغا؛ والخوارزميات في [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| التنزيلات | libtorrent 2.x عبر جسر FFI بواجهة C-ABI (qBittorrent الخارجي بديلًا احتياطيًا) |
| المزامنة | خوادم سحابية + Fushi Interconnect (الشبكة المحلية LAN، والعناوين البعيدة، ونفق iroh P2P) |
| المحرّك المشترك | `fushi_engine` — نواة Dart خالصة يتشاركها التطبيق وFushi Server |
| إنشاء البطاقات | AnkiDroid API + AnkiConnect |
| التدويل | Slang (17 لغة) |

</details>

<details>
<summary><b>بنية المشروع</b></summary>

```
Fushi/                      # Repository root (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (library pages, reader, video player, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Books, manga, video, audiobooks, online sources
│   │   │   ├── lookup/      # Dictionary lookup popups and overlays
│   │   │   ├── mining/      # Card creation (incl. galgame mining)
│   │   │   ├── sync/        # Cloud sync, Interconnect, media servers
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project
├── packages/                # Dart packages
│   ├── fushi_core/          #   Database schema, preferences
│   ├── fushi_engine/        #   Pure-Dart engine shared with the server
│   ├── fushi_server/        #   Headless server CLI + web UI
│   ├── fushi_cli/           #   Desktop command-line client
│   ├── fushi_dictionary/    #   Dictionary engine bindings and importers
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent / iroh FFI bindings
│   └── …                    #   Vendored forks (inappwebview Windows/Linux, gamepads)
├── native/                  # Native sources: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Log collector and leaderboard backends (deployed separately)
├── tools/browser-extension/ # Browser lookup extension
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and CI scripts
├── tool/                    # bootstrap / setup_worktree / bug tracker scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

يدعم استيراد الفيديو التجميع حسب العمل أو المجلد. راجع [سير عمل الفيديو](../specs/2026-09-07-video-library-workflow.md) و[بيانات MAL/TMDB الوصفية مع تجزئة ملفات AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) للاطلاع على المطابقة والمهام الخلفية.

يشرح [إعداد الخدمات الاختيارية عبر الإنترنت](../specs/2026-09-07-online-services-setup.md) هويات التطبيق المضمَّنة وبيانات الاعتماد الشخصية وتذكير إعداد الفيديو القابل للإغلاق.

## الخصوصية والبيانات

يُخزّن Fushi الكتب والقواميس والخطوط وبيانات الكتب الصوتية ومقاطع الفيديو وتقدّم القراءة والإبرازات والإحصاءات والإعدادات المُستورَدة في التخزين المحلّي للتطبيق.

- **المزامنة** — يستخدم Google Drive / OneDrive / Dropbox تسجيل الدخول عبر OAuth؛ ويستخدم WebDAV / FTP / SFTP / Fushi Server عنوان الخادم وبيانات الاعتماد التي تقدّمها. يربط Fushi Interconnect الأجهزة المقترنة مباشرةً (الشبكة المحلية أو IPv6 أو الشبكات الافتراضية أو العناوين العامة)، ويعود إلى نفق iroh P2P مشفّر من طرف إلى طرف عند تعذّر أي مسار مباشر؛ وتطلب روابط الاقتران التأكيد دائمًا.
- **Anki** — يتواصل إنشاء البطاقات مع AnkiDroid أو عنوان AnkiConnect الذي تُهيّئه.
- **إحصاءات الاستخدام** — مرة واحدة يوميًا، ترسل إصدارات سطح المكتب وAndroid معرّف تثبيت عشوائيًا وإصدار التطبيق والمنصّة وقناة التحديث إلى fushi.moe لإحصاء المستخدمين النشطين؛ ولا تُرسَل أي بيانات حساب أو مكتبة أو قراءة ولا تُخزَّن عناوين IP. أوقفها عبر *مشاركة إحصاءات الاستخدام* في إعدادات التحديث. لا ترسلها إصدارات iOS.
- **فقط عندما تطلب ذلك** — رفع السجلات (بعد مطالبة موافقة لمرة واحدة)، والملاحظات داخل التطبيق، ولوحة المتصدّرين (معطّلة افتراضيًا؛ ترفع عناوين مكتبتك وتقدّمك فقط بعد اشتراكك).
- **OCR المانغا** — المحرّك الافتراضي هو Google Lens، الذي يرسل صورة الصفحة إلى Google؛ انتقل في الإعدادات إلى النموذج على الجهاز أو OCR النظام لإبقاء الصور محلية.
- **ميزات الذكاء الاصطناعي** — تُرسَل الطلبات فقط إلى مزوّد LLM الذي تُهيّئه وتُسنده إلى ميزة؛ وإن لم يُسنَد أي مزوّد فلا يُرسَل شيء.
- **خدمات الجهات الخارجية** — تتصل ميزات البيانات الوصفية والترجمات والمصادر عبر الإنترنت بالخدمات المدرجة تحت [مصادر المحتوى والتكاملات](#مصادر-المحتوى-والتكاملات) فقط عند استخدامك لها.

## نشاط التطوير

[![نشاط التطوير](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

يصل العمل اليومي إلى `develop`؛ ولا يتلقّى `main` سوى عمليات دمج الإصدارات. يُعرض المخطط هنا على `main` لكنه يُولَّد من `develop`، فيعكس التطوير الفعلي لا حركة الدمج.

المسارات الثلاثة هي قنوات التحديث التي يقدّمها التطبيق نفسه، ويُقاس كل منها بذروته الخاصة — فعدد إصدارات debug يفوق الإصدارات المستقرة بمرتبتين من الحجم، لذا فإن مقياسًا مشتركًا سيسحق المسارين الآخرين إلى لا شيء.

| المسار | ما الذي يُحتسب | كيف تحصل عليه |
|---|---|---|
| **Debug (متجدّد)** | عمليات البناء الناجحة عند push لملف [release.yml](../../.github/workflows/release.yml) | إصدار تجريبي متجدّد يُعاد نشره عند كل push |
| **Beta** | الإصدارات التجريبية `v<version>-beta.<seq>` | بناء اختباري يُشغَّل يدويًا |
| **مستقر** | إصدارات `v<version>` | أحدث إصدار |

> يُولَّد المخطط أعلاه داخل هذا المستودع (دون خدمة طرف ثالث) ويُحدَّث يوميًا بواسطة سير العمل [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## سجل النجوم

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![سجل النجوم](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> يُولَّد المخطط أعلاه داخل هذا المستودع (دون خدمة طرف ثالث) ويُحدَّث يوميًا بواسطة سير العمل [Update Star History](../../.github/workflows/star-history.yml).

## شكر وتقدير

يُبنى Fushi على المشاريع والمنظومة التالية:

### أدوات التعلم والمشاريع المرجعية

| المشروع | الوصف |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | أداة تعلّم اللغة اليابانية بأسلوب الانغماس |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | قارئ اللغة اليابانية على iOS؛ مرجع محرّك ترقيم صفحات القارئ |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | قارئ اللغة اليابانية الأصيل على Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | محرّك قاموس C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | حلّ مزامنة الكتب الصوتية |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | خوارزمية محاذاة توقيت الترجمة مع مرجع (GPL-3.0)؛ أساس المحاذاة التلقائية للترجمات المنزَّلة مع المسارات المضمَّنة |
| [Yomitan](https://github.com/yomidevs/yomitan) | مرجع تنسيق القاموس وجداول التحويل وتجربة البحث عن الكلمات |
| [Lapis](https://github.com/donkuri/lapis) | نوع ملاحظات Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | تكامل إنشاء البطاقات على Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | مرجع الصوت المحلّي والتفاعل مع AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | مرجع القارئ والإحصاءات وتوافق المزامنة |
| [media_kit](https://github.com/media-kit/media-kit) | إطار تشغيل الفيديو في Flutter (نواة libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | مجموعة تعلّم اللغات بأسلوب الانغماس لنظام macOS |

### المحركات والمكونات الأصلية

| المشروع | الوصف |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | محرك اعتراض نصوص الـ galgame (ملفات DLL مرفقة يحمّلها الحاقن) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | مكتبة اعتراض inline يستخدمها حاقن الـ galgame |
| [libtorrent](https://github.com/arvidn/libtorrent) | محرك تنزيل التورنت المدمج |
| [mpv](https://github.com/mpv-player/mpv) | نواة التشغيل libmpv خلف media_kit |
| [FFmpeg](https://ffmpeg.org) | فحص الوسائط والاقتصاص واستخراج الصوت |
| [libplacebo](https://github.com/haasn/libplacebo) | مظللات الفيديو على الـ GPU وتعيين ألوان HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | محرك WebView الذي يعرض قارئ EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | الاستدلال على الجهاز للتعرف على الكلام و OCR |
| [iroh](https://github.com/n0-computer/iroh) | نفق P2P لاتصالات Fushi Interconnect البعيدة |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | اعتماديات محرك القواميس |

### النماذج على الجهاز

| المشروع | الوصف |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | حزم نماذج التعرف على الكلام Zipformer وبنى VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | نموذج التعرف على الكلام الياباني |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | نموذج التعرف على الكلام الياباني |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | نموذج التعرف على الكلام الياباني (CC BY-NC 4.0، يُنزَّل من مستودعه على Hugging Face) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | نموذج تعرف على الكلام متعدد اللغات بتقنية CTC |
| [Silero VAD](https://github.com/snakers4/silero-vad) | نموذج كشف نشاط الصوت |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | نموذج كشف نصوص وفقاعات حوار المانغا |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | نموذج كشف إطارات المانغا، مدرَّب على [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | كشف أسطر النص والتعرّف عليها؛ ونموذج rec المضبوط للمانغا (المدرَّب على [Manga109-s](http://www.manga109.org/en/download_s.html) و[AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) هو ما يشغّل نموذج OCR المحلي بتقنية CTC لكل عمود |

> نموذج كشف إطارات المانغا وPP-OCRv6_manga مدرَّبان على مجموعة بيانات Manga109-s (Matsui et al. 2017; Aizawa et al. 2020)، وتشترط شروطها الإشارة بوضوح إلى هذا الاستخدام لمجموعة البيانات. وقد دُرّب PP-OCRv6_manga (Apache-2.0) إضافةً على مجموعة بيانات AnimeText المرخَّصة بموجب CC BY-NC-SA 4.0؛ ويُنزّل التطبيق ذلك النموذج من مستودعه على Hugging Face ولا يعيد توزيعه.

### مصادر المحتوى والتكاملات

| المشروع | الوصف |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | منظومة إضافات مصادر المانغا |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | منظومة إضافات مصادر الأنمي (extensions-lib 14–16 بنفس بيئة التشغيل) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | بيئة تشغيل إضافات المانغا لسطح المكتب (مضمَّنة، MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | مرجع تكييف إضافات Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | منظومة إضافات مصادر الروايات الخفيفة |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | خوادم وسائط يمكن تصفحها من مكتبة الفيديو |
| [asbplayer](https://github.com/asbplayer/asbplayer) | مرجع جسر ترجمات البث لإضافة المتصفح |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | مرجع معماري لتعريف الأنمي وجمع بياناته |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | مرجع معمارية معلومات مكتبة الـ galgame |
| [AniDB](https://anidb.net) | هوية الأنمي والحلقات والملفات |
| [MyAnimeList](https://myanimelist.net) (عبر [Jikan](https://jikan.moe)) | بيانات الأنمي الوصفية |
| [TMDB](https://www.themoviedb.org) | بيانات وصفية وصور تكميلية |
| [VNDB](https://vndb.org) | بيانات الروايات المرئية الوصفية |
| [Jimaku](https://jimaku.cc) | مصدر ترجمات يابانية |
| [OpenSubtitles](https://www.opensubtitles.com) | مصدر ترجمات |

> يستخدم هذا التطبيق TMDB وواجهات TMDB البرمجية لكنه غير معتمد أو مُصدّق أو موافق عليه من TMDB.

## الترخيص

موزَّع بموجب رخصة GNU General Public License v3.0. راجع [LICENSE](../../LICENSE) للتفاصيل.

## المشرف على المشروع

يتولّى [hajisensai](https://github.com/hajisensai) صيانة Fushi. الموقع: [fushi.moe](https://fushi.moe). للتواصل: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | **العربية**

</div>
