<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Lees een boek en maak elk nieuw woord van jezelf.</b></p>
<p align="center">Multiplatform, meertalige immersieve lezer —— EPUB lezen · Tik om op te zoeken · Anki-kaarten maken · Luisterboeksynchronisatie · Opzoeken in videoondertitels</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Projectwebsite (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <b>Nederlands</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Inleiding

**hibiki** is een multiplatform immersieve leesapp voor het leren van talen. Binnen de tekst van een EPUB kun je **tikken om op te zoeken en selecteren om te analyseren**, en met één tik elk nieuw woord omzetten in een Anki-kaart; laat de audio van het luisterboek zin voor zin synchroon met de tekst oplichten; en zoek en maak zelfs kaarten rechtstreeks vanuit videoondertitels. Eén gereedschap voor alle drie de immersieve invoervormen: «lezen · luisteren · kijken».

Het opzoeken in het woordenboek dekt **alle transformatietalen** van [Yomitan](https://github.com/yomidevs/yomitan) (deflectie + tekstnormalisatie vóór het opzoeken), de interface is gelokaliseerd in **17 talen** en ondersteunt de vijf platforms **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Boekenplank" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Opzoeken" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Instellingen en thema's" width="300">
</p>
<p align="center"><sub>Boekenplank · Opzoeken · Instellingen en thema's</sub></p>

---

## Belangrijkste functies

### 📖 EPUB lezen, tik om op te zoeken

EPUB-lezer gerenderd in WebView (gepagineerde engine afgeleid van [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)): tik op een willekeurig woord om het direct op te zoeken, selecteer een stuk tekst voor directe analyse. Dubbele modus met continu scrollen en paginering, aangepaste lettertypen en thema's (licht / donker / puur zwart / aangepast), furigana, leesstatistieken en bladwijzers allemaal inbegrepen.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Verticaal lezen · Furigana · Luisterboeksynchronisatie" width="300">
</p>
<p align="center"><sub>Verticale tekst · Furigana · Selectiemarkering · Luisterboekbedieningsbalk onderaan</sub></p>

### 🔍 Tik om op te zoeken, dekt alle transformatietalen van Yomitan

Importeer woordenboeken in meerdere formaten: **Yomitan** (voorheen Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Meertalige lemmatisering (Yomitan-transformatietabellen) + tekstnormalisatie vóór het opzoeken (hoofdletters/kleine letters / diakritische tekens / Arabische harakat), aangedreven door code points en zonder van taal te wisselen. Parallelle zoekopdrachten in meerdere woordenboeken, prioriteit en in-/uitschakelen van subbronnen, toonaccentannotatie en woordfrequentie, allemaal in één pop-up.

### 🎴 Anki-kaarten maken met één tik

Heb je een nieuw woord opgezocht, exporteer het dan in één stap naar [AnkiDroid](https://github.com/ankidroid/Anki-Android) en AnkiConnect. Ingebouwd [Lapis](https://github.com/donkuri/lapis)-notitietypeschema (vendored 1.7.0): je kunt kaartsjablonen en decks rechtstreeks in de app maken; automatisch invullen van contextzinnen, ondersteuning voor audio-opname en screenshot bijsnijden, meerdere exportconfiguraties (Profile), aangepaste veldtoewijzing en snelle acties om in één stap een kaart te maken.

### 🎧 Luisterboeksynchronisatie (Sasayaki)

Ondersteunt SRT / LRC / VTT / ASS-ondertitels en lijnt de ondertiteltekst automatisch uit met de EPUB-inhoud. Tijdens het afspelen **markeert het de tekst meelezend en bladert het synchroon met de audio**, samen met de afspeelbedieningsbalk (voortgang, zoeken, snelheid): tijdens het luisteren licht de tekst zin voor zin op —— de bedieningsbalk onderaan de leesschermafbeelding bovenaan deze pagina is precies deze functie.

### 🎬 Opzoeken in videoondertitels

Ingebouwde videospeler op basis van media_kit / libmpv, met ondersteuning voor ingebedde / externe ondertitels. Tijdens het afspelen van een video kun je **rechtstreeks op de ondertitels opzoeken en kaarten maken**, zodat ook audiovisueel materiaal deel uitmaakt van de immersieve invoer; tegelijkertijd worden de kijktijd en het aantal gemaakte kaarten geregistreerd.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Schermafbeelding van de videospeler nog toe te voegen.</sub></p>

### 🔗 Meer

- **17 interfacetalen**, gelokaliseerd op alle platforms
- **Hibiki Interconnect**: synchronisatie tussen apparaten van boeken / woordenboeken / luisterboeken / leesvoortgang
- **Meerdere gebruikersprofielen (Profile)**, automatisch wisselen per boek
- **Incognitomodus**; **tekst delen vanuit andere apps om direct op te zoeken**

---

## Ondersteunde platforms

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (EPUB-rendering via de fork `flutter_inappwebview_windows`) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Minimaal Android 7.0 (API 24). De opzoektaal van het woordenboek wordt bepaald door de geïmporteerde woordenboeken en de Yomitan-transformatietabellen, onafhankelijk van de interfacetaal.

### Interfacetalen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Installatie en compilatie

Voorbereiding met één commando (`flutter pub get` + patches toepassen), daarna bouwen:

```bash
# in de hoofdmap van de repository
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` brengt in één commando ① `flutter pub get` en ② `ci/apply-patches.sh` samen. Dit project is vastgezet op Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); sommige upstream-afhankelijkheden zijn vendored onder `third_party/` of worden door `ci/apply-patches.sh` gepatcht —— voor mechanismedetails, het bouwen op de vijf platforms en de lijst met afhankelijkheden en patches, zie [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Technologiestack in het kort</b></summary>

| Laag | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptief) |
| Lezer | Gepagineerde WebView-engine (afgeleid van [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Video | media_kit / libmpv |
| Opslag | Drift (SQLite, WAL) + hoshidicts (C++ FFI woordenboekengine) |
| NLP | Yomitan-transformatietabellen (meertalige lemmatisering) + kana_kit (kana-conversie); tokenisatie verloopt via hoshidicts FFI |
| Kaarten maken | AnkiDroid API + AnkiConnect |
| Internationalisatie | Slang (17 talen) |

</details>

<details>
<summary><b>Projectstructuur</b></summary>

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
├── native/                  # hoshidicts C++ woordenboekengine (FFI)
├── third_party/             # vendored patch-pakketten (aangewezen via dependency_overrides)
├── ci/                      # Build-patch- en integratietestscripts
├── tool/                    # bootstrap / i18n_sync en andere scripts
└── docs/                    # Ontwikkelingsdocumentatie (inclusief agent-handleiding in docs/agent/)
```

</details>

---

## Dankbetuigingen

| Project | Beschrijving |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Immersief Japans leerhulpmiddel |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android Japanse lezer |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ woordenboekengine |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japanse lezer |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Schema voor luisterboeksynchronisatie |
| [Yomitan](https://github.com/yomidevs/yomitan) | Bron van het woordenboekformaat en de transformatietabellen |
| [Lapis](https://github.com/donkuri/lapis) | Anki-notitietype |

## Licentie

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <b>Nederlands</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
