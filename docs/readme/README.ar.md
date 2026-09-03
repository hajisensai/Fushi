<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="شعار Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | **العربية**

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![تنزيل أحدث إصدار](https://img.shields.io/badge/%E2%AC%87%20%D8%AA%D9%86%D8%B2%D9%8A%D9%84%20%D8%A3%D8%AD%D8%AF%D8%AB%20%D8%A5%D8%B5%D8%AF%D8%A7%D8%B1-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![انضم إلى Discord](https://img.shields.io/badge/%D8%A7%D9%86%D8%B6%D9%85%20%D8%A5%D9%84%D9%89%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## دعم المنصّات

| المنصّة | الحالة | العرض / الواجهة |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> الحدّ الأدنى Android 7.0 (API 24). تُحدَّد اللغات المتاحة للبحث في القاموس بناءً على القواميس المُستورَدة وجداول تحويل Yomitan، بشكل مستقلّ عن لغة الواجهة.

### لغات الواجهة (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## التثبيت والبناء

تحضير بأمر واحد (`flutter pub get` + apply patches)، ثم البناء:

```bash
# From the repository root
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows desktop
flutter build windows --release
```

يَدمج `tool/bootstrap.sh` / `tool/bootstrap.ps1` كلًّا من `flutter pub get` و`ci/apply-patches.sh` في أمر واحد. هذا المشروع مثبَّت على Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`)؛ بعض التبعيات المنبع مُضمَّنة ضمن `third_party/` أو مُرقَّعة بواسطة `ci/apply-patches.sh` — راجع [docs/agent/build.md](../agent/build.md) للتفاصيل.

<details>
<summary><b>حزمة التقنيات</b></summary>

| الطبقة | التقنية |
|---|---|
| إطار العمل | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| المنصّات | Android / Windows / macOS / iOS (Material Design 3) |
| القارئ | محرّك ترقيم صفحات WebView (مُشتقّ من عائلة Hoshi Reader) |
| الفيديو | media_kit (نواة libmpv) |
| التخزين | Drift (SQLite, WAL) + fushidicts (محرّك قاموس C++ FFI) |
| معالجة اللغة الطبيعية | جداول تحويل Yomitan (التأصيل متعدّد اللغات) + kana_kit (تحويل الكانا)؛ التقسيم إلى وحدات عبر fushidicts FFI |
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
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native fushidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # fushidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## الخصوصية والبيانات

يُخزّن Fushi الكتب والقواميس والخطوط وبيانات الكتب الصوتية ومقاطع الفيديو وتقدّم القراءة والإبرازات والإحصاءات والإعدادات المُستورَدة في التخزين المحلّي للتطبيق.

تستخدم المزامنة السحابية (Google Drive / OneDrive / Dropbox) بيانات اعتماد OAuth التي يُهيّئها المستخدم؛ ويستخدم WebDAV / FTP / SFTP عناوين الخوادم وبيانات الاعتماد التي يُقدّمها المستخدم؛ ويتّصل Fushi Interconnect مباشرةً عبر عنوان يُهيّئه المستخدم. يتواصل إنشاء بطاقات Anki مع AnkiDroid أو عنوان AnkiConnect المُهيّأ.

## شكر وتقدير

يُبنى Fushi على المشاريع والمنظومة التالية:

| المشروع | الوصف |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | أداة تعلّم اللغة اليابانية بأسلوب الانغماس |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | قارئ اللغة اليابانية على iOS؛ مرجع محرّك ترقيم صفحات القارئ |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | قارئ اللغة اليابانية الأصيل على Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | محرّك قاموس C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | حلّ مزامنة الكتب الصوتية |
| [Yomitan](https://github.com/yomidevs/yomitan) | مرجع تنسيق القاموس وجداول التحويل وتجربة البحث عن الكلمات |
| [Lapis](https://github.com/donkuri/lapis) | نوع ملاحظات Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | تكامل إنشاء البطاقات على Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | مرجع الصوت المحلّي والتفاعل مع AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | مرجع القارئ والإحصاءات وتوافق المزامنة |
| [media_kit](https://github.com/media-kit/media-kit) | إطار تشغيل الفيديو في Flutter (نواة libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | مجموعة تعلّم اللغات بأسلوب الانغماس لنظام macOS |

## الترخيص

موزَّع بموجب رخصة GNU General Public License v3.0. راجع [LICENSE](../../LICENSE) للتفاصيل.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | **العربية**

</div>
