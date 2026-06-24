<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>اقرأ كتاباً، واجعل كل كلمة جديدة ملكاً لك.</b></p>
<p align="center">قارئ غامر متعدد المنصات ومتعدد اللغات —— قراءة EPUB · البحث عن الكلمات باللمس · إنشاء بطاقات Anki · مزامنة الكتب الصوتية · البحث عن الكلمات من ترجمات الفيديو</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 الصفحة الرئيسية للمشروع (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <b>العربية</b> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## مقدمة

**hibiki** هو قارئ غامر لتعلم اللغات يعمل على منصات متعددة. داخل نص EPUB يمكنك **النقر للبحث عن الكلمات، وتحديد كلمة لتحليلها** مباشرةً، وتحويل الكلمات الجديدة إلى بطاقات Anki بنقرة واحدة؛ كما يجعل صوت الكتاب الصوتي يتزامن مع النص ويُبرزه جملةً جملة؛ بل ويتيح البحث عن الكلمات وإنشاء البطاقات مباشرةً من ترجمات الفيديو. أداة واحدة تغطي مسارات الإدخال الغامر الثلاثة لديك: «اقرأ · استمع · شاهد».

يغطي البحث في القاموس **جميع لغات التحويل** في [Yomitan](https://github.com/yomidevs/yomitan) (التصريف العكسي + تطبيع النص قبل البحث)، والواجهة موطّنة إلى **17 لغة**، ويدعم المنصات الخمس **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="رف الكتب" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="البحث عن الكلمات" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="الإعدادات والسمات" width="300">
</p>
<p align="center"><sub>رف الكتب · البحث عن الكلمات · الإعدادات والسمات</sub></p>

---

## أبرز الميزات

### 📖 قراءة EPUB، انقر للبحث فوراً

قارئ EPUB يُعرض عبر WebView (محرك تقسيم صفحات مشتق من [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))، انقر على أي كلمة لبحث فوري، وحدّد نصاً لتحليل فوري. وضعان للتمرير المستمر وتقسيم الصفحات، خطوط وسمات مخصصة (فاتحة / داكنة / سوداء صرفة / مخصصة)، مع الفوريغانا وإحصائيات القراءة والعلامات المرجعية، كلها متوفرة.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="قراءة عمودية · فوريغانا · مزامنة الكتب الصوتية" width="300">
</p>
<p align="center"><sub>نص عمودي · فوريغانا · إبراز الكلمة المحددة · شريط التحكم بمزامنة الكتب الصوتية في الأسفل</sub></p>

### 🔍 البحث عن الكلمات باللمس، يغطي جميع لغات التحويل في Yomitan

استورد قواميس بصيغ متعددة: **Yomitan** (سابقاً Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. استرجاع شكل الكلمة متعدد اللغات (جداول تحويل Yomitan) + تطبيع النص قبل البحث (الأحرف الكبيرة/الصغيرة / علامات التشكيل / حركات العربية)، مدفوعاً بنقاط الترميز (code point) دون الحاجة لتبديل اللغة. بحث متوازٍ في عدة قواميس، أولوية المصادر الفرعية وتفعيلها/تعطيلها، تأشير النبرة وتردد الكلمات، كل ذلك يتم في نافذة واحدة.

### 🎴 إنشاء بطاقات Anki بخطوة واحدة

عند العثور على كلمة جديدة، صدّرها بخطوة واحدة إلى [AnkiDroid](https://github.com/ankidroid/Anki-Android) و AnkiConnect. يتضمن schema لنوع ملاحظة [Lapis](https://github.com/donkuri/lapis) (vendored 1.7.0)، ويمكنك إنشاء قوالب البطاقات والمجموعات مباشرةً داخل التطبيق؛ ملء تلقائي لجمل السياق، دعم التسجيل الصوتي وقص لقطات الشاشة، ملفات تصدير متعددة (Profile)، تعيين حقول مخصص، وإجراءات سريعة لإنشاء البطاقة بخطوة واحدة.

### 🎧 مزامنة الكتب الصوتية (Sasayaki)

يدعم ترجمات SRT / LRC / VTT / ASS، ويحاذي نص الترجمة تلقائياً مع نص EPUB. أثناء التشغيل **يتم الإبراز تتبعاً للقراءة، وتقليب الصفحات متزامن مع الصوت**، مع شريط التحكم بالتشغيل (التقدم، القفز، السرعة)؛ وأثناء الاستماع يُضاء النص جملةً جملة —— وشريط التحكم أسفل لقطة شاشة القراءة في أعلى هذه الصفحة هو هذه الميزة بعينها.

### 🎬 البحث عن الكلمات من ترجمات الفيديو

مشغّل فيديو مدمج قائم على media_kit / libmpv، يدعم الترجمات المدمجة / الخارجية. أثناء تشغيل الفيديو يمكنك **البحث عن الكلمات وإنشاء البطاقات مباشرةً على الترجمة**، فتدخل المواد المرئية أيضاً ضمن الإدخال الغامر؛ مع تسجيل إحصائيات مدة المشاهدة وعدد البطاقات المنشأة.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 لقطة شاشة مشغّل الفيديو ستُضاف لاحقاً —— يلزم التقاطها على جهاز حقيقي / في المقدمة (صورة الفيديو + شريط الترجمة + نافذة البحث عن الكلمات، انظر الشرح أدناه).</sub></p>

### 🔗 المزيد

- **17 لغة للواجهة**، موطّنة على كل المنصات
- **Hibiki Interconnect**: مزامنة الكتب / القواميس / الكتب الصوتية / تقدم القراءة بين الأجهزة
- **ملفات تعريف مستخدمين متعددة (Profile)**، تبديل تلقائي لكل كتاب
- **وضع التصفح المتخفي**؛ **مشاركة نص من تطبيقات أخرى للبحث المباشر عن الكلمات**

---

## المنصات المدعومة

| المنصة | الحالة | العرض / الواجهة |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (نسخة fork من `flutter_inappwebview_windows` تعرض EPUB) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> الحد الأدنى Android 7.0 (API 24). تُحدَّد لغة البحث في القاموس حسب القاموس المستورد وجداول تحويل Yomitan، وهي مستقلة عن لغة الواجهة.

### لغات الواجهة (17 لغة)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## التثبيت والبناء

تحضير بأمر واحد (`flutter pub get` + تطبيق التصحيحات)، ثم البناء:

```bash
# في جذر المستودع
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # أو (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

يجمع `tool/bootstrap.sh` / `tool/bootstrap.ps1` بين ① `flutter pub get` و ② `ci/apply-patches.sh` في أمر واحد. يقفل هذا المشروع على Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`)؛ وبعض التبعيات الأصلية مدمجة (vendored) في `third_party/` أو مُصحَّحة بواسطة `ci/apply-patches.sh` —— تفاصيل الآلية، وبناء المنصات الخمس، وقائمة التبعيات والتصحيحات في [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>نظرة سريعة على المكدس التقني</b></summary>

| الطبقة | التقنية |
|---|---|
| إطار العمل | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| المنصة | Android / iOS / macOS / Windows / Linux (تكيُّف Material 3 + Cupertino) |
| القارئ | محرك تقسيم الصفحات WebView (مشتق من [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| الفيديو | media_kit / libmpv |
| التخزين | Drift (SQLite, WAL) + hoshidicts (محرك قاموس C++ FFI) |
| NLP | جداول تحويل Yomitan (استرجاع شكل الكلمة متعدد اللغات) + kana_kit (تحويل الكانا)؛ التقطيع عبر hoshidicts FFI |
| إنشاء البطاقات | AnkiDroid API + AnkiConnect |
| التدويل | Slang (17 لغة) |

</details>

<details>
<summary><b>هيكل المشروع</b></summary>

```
hibiki/                      # جذر المستودع (Melos workspace: hibiki_workspace)
├── hibiki/                  # الدليل الرئيسي لتطبيق Flutter
│   ├── lib/
│   │   ├── i18n/            # التدويل (17 لغة، Slang)
│   │   ├── src/
│   │   │   ├── pages/       # الصفحات (رف الكتب، القارئ، القاموس، الإعدادات، إلخ)
│   │   │   ├── reader/      # سكربتات JS/CSS للقارئ في WebView
│   │   │   ├── media/       # الكتب الصوتية، تحليل الترجمات، reader source
│   │   │   └── models/      # نماذج البيانات وإدارة الحالة (AppModel)
│   │   └── main.dart
│   └── android/             # مشروع Android (manifest، hoshidicts الأصلي)
├── packages/                # حزم داخلية + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # محرك القاموس C++ hoshidicts (FFI)
├── third_party/             # حزم تصحيح مدمجة (vendored، يشير إليها dependency_overrides)
├── ci/                      # سكربتات تصحيح البناء واختبارات التكامل
├── tool/                    # سكربتات bootstrap / i18n_sync، إلخ
└── docs/                    # وثائق التطوير (تشمل دليل عمليات الوكيل في docs/agent/)
```

</details>

---

## شكر وتقدير

| المشروع | الوصف |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | أداة تعلم اللغة اليابانية الغامرة |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | قارئ ياباني لأندرويد |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | محرك قاموس C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | قارئ ياباني لنظام iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | حل مزامنة الكتب الصوتية |
| [Yomitan](https://github.com/yomidevs/yomitan) | مصدر صيغة القاموس وجداول التحويل |
| [Lapis](https://github.com/donkuri/lapis) | نوع ملاحظة Anki |

## الرخصة

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <b>العربية</b> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
