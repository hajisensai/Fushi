<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="логотип Fushi" width="160">

![Платформа](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![Лицензия](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | **Русский** | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Скачать последнюю версию](https://img.shields.io/badge/%E2%AC%87%20%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D0%BF%D0%BE%D1%81%D0%BB%D0%B5%D0%B4%D0%BD%D1%8E%D1%8E%20%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8E-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Присоединиться к Discord](https://img.shields.io/badge/%D0%9F%D1%80%D0%B8%D1%81%D0%BE%D0%B5%D0%B4%D0%B8%D0%BD%D0%B8%D1%82%D1%8C%D1%81%D1%8F%20%D0%BA%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Поддержка платформ

| Платформа | Статус | Примечания |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) или новее |
| Windows | ✅ | Перехват текста и голоса galgame работает только в Windows |
| macOS | ✅ | Только Apple Silicon; Mac на Intel не поддерживаются |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Нет поиска источников, онлайн-источников и центра загрузок (правила App Store) |
| Linux | 🔧 Сборка из исходников | Готового релиза пока нет; для читалки EPUB нужен WPE WebKit |
| Fushi Server | 🧪 Бета ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Безголовый хост для Linux / Windows / macOS с веб-интерфейсом — см. [packages/fushi_server](../../packages/fushi_server/README.md) |

**Система дизайна** — на всех платформах по умолчанию используется **Material 3 Expressive**; систему дизайна **Cupertino** (в стиле Apple) можно выбрать в *Настройки › Внешний вид › Система дизайна*; при Cupertino фон окна использует Mica в Windows 11 и vibrancy в macOS (если не включена системная настройка уменьшения прозрачности или высокой контрастности).

> Языки, доступные для поиска по словарю, определяются импортированными словарями и таблицами трансформации Yomitan, независимо от языка интерфейса. Обновления для iOS приходят через TestFlight на несколько дней позже, чем на других платформах.

### Языки интерфейса (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Установка

Скачайте последний релиз на [сайте Fushi](https://fushi.moe/) — доступны APK для Android, установщик для Windows и сборки для macOS (только Apple Silicon; Mac на Intel не поддерживаются); iOS устанавливается через [TestFlight](https://testflight.apple.com/join/j88d69jx). Готового релиза приложения для Linux пока нет; собирайте из исходников. Безголовый Fushi Server выпускается отдельно в [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Требуется Android 7.0 (API 24) или выше.

## Сборка

Подготовка одной командой (`flutter pub get` + применение патчей), затем сборка:

```bash
# из корня репозитория
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Десктоп
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Безголовый сервер (из packages/fushi_server; используйте `dart build cli`, а не `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` сводят `flutter pub get` и `ci/apply-patches.sh` в одну команду. Проект привязан к Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); более ранние версии Flutter его не соберут, потому что Material и Cupertino подключаются как пакеты `material_ui` / `cupertino_ui`. Часть upstream-зависимостей vendored в `third_party/` или патчится через `ci/apply-patches.sh` — подробности, включая зависимости сборки для Linux-десктопа, см. в [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Технологический стек</b></summary>

| Уровень | Технология |
|---|---|
| Фреймворк | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Платформы | Android / Windows / macOS / iOS / Linux, а также безголовый сервер |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Читалка | Постраничный движок на WebView (на основе семейства Hoshi Reader) |
| Видео | media_kit (ядро libmpv) + libplacebo |
| Хранение | Drift (SQLite, WAL) + fushidicts (движок словарей C++ FFI) |
| NLP | Таблицы трансформации Yomitan (многоязычная лемматизация) + kana_kit (конвертация кана); сегментация через fushidicts FFI |
| ИИ на устройстве | ONNX Runtime для распознавания речи (генерация субтитров) и OCR манги; алгоритмы находятся в [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Загрузки | libtorrent 2.x через C-ABI FFI-мост (внешний qBittorrent как запасной вариант) |
| Синхронизация | Облачные бэкенды + Fushi Interconnect (LAN, удалённые адреса и P2P-туннель iroh) |
| Общий движок | `fushi_engine` — чистое ядро на Dart, общее для приложения и Fushi Server |
| Создание карточек | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 языков) |

</details>

<details>
<summary><b>Структура проекта</b></summary>

```
Fushi/                      # Корень репозитория (Melos workspace: fushi_workspace)
├── fushi/                  # Основной каталог Flutter-приложения
│   ├── lib/
│   │   ├── i18n/            # Интернационализация (17 языков, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Страницы (страницы библиотек, читалка, видеоплеер, настройки и др.)
│   │   │   ├── reader/      # JS/CSS-скрипты WebView читалки
│   │   │   ├── media/       # Книги, манга, видео, аудиокниги, онлайн-источники
│   │   │   ├── lookup/      # Всплывающие окна и оверлеи поиска по словарю
│   │   │   ├── mining/      # Создание карточек (включая galgame mining)
│   │   │   ├── sync/        # Облачная синхронизация, Interconnect, медиасерверы
│   │   │   └── models/      # Модели данных и управление состоянием (AppModel)
│   │   └── main.dart
│   └── android/             # Android-проект
├── packages/                # Dart-пакеты
│   ├── fushi_core/          #   Схема базы данных, настройки
│   ├── fushi_engine/        #   Чистый Dart-движок, общий с сервером
│   ├── fushi_server/        #   CLI безголовного сервера + веб-интерфейс
│   ├── fushi_cli/           #   Консольный клиент для десктопа
│   ├── fushi_dictionary/    #   Привязки словарного движка и импортёры
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # FFI-привязки libtorrent / iroh
│   └── …                    #   Vendored-форки (inappwebview Windows/Linux, gamepads)
├── native/                  # Нативные исходники: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Сборщик логов и бэкенды таблицы лидеров (развёртываются отдельно)
├── tools/browser-extension/ # Расширение браузера для поиска по словарю
├── third_party/             # Vendored патч-пакеты (dependency_overrides)
├── ci/                      # Патчи сборки и скрипты CI
├── tool/                    # Скрипты bootstrap / setup_worktree / трекера багов
└── docs/                    # Документация разработки (включая руководство по операциям docs/agent/)
```

</details>

Импорт видео поддерживает группировку по произведению или по папке. О сопоставлении и фоновых задачах см. [рабочий процесс видео](../specs/2026-09-07-video-library-workflow.md) и [метаданные MAL/TMDB с хешированием файлов AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md).

[Настройка необязательных онлайн-сервисов](../specs/2026-09-07-online-services-setup.md) описывает встроенные идентификаторы приложения, личные учётные данные и закрываемое напоминание о настройке видео.

## Конфиденциальность и данные

Fushi хранит импортированные книги, словари, шрифты, данные аудиокниг, видео, прогресс чтения, подсветки, статистику и настройки в локальном хранилище приложения.

- **Синхронизация** — Google Drive / OneDrive / Dropbox используют вход через OAuth; WebDAV / FTP / SFTP / Fushi Server используют указанные вами адрес сервера и учётные данные. Fushi Interconnect соединяет сопряжённые устройства напрямую (LAN, IPv6, оверлейные сети или публичные адреса) и переключается на сквозной P2P-туннель iroh, если прямого маршрута нет; ссылки для сопряжения всегда запрашивают подтверждение.
- **Anki** — создание карточек обращается к AnkiDroid или к адресу AnkiConnect, который вы настроили.
- **Статистика использования** — раз в сутки десктопные и Android-сборки отправляют на fushi.moe случайный идентификатор установки, версию приложения, платформу и канал обновлений, чтобы считать активных пользователей; данные об аккаунте, библиотеке и чтении не передаются, IP-адреса не сохраняются. Отключается пунктом «Отправлять статистику использования» в настройках обновлений. Сборки для iOS её не отправляют.
- **Только по вашему запросу** — выгрузка логов (после однократного запроса согласия), отзывы в приложении и таблица лидеров (по умолчанию выключена; названия вашей библиотеки и прогресс выгружаются только после вашего согласия).
- **OCR манги** — движок по умолчанию — Google Lens, он отправляет изображение страницы в Google; чтобы изображения оставались локальными, переключитесь в настройках на модель на устройстве или системный OCR.
- **ИИ-функции** — запросы уходят только к LLM-провайдеру, которого вы настроили и назначили функции; если провайдер не назначен, ничего не отправляется.
- **Сторонние сервисы** — функции метаданных, субтитров и онлайн-источников обращаются к сервисам из раздела [Источники контента и интеграции](#источники-контента-и-интеграции) только когда вы ими пользуетесь.

## Активность разработки

[![Активность разработки](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Повседневная работа попадает в `develop`; `main` получает только релизные слияния. График показан здесь, на `main`, но строится по `develop`, поэтому отражает реальную разработку, а не трафик слияний.

Три дорожки — это каналы обновлений, которые предлагает само приложение, и каждая масштабируется по собственному пику: debug-сборок на два порядка больше, чем стабильных релизов, поэтому общая шкала сплющила бы две другие дорожки до нуля.

| Дорожка | Что считается | Как получить |
|---|---|---|
| **Debug (скользящий)** | Успешные сборки по push для [release.yml](../../.github/workflows/release.yml) | Скользящий пре-релиз, переопубликовывается при каждом push |
| **Бета** | Пре-релизы `v<version>-beta.<seq>` | Тестовая сборка, запускаемая вручную |
| **Стабильный** | Релизы `v<version>` | Последний релиз |

> График выше строится внутри этого репозитория (без сторонних сервисов) и ежедневно обновляется workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## История звёзд

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![История звёзд](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> График выше строится внутри этого репозитория (без сторонних сервисов) и ежедневно обновляется workflow [Update Star History](../../.github/workflows/star-history.yml).

## Благодарности

Fushi опирается на следующие проекты и экосистему:

### Инструменты изучения и предшественники

| Проект | Описание |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Инструмент иммерсивного изучения японского |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Читалка японского для iOS; референс постраничного движка |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Нативная читалка японского для Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Движок словарей C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Решение для синхронизации аудиокниг |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Алгоритм выравнивания тайминга субтитров по эталону (GPL-3.0); основа автоматического выравнивания скачанных субтитров по встроенным дорожкам |
| [Yomitan](https://github.com/yomidevs/yomitan) | Референс формата словарей, таблиц трансформации и опыта поиска |
| [Lapis](https://github.com/donkuri/lapis) | Тип заметки Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Интеграция создания карточек на Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Референс локального аудио и взаимодействия с AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Референс совместимости читалки, статистики и синхронизации |
| [media_kit](https://github.com/media-kit/media-kit) | Фреймворк воспроизведения видео для Flutter (ядро libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Набор для иммерсивного изучения языков для macOS |

### Движки и нативные компоненты

| Проект | Описание |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Движок перехвата текста в galgame (поставляемые DLL, загружаются инжектором) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Библиотека inline-перехвата, используемая инжектором galgame |
| [libtorrent](https://github.com/arvidn/libtorrent) | Встроенный движок torrent-загрузок |
| [mpv](https://github.com/mpv-player/mpv) | Ядро воспроизведения libmpv в основе media_kit |
| [FFmpeg](https://ffmpeg.org) | Анализ медиа, нарезка и извлечение аудио |
| [libplacebo](https://github.com/haasn/libplacebo) | Видеошейдеры на GPU и тональная компрессия HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Движок WebView, отрисовывающий читалку EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Локальный вывод для распознавания речи и OCR |
| [iroh](https://github.com/n0-computer/iroh) | P2P-туннель для удалённых подключений Fushi Interconnect |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Зависимости словарного движка |

### Модели на устройстве

| Проект | Описание |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Пакеты моделей распознавания речи Zipformer и сборки VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Модель распознавания японской речи |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Модель распознавания японской речи |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Модель распознавания японской речи (CC BY-NC 4.0, скачивается из её репозитория на Hugging Face) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Многоязычная CTC-модель распознавания речи |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Модель детекции речевой активности |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Модель детекции текста и «облачков» в манге |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Модель детекции панелей манги, обучена на [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Детекция и распознавание строк текста; rec, настроенная на мангу (обучена на [Manga109-s](http://www.manga109.org/en/download_s.html) и [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)), лежит в основе локальной модели OCR с CTC по колонкам |

> Модель детекции панелей манги и PP-OCRv6_manga обучены на датасете Manga109-s (Matsui et al. 2017; Aizawa et al. 2020), условия которого требуют чётко указывать такое использование датасета. PP-OCRv6_manga (Apache-2.0) дополнительно обучена на датасете AnimeText, лицензированном по CC BY-NC-SA 4.0; приложение скачивает эту модель из её репозитория на Hugging Face и не распространяет её.

### Источники контента и интеграции

| Проект | Описание |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Экосистема расширений источников манги |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Экосистема расширений источников аниме (extensions-lib 14–16, та же среда выполнения) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Среда выполнения расширений манги для десктопа (vendored, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Референс адаптации расширений Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Экосистема плагинов источников ранобэ |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Медиасерверы, которые можно просматривать из видеобиблиотеки |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Референс моста субтитров стриминга для расширения браузера |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Референс архитектуры идентификации и скрейпинга аниме |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Референс информационной архитектуры библиотеки galgame |
| [AniDB](https://anidb.net) | Идентификация аниме, эпизодов и файлов |
| [MyAnimeList](https://myanimelist.net) (через [Jikan](https://jikan.moe)) | Метаданные аниме |
| [TMDB](https://www.themoviedb.org) | Дополнительные метаданные и изображения |
| [VNDB](https://vndb.org) | Метаданные визуальных новелл |
| [Jimaku](https://jimaku.cc) | Источник японских субтитров |
| [OpenSubtitles](https://www.opensubtitles.com) | Источник субтитров |

> Это приложение использует TMDB и API TMDB, но не одобрено, не сертифицировано и никак не поддержано TMDB.

## Лицензия

Распространяется под лицензией GNU General Public License v3.0. Подробности см. в [LICENSE](../../LICENSE).

## Сопровождающий

Fushi сопровождает [hajisensai](https://github.com/hajisensai). Сайт: [fushi.moe](https://fushi.moe). Контакт: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | **Русский** | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
