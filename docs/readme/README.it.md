<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Lettore immersivo di giapponese per Android</p>
<p align="center">EPUB · Dizionario · Anki · Sincronizzazione audiolibri</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <b>Italiano</b> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduzione

**hibiki** è un'app di lettura per Android destinata agli studenti di giapponese.

## Funzionalità

### Lettura EPUB
- [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) integrato per il rendering EPUB (WebView)
- Tocca per cercare nel dizionario, seleziona per analizzare
- Font personalizzati, temi (chiaro/scuro)
- Statistiche di lettura e segnalibri
- Scorrimento continuo / modalità a pagine

### Dizionario
- Importa dizionari in formato [Yomitan](https://github.com/yomidevs/yomitan) (ex Yomichan)
- Supporto per accento tonale e dati di frequenza
- Ricerca parallela su più dizionari, cronologia ricerche
- Deconiugazione Ve

### Schede Anki
- Esportazione con un tocco verso [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Compilazione automatica delle frasi di contesto
- Registrazione audio, ritaglio screenshot
- Profili di esportazione multipli, mappatura personalizzata dei campi
- Azioni rapide (Quick Actions) per la creazione di schede in un solo passaggio

### Sincronizzazione audiolibri (Sasayaki)
- Formati sottotitoli: SRT / LRC / VTT / ASS
- Allineamento automatico del testo dei sottotitoli al contenuto EPUB
- Evidenziazione sincronizzata, cambio pagina sincronizzato con l'audio
- Controlli di riproduzione (progresso, ricerca, velocità)

### Altro
- 17 lingue dell'interfaccia
- Profili utente multipli
- Modalità in incognito
- Condivisione testo da altre app per la ricerca

## Lingue supportate

L'interfaccia supporta le seguenti lingue:

| Lingua | Codice |
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

## Stack tecnologico

| Livello | Tecnologia |
|---|---|
| Framework | Flutter 3.41.6 / Dart 3.11.4 |
| Lettore | ttu Ebook Reader (WebView, [fork](https://github.com/hdjsadgfwtg/ttu-fork)) |
| Archiviazione | Isar + Drift (SQLite) + hoshidicts (motore dizionario C++ FFI) |
| NLP | Ve (deconiugazione) |
| Schede | AnkiDroid API |
| Internazionalizzazione | Slang |
| Versione minima | Android 8.0 (API 26) |

## Compilazione

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **Prima della prima compilazione è necessario applicare le patch alla pub cache.** Se la pub cache viene cancellata o si esegue nuovamente `pub get`, tutte le patch devono essere riapplicate. Vedi [Dipendenze e patch](#dipendenze-e-patch) di seguito.

## Dipendenze e patch

Questo progetto è bloccato su Flutter 3.41.6. Alcune dipendenze upstream non sono ancora compatibili e richiedono patch manuali al codice sorgente nella pub cache.

<details>
<summary><b>Patch per modifiche API di Flutter</b></summary>

| Pacchetto | Modifiche |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; sostituzione di `imageCache.putIfAbsent` rimosso |
| `flutter_blurhash` 0.7.0 | Come sopra: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Aggiunta `hide CarouselController` all'import interno per evitare conflitti di nomi |
| `fading_edge_scrollview` 3.0.0 | Correzione nullable per `PageView.controller` |

</details>

<details>
<summary><b>Patch per rimozione v1 Embedding</b></summary>

Flutter 3.41.6 ha rimosso completamente l'API v1 embedding (`PluginRegistry.Registrar`). I seguenti plugin richiedono la rimozione dei riferimenti correlati:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Patch Gradle / Kotlin</b></summary>

| Obiettivo | Modifiche |
|---|---|
| `android/build.gradle` afterEvaluate | Forzatura `compileSdkVersion 34` per i sotto-progetti; rimozione di `-Werror` |
| `audio_session` 0.1.14 | Rimozione di `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Correzione null safety per Kotlin |
| `receive_intent` (git) | Correzione null safety per Kotlin |

</details>

<details>
<summary><b>Dipendenze Git</b></summary>

| Pacchetto | Origine |
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

## Struttura del progetto

```
hibiki/
├── hibiki/                  # Directory principale dell'app Flutter
│   ├── lib/
│   │   ├── i18n/            # Internazionalizzazione (17 lingue)
│   │   ├── src/
│   │   │   ├── pages/       # Pagine (libreria, lettore, dizionario, impostazioni, ecc.)
│   │   │   ├── media/       # Bridge audiolibri, parsing sottotitoli
│   │   │   ├── dictionary/  # Motore di ricerca dizionario
│   │   │   ├── models/      # Modelli dati e gestione dello stato
│   │   │   └── language/    # Livello di astrazione linguistica
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # Artefatti di build del fork ttu
│   └── android/
│       └── app/src/main/cpp/ # Motore dizionario C++ hoshidicts
├── docs/                    # Documentazione di sviluppo
└── chisa/                   # Riferimento alla versione precedente di jidoujisho
```

## Ringraziamenti

| Progetto | Descrizione |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Strumento di apprendimento immersivo del giapponese |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lettore giapponese per Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motore dizionario C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lettore giapponese per iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Schema di sincronizzazione audiolibri |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Motore di rendering EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Versione mantenuta dalla comunità ttu (SvelteKit v2), base upstream del fork hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Origine del formato dizionario |

## Licenza

[GNU General Public License v3.0](../../LICENSE)
