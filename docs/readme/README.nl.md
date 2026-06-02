<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Immersieve Japanse lezer voor Android</p>
<p align="center">EPUB · Woordenboek · Anki · Luisterboeksynchronisatie</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <b>Nederlands</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Inleiding

**hibiki** is een Android-leesapp voor Japans-studenten.

## Functies

### EPUB-lezer
- EPUB-weergave in WebView (gepagineerde engine afgeleid van [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Tik om op te zoeken, selecteer om te analyseren
- Aangepaste lettertypen, thema's (licht/donker)
- Leesstatistieken en bladwijzers
- Continu scrollen / gepagineerde modus

### Woordenboek
- Importeer woordenboeken in [Yomitan](https://github.com/yomidevs/yomitan)-formaat (voorheen Yomichan)
- Ondersteuning voor toonaccent en frequentiegegevens
- Parallelle zoekopdrachten in meerdere woordenboeken, zoekgeschiedenis
- Ve-deconjugatie

### Anki-kaarten
- Exporteer met een tik naar [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Automatisch invullen van contextzinnen
- Audio-opname, screenshot bijsnijden
- Meerdere exportprofielen, aangepaste veldtoewijzing
- Snelle acties (Quick Actions) voor het maken van kaarten in een stap

### Luisterboeksynchronisatie (Sasayaki)
- Ondertitelformaten: SRT / LRC / VTT / ASS
- Automatische uitlijning van ondertiteltekst met EPUB-inhoud
- Gesynchroniseerde markering, audio-gesynchroniseerd bladeren
- Afspeelknoppen (voortgang, zoeken, snelheid)

### Overig
- 17 interfacetalen
- Meerdere gebruikersprofielen
- Incognitomodus
- Tekst delen vanuit andere apps om op te zoeken

## Ondersteunde talen

De interface ondersteunt de volgende talen:

| Taal | Code |
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

## Technologiestack

| Laag | Technologie |
|---|---|
| Framework | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptief) |
| Lezer | Gepagineerde WebView-engine (afgeleid van [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Opslag | Drift (SQLite, WAL) + hoshidicts (C++ FFI woordenboekengine) |
| NLP | Ve (deconjugatie) |
| Kaarten | AnkiDroid API |
| Internationalisatie | Slang (17 talen) |
| Minimumversie | Android 7.0 (API 24) |

## Bouwen

Voorbereiding met een enkel commando (automatisch seeden van `dart_defines.env` + `flutter pub get` + patches toepassen), daarna bouwen:

```bash
# in de hoofdmap van de repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # of (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define-from-file=dart_defines.env
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` brengt drie stappen samen in een commando: ① als `hibiki/dart_defines.env` ontbreekt, wordt het automatisch gegenereerd uit `dart_defines.env.example` (placeholder-OAuth-waarden volstaan om te compileren, echte waarden zijn alleen nodig voor Google Drive-back-up); ② `flutter pub get`; ③ uitvoeren van `ci/apply-patches.sh`. `melos bootstrap` doet via een post hook hetzelfde voor ②③ (op Windows heeft melos een CJK-coderingsbug, gebruik daarom `tool/bootstrap.ps1`).

> **Over de patches:** `ci/apply-patches.sh` legt de wijzigingen uit `ci/patches/` over de feitelijke pub cache. Na elke wissing van de pub cache of een nieuwe `flutter pub get` moet het opnieuw worden uitgevoerd (bootstrap bevat deze stap al). Als het script geen enkel patch-doel vindt, slaat het dit over met een waarschuwing in plaats van succes te veinzen.

## Afhankelijkheden en patches

Dit project is vastgezet op Flutter 3.41.6 en sommige upstream-afhankelijkheden zijn nog niet aangepast. Patches verlopen via twee wegen: ① pakketten die een build-invoer moeten zijn en op verschillende machines identiek reproduceerbaar, worden vendored onder `third_party/` en via `dependency_overrides` aangewezen (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **zonder** pub-cache-patch); ② de overige pakketten worden door `ci/apply-patches.sh` in de pub-cache-broncode gepatcht. Mechanismedetails staan in [docs/agent/build.md](../agent/build.md). De inklapbare tabellen hieronder vormen een historische lijst gerangschikt op wijziging; voor pakketten die met mechanisme ① overlappen, geldt de vendored versie.

<details>
<summary><b>Flutter API-wijzigingspatches</b></summary>

| Pakket | Wijzigingen |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; vervanging van verwijderde `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | Idem: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Interne import met `hide CarouselController` om naamconflicten te voorkomen |
| `fading_edge_scrollview` 3.0.0 | Nullable-fix voor `PageView.controller` |

</details>

<details>
<summary><b>v1 Embedding-verwijderingspatches</b></summary>

Flutter 3.41.6 heeft de v1 embedding API (`PluginRegistry.Registrar`) volledig verwijderd. De volgende plugins vereisen het verwijderen van gerelateerde verwijzingen:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin-patches</b></summary>

| Doel | Wijzigingen |
|---|---|
| `android/build.gradle` afterEvaluate | Subprojecten geforceerd naar `compileSdk` (standaard 36, enkele 34); verwijdering van `-Werror` |
| `audio_session` 0.1.14 | Verwijdering van `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null safety-fix |
| `receive_intent` (git) | Kotlin null safety-fix |

</details>

<details>
<summary><b>Git-afhankelijkheden</b></summary>

| Pakket | Bron |
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

## Projectstructuur

```
hibiki/                      # Hoofdmap repository (Melos workspace: hibiki_workspace)
├── hibiki/                  # Hoofdmap van de Flutter-app
│   ├── lib/
│   │   ├── i18n/            # Internationalisatie (17 talen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagina's (boekenplank, lezer, woordenboek, instellingen, enz.)
│   │   │   ├── reader/      # JS/CSS-scripts van de WebView-lezer
│   │   │   ├── media/       # Luisterboeken, ondertitelparsing, reader source
│   │   │   └── models/      # Datamodellen en statusbeheer (AppModel)
│   │   └── main.dart
│   └── android/             # Android-project (manifest, native hoshidicts)
├── packages/                # Interne packages + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # vendored patch-pakketten (aangewezen via dependency_overrides)
├── ci/                      # Build-patch- en integratietestscripts
├── tool/                    # bootstrap / i18n_sync en andere scripts
└── docs/                    # Ontwikkelingsdocumentatie (inclusief agent-handleiding in docs/agent/)
```

## Dankbetuigingen

| Project | Beschrijving |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Immersief Japans leerhulpmiddel |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android Japanse lezer |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ woordenboekengine |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japanse lezer |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Schema voor luisterboeksynchronisatie |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB-renderingengine |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Door de community onderhouden ttu-versie (SvelteKit v2), upstream-basis van de hibiki-fork |
| [Yomitan](https://github.com/yomidevs/yomitan) | Bron van het woordenboekformaat |

## Licentie

[GNU General Public License v3.0](../../LICENSE)
