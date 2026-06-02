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
- Рендеринг EPUB в WebView (постраничный движок на основе [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
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
| Фреймворк | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Платформа | Android / iOS / macOS / Windows / Linux (адаптивный Material 3 + Cupertino) |
| Читалка | Постраничный движок на WebView (на основе [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Хранение | Drift (SQLite, WAL) + hoshidicts (движок словарей C++ FFI) |
| NLP | Ve (деконъюгация) |
| Создание карточек | AnkiDroid API |
| Интернационализация | Slang (17 языков) |
| Минимальная версия | Android 7.0 (API 24) |

## Сборка

Подготовка одной командой (`flutter pub get` + применение патчей), затем сборка:

```bash
# в корне репозитория
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # или (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` сводит два действия в одну команду: ① `flutter pub get`; ② запуск `ci/apply-patches.sh`. `melos bootstrap` через post hook выполняет то же самое (в Windows у melos есть баг с кодировкой CJK, поэтому используйте `tool/bootstrap.ps1`).

> **О патчах:** `ci/apply-patches.sh` накладывает изменения из `ci/patches/` поверх фактического pub cache. После каждой очистки pub cache или повторного `flutter pub get` его необходимо запускать заново (bootstrap уже включает этот шаг). Если скрипт не находит ни одной цели патча, он пропускает её с предупреждением, а не имитирует успех.

## Зависимости и патчи

Проект привязан к Flutter 3.41.6, часть upstream-зависимостей ещё не адаптирована. Исправления идут двумя путями: ① пакеты, которые должны быть входными данными сборки и воспроизводиться одинаково на разных машинах, vendored в `third_party/` и подключены через `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **без** патча pub cache); ② остальные пакеты исправляет `ci/apply-patches.sh` в исходниках pub cache. Подробности механизма см. в [docs/agent/build.md](../agent/build.md). Свёрнутые таблицы ниже — исторический список по категориям изменений; для пакетов, пересекающихся с механизмом ①, приоритет имеет vendored-версия.

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
| `android/build.gradle` afterEvaluate | Принудительный `compileSdk` для подпроектов (по умолчанию 36, отдельные 34); удаление `-Werror` |
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
hibiki/                      # Корень репозитория (Melos workspace: hibiki_workspace)
├── hibiki/                  # Основной каталог Flutter-приложения
│   ├── lib/
│   │   ├── i18n/            # Интернационализация (17 языков, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Страницы (книжная полка, читалка, словарь, настройки и др.)
│   │   │   ├── reader/      # JS/CSS-скрипты WebView читалки
│   │   │   ├── media/       # Аудиокниги, разбор субтитров, reader source
│   │   │   └── models/      # Модели данных и управление состоянием (AppModel)
│   │   └── main.dart
│   └── android/             # Android-проект (manifest, native hoshidicts)
├── packages/                # Внутренние package + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # vendored патч-пакеты (подключены через dependency_overrides)
├── ci/                      # Скрипты патчей сборки и интеграционных тестов
├── tool/                    # Скрипты bootstrap / i18n_sync и др.
└── docs/                    # Документация разработки (включая руководство agent в docs/agent/)
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
