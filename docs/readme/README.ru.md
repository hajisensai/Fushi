<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Читайте книгу и делайте каждое незнакомое слово своим.</b></p>
<p align="center">Кроссплатформенная многоязычная иммерсивная читалка — чтение EPUB · поиск слов по выделению · создание карточек Anki · синхронизация аудиокниг · поиск слов в субтитрах видео</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Главная страница проекта (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <b>Русский</b> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Введение

**hibiki** — кроссплатформенная иммерсивная читалка для изучения языков. Прямо в тексте EPUB **нажмите, чтобы искать слово, выделите, чтобы анализировать**, и превращайте незнакомое слово в карточку Anki одним нажатием; синхронизируйте аудио аудиокниги с текстом, подсвечивая его фраза за фразой; и даже ищите слова и создавайте карточки прямо в субтитрах видео. Один инструмент охватывает три формы иммерсивного ввода: «читать · слушать · смотреть».

Поиск по словарю охватывает **все языки трансформации** [Yomitan](https://github.com/yomidevs/yomitan) (деинфлексия + нормализация текста перед поиском), интерфейс локализован на **17 языков**, а приложение поддерживает все пять платформ **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Книжная полка" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Поиск слов" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Настройки и темы" width="300">
</p>
<p align="center"><sub>Книжная полка · Поиск слов · Настройки и темы</sub></p>

---

## Ключевые возможности

### 📖 Чтение EPUB, поиск одним нажатием

EPUB-читалка, отрисованная в WebView (постраничный движок на основе [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)): нажмите на любое слово для мгновенного поиска, выделите область для мгновенного анализа. Два режима — непрерывная прокрутка и постраничный, настраиваемые шрифты и темы (светлая / тёмная / чисто-чёрная / пользовательская), фуригана, статистика чтения и закладки — всё на месте.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Вертикальное чтение · Фуригана · Синхронизация аудиокниги" width="300">
</p>
<p align="center"><sub>Вертикальный текст · Фуригана · Подсветка по выделению · Панель синхронизации аудиокниги внизу</sub></p>

### 🔍 Поиск по выделению, охватывает все языки трансформации Yomitan

Импортируйте словари в форматах **Yomitan** (ранее Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Многоязычная лемматизация (таблицы трансформации Yomitan) + нормализация текста перед поиском (регистр / диакритика / арабская харакат), управляемая по кодовым точкам, без переключения языка. Параллельный поиск по нескольким словарям, приоритет и включение/отключение подысточников, разметка тонального ударения и частотность слов — всё в одном всплывающем окне.

### 🎴 Создание карточек Anki одним нажатием

Найдя незнакомое слово, экспортируйте его в один шаг в [AnkiDroid](https://github.com/ankidroid/Anki-Android) и AnkiConnect. Встроенная схема типа заметки [Lapis](https://github.com/donkuri/lapis) (vendored 1.7.0) позволяет создавать шаблоны карточек и колоды прямо в приложении; автозаполнение контекстных предложений, поддержка записи аудио и обрезки скриншотов, множественные профили экспорта (Profile), настраиваемое сопоставление полей и быстрые действия для создания карточки в один жест.

### 🎧 Синхронизация аудиокниг (Sasayaki)

Поддержка субтитров SRT / LRC / VTT / ASS с автоматическим выравниванием текста субтитров по тексту EPUB. При воспроизведении — **подсветка при чтении вслед и синхронный переход страниц**, дополненные панелью управления воспроизведением (прогресс, навигация, скорость): при прослушивании текст загорается фраза за фразой — панель управления внизу скриншота чтения в верхней части этой страницы иллюстрирует именно эту возможность.

### 🎬 Поиск слов в субтитрах видео

Встроенный видеоплеер на основе media_kit / libmpv с поддержкой встроенных / внешних субтитров. Во время воспроизведения видео **ищите слова и создавайте карточки прямо в субтитрах**, включая видеоматериалы в иммерсивный ввод; также подсчитываются время просмотра и количество созданных карточек.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Скриншот видеоплеера будет добавлен</sub></p>

### 🔗 И ещё

- **17 языков интерфейса**, локализация на всех платформах
- **Hibiki-интерконнект**: синхронизация книг / словарей / аудиокниг / прогресса чтения между устройствами
- **Множественные пользовательские профили (Profile)**, автоматическое переключение по книге
- **Режим инкогнито**; **прямой поиск через отправку текста** из других приложений

---

## Поддержка платформ

| Платформа | Статус | Рендеринг / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (форк `flutter_inappwebview_windows` для рендеринга EPUB) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Минимум Android 7.0 (API 24). Язык поиска по словарю определяется импортированными словарями и таблицами трансформации Yomitan и не зависит от языка интерфейса.

### Языки интерфейса (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Установка и сборка

Подготовка одной командой (`flutter pub get` + применение патчей), затем сборка:

```bash
# в корне репозитория
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # или (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` сводит в одну команду ① `flutter pub get` и ② `ci/apply-patches.sh`. Проект привязан к Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); часть upstream-зависимостей vendored в `third_party/` или патчится через `ci/apply-patches.sh` — подробности механизма, сборка на пяти платформах, список зависимостей и патчей см. в [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Обзор технологического стека</b></summary>

| Уровень | Технология |
|---|---|
| Фреймворк | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Платформа | Android / iOS / macOS / Windows / Linux (адаптивный Material 3 + Cupertino) |
| Читалка | Постраничный движок на WebView (на основе [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Видео | media_kit / libmpv |
| Хранение | Drift (SQLite, WAL) + hoshidicts (движок словарей C++ FFI) |
| NLP | Таблицы трансформации Yomitan (многоязычная лемматизация) + kana_kit (конвертация кана); сегментация идёт через hoshidicts FFI |
| Создание карточек | AnkiDroid API + AnkiConnect |
| Интернационализация | Slang (17 языков) |

</details>

<details>
<summary><b>Структура проекта</b></summary>

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
├── native/                  # Движок словарей C++ hoshidicts (FFI)
├── third_party/             # vendored патч-пакеты (подключены через dependency_overrides)
├── ci/                      # Скрипты патчей сборки и интеграционных тестов
├── tool/                    # Скрипты bootstrap / i18n_sync и др.
└── docs/                    # Документация разработки (включая руководство agent в docs/agent/)
```

</details>

---

## Благодарности

| Проект | Описание |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Инструмент иммерсивного изучения японского |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Читалка японского для Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Движок словарей C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Читалка японского для iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Решение для синхронизации аудиокниг |
| [Yomitan](https://github.com/yomidevs/yomitan) | Источник форматов словарей и таблиц трансформации |
| [Lapis](https://github.com/donkuri/lapis) | Тип заметки Anki |

## Лицензия

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <b>Русский</b> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
