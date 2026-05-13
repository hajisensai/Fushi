<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Иммерсивная читалка японского для Android</p>
<p align="center">EPUB · Словарь · Anki · Синхронизация аудиокниг</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <b>Русский</b> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Введение

**hibiki** — приложение для чтения на Android для изучающих японский язык.

## Возможности

### Чтение EPUB
- Встроенный рендеринг EPUB через [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) (WebView)
- Нажмите для поиска слова, выделите для анализа
- Настраиваемые шрифты и темы (светлая/тёмная)
- Статистика чтения и закладки
- Два режима: непрерывная прокрутка / постраничный

### Словарь
- Импорт словарей в формате [Yomitan](https://github.com/yomidevs/yomitan) (ранее Yomichan)
- Поддержка тонального ударения и данных о частотности
- Параллельный поиск по нескольким словарям, история поиска
- Деконъюгация Ve

### Карточки Anki
- Экспорт одним нажатием в [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Автоматическое заполнение контекстных предложений
- Запись аудио и обрезка скриншотов
- Множественные профили экспорта, настраиваемое сопоставление полей
- Быстрые действия (Quick Actions) для создания карточки в один шаг

### Синхронизация аудиокниг (Sasayaki)
- Форматы субтитров: SRT / LRC / VTT / ASS
- Автоматическое выравнивание субтитров по тексту EPUB
- Подсветка при чтении вслед, синхронный переход страниц
- Панель управления воспроизведением (прогресс, навигация, скорость)

### Прочее
- 17 языков интерфейса
- Множественные профили пользователей
- Режим инкогнито
- Поиск слов через отправку текста из других приложений

## Поддерживаемые языки

Интерфейс поддерживает следующие языки:

| Язык | Код |
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

## Технологический стек

| Уровень | Технология |
|---|---|
| Фреймворк | Flutter 3.41.6 / Dart 3.11.4 |
| Читалка | ttu Ebook Reader (WebView, [форк](https://github.com/hdjsadgfwtg/ttu-fork)) |
| Хранение | Isar + Drift (SQLite) + hoshidicts (движок словарей C++ FFI) |
| NLP | Ve (деконъюгация) |
| Создание карточек | AnkiDroid API |
| Интернационализация | Slang |
| Минимальная версия | Android 8.0 (API 26) |

## Сборка

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **Перед первой сборкой необходимо применить патчи pub cache.** Если pub cache очищен или повторно выполнен `pub get`, все патчи необходимо применить заново. См. раздел [Зависимости и патчи](#зависимости-и-патчи) ниже.

## Зависимости и патчи

Проект привязан к Flutter 3.41.6. Некоторые зависимости ещё не адаптированы и требуют ручного исправления исходного кода в pub cache.

<details>
<summary><b>Патчи изменений API Flutter</b></summary>

| Пакет | Изменения |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; замена удалённого `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | Аналогично `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Добавление `hide CarouselController` во внутренние импорты для избежания конфликтов имён |
| `fading_edge_scrollview` 3.0.0 | Исправление nullable для `PageView.controller` |

</details>

<details>
<summary><b>Патчи удаления v1 embedding</b></summary>

Flutter 3.41.6 полностью удалил API v1 embedding (`PluginRegistry.Registrar`). Следующие плагины требуют удаления соответствующих ссылок:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Патчи Gradle / Kotlin</b></summary>

| Цель | Изменения |
|---|---|
| `android/build.gradle` afterEvaluate | Принудительный `compileSdkVersion 34` для подпроектов; удаление `-Werror` |
| `audio_session` 0.1.14 | Удаление `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Исправление null-безопасности Kotlin |
| `receive_intent` (git) | Исправление null-безопасности Kotlin |

</details>

<details>
<summary><b>Git-зависимости</b></summary>

| Пакет | Источник |
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

## Структура проекта

```
hibiki/
├── hibiki/                  # Основной каталог Flutter-приложения
│   ├── lib/
│   │   ├── i18n/            # Интернационализация (17 языков)
│   │   ├── src/
│   │   │   ├── pages/       # Страницы (книжная полка, читалка, словарь, настройки и др.)
│   │   │   ├── media/       # Мост аудиокниг, разбор субтитров
│   │   │   ├── dictionary/  # Движок поиска по словарю
│   │   │   ├── models/      # Модели данных и управление состоянием
│   │   │   └── language/    # Уровень абстракции языка
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # Артефакты сборки форка ttu
│   └── android/
│       └── app/src/main/cpp/ # Движок словарей C++ hoshidicts
├── docs/                    # Документация разработки
└── chisa/                   # Справочник ранних версий jidoujisho
```

## Благодарности

| Проект | Описание |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Инструмент иммерсивного изучения японского |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Читалка японского для Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Движок словарей C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Читалка японского для iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Решение для синхронизации аудиокниг |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Движок рендеринга EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Версия ttu от сообщества (SvelteKit v2), upstream-база форка hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Источник формата словарей |

## Лицензия

[GNU General Public License v3.0](../../LICENSE)
