<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="hibiki-logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | **Nederlands** | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[Gebruikershandleiding](../user-guide.nl.md) | [Nieuwste versie downloaden](https://github.com/hajisensai/hibiki/releases)

hibiki is een immersieve taalleertool voor Android en Windows die EPUB-lezen, audioboeksynchronisatie, het opzoeken van woorden in videoondertitels en het maken van Anki-kaarten met één tik samenbrengt — zodat elke input vanzelf herhaalbaar vocabulaire wordt.

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Boekenplank" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Videobibliotheek" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Verticaal lezen op desktop met opzoek-pop-up" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Opzoeken in video (geneste pop-ups)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Opzoeken in video (ondertitellijst)" width="100%"></td>
  </tr>
</table>

</div>

## Functies

### Boekenplank

- Importeer EPUB's afzonderlijk, in bulk of recursief per map; bekijk de leesvoortgang direct op de plank.
- Organiseer boeken met aangepaste boekenplanken, tagfilters en slepen om te herordenen.
- Sleep bestanden om boeken, ondertitels of video's te importeren (desktop).
- Koppel bij het importeren automatisch ondertitel-/audiobestanden met dezelfde naam.

### Lezen

- Lees in verticale of horizontale lay-out; schakel tussen pagina- en doorlopende-scrollmodus.
- Pas thema's (licht / donker / puur zwart / aangepast), lettertypen, alinea-afstand en lezerbediening aan.
- Furigana (ふりがな)-annotaties.
- Aanpasbare UI-schaal; de bedieningselementen van de onderbalk volgen de schaal.
- Profielen voor meerdere gebruikers (Profile), automatisch per boek gewisseld.

### Opzoeken

- Importeer woordenboeken van [Yomitan](https://github.com/yomidevs/yomitan) (voorheen Yomichan), ABBYY Lingvo (DSL), MDict (MDX) en Migaku.
- Tik op tekst in de lezer om woorden op te zoeken, zoek op de woordenboekpagina of deel tekst vanuit andere apps.
- Deflexie voor **alle Yomitan-transformatietalen** + tekstnormalisatie vóór het opzoeken (hoofdletters / diakritische tekens / Arabische harakat), aangestuurd door code points zonder taalwisseling.
- Tik op woorden binnen definities voor recursief opzoeken (geneste pop-ups).
- Parallelle zoekopdrachten in meerdere woordenboeken, prioriteit en in-/uitschakelen van subbronnen, toonhoogteaccent- en frequentie-annotaties.
- Online en lokale woord-audio.
- Eigen CSS injecteren.

### Markeringen & Statistieken

- Voeg tijdens het lezen markeringen in vijf kleuren toe; spring op elk moment naar elke markering.
- Leesstatistieken: gelezen tekens, duur, leessnelheid — in realtime weergegeven tijdens het lezen.
- Videostatistieken: kijktijd, gemaakte kaarten en favorieten.

### Anki-kaarten maken

- Maak kaarten via [AnkiDroid](https://github.com/ankidroid/Anki-Android) of AnkiConnect.
- Ingebouwd [Lapis](https://github.com/donkuri/lapis)-notitietype (meegeleverd 1.7.0); maak kaartsjablonen en decks met één tik binnen de app.
- Vul contextzinnen automatisch in; audio-opname en screenshot-bijsnijden.
- Meerdere exportprofielen (Profile) en aangepaste veldtoewijzing.
- Markeer woorden als favoriet; gemaakte kaarten en favorieten worden meegeteld in de statistieken.

### Audioboeksynchronisatie (Sasayaki)

- Ondersteuning voor SRT-/LRC-/VTT-/ASS-ondertitels; lijnt de ondertiteltekst automatisch uit met de EPUB-tekst.
- Meelopende zinmarkering en automatisch omslaan van pagina's tijdens het afspelen.
- Afspeelsnelheid, zoekacties en systeemmediabediening.
- „Afspelen vanaf deze zin” met naadloze voortzetting over hoofdstukken heen.

### Woorden opzoeken in videoondertitels

- Ingebouwde videospeler op basis van [media_kit](https://github.com/media-kit/media-kit) (libmpv-kern).
- Ingebedde (tekst- + grafische sporen) en externe ondertitels; import van .m3u8-afspeellijsten.
- Zoek tijdens het afspelen woorden op en maak kaarten rechtstreeks vanuit de ondertitels.
- Beheer van de videobibliotheek, tagfilters, seriegroepering en bulkbewerkingen.

### Gegevenssynchronisatie

- Zeven sync-backends: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP en Hibiki P2P.
- Synchroniseer leesvoortgang, statistieken en boeken.

### Meer

- **17 interfacetalen**, volledig gelokaliseerd op alle platforms.
- Deel tekst vanuit andere apps om woorden direct op te zoeken.

## Platformondersteuning

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> Minimaal Android 7.0 (API 24). Welke talen beschikbaar zijn om op te zoeken, wordt bepaald door de geïmporteerde woordenboeken en de Yomitan-transformatietabellen, onafhankelijk van de interfacetaal.

### Interfacetalen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installatie & Bouwen

Voorbereiding met één commando (`flutter pub get` + patches toepassen), dan bouwen:

```bash
# Vanuit de hoofdmap van de repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows-desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` bundelen `flutter pub get` en `ci/apply-patches.sh` tot één enkel commando. Dit project is vastgezet op Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); sommige upstream-afhankelijkheden zijn meegeleverd onder `third_party/` of gepatcht door `ci/apply-patches.sh` — zie [docs/agent/build.md](../agent/build.md) voor details.

<details>
<summary><b>Technologiestack</b></summary>

| Laag | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platforms | Android / Windows (Material Design 3) |
| Reader | WebView-paginamotor (afgeleid van de Hoshi Reader-familie) |
| Video | media_kit (libmpv-kern) |
| Opslag | Drift (SQLite, WAL) + hoshidicts (C++-FFI-woordenboekengine) |
| NLP | Yomitan-transformatietabellen (meertalige lemmatisering) + kana_kit (kana-conversie); tokenisatie via hoshidicts-FFI |
| Kaarten maken | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 talen) |

</details>

<details>
<summary><b>Projectstructuur</b></summary>

```
hibiki/                      # Hoofdmap van de repository (Melos-workspace: hibiki_workspace)
├── hibiki/                  # Hoofdmap van de Flutter-app
│   ├── lib/
│   │   ├── i18n/            # Internationalisatie (17 talen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagina's (boekenplank, lezer, woordenboek, instellingen enz.)
│   │   │   ├── reader/      # Reader-WebView-JS-/CSS-scripts
│   │   │   ├── media/       # Audioboek, ondertitel-parsing, reader-bron
│   │   │   └── models/      # Datamodellen en toestandsbeheer (AppModel)
│   │   └── main.dart
│   └── android/             # Android-project (manifest, native hoshidicts)
├── packages/                # Interne pakketten + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # hoshidicts C++-woordenboekengine (FFI)
├── third_party/             # Meegeleverde gepatchte pakketten (dependency_overrides)
├── ci/                      # Build-patches en integratietestscripts
├── tool/                    # bootstrap / i18n_sync en andere scripts
└── docs/                    # Ontwikkeldocumentatie (incl. docs/agent/ bedieningshandleiding)
```

</details>

## Privacy & Gegevens

hibiki slaat geïmporteerde boeken, woordenboeken, lettertypen, audioboekgegevens, video's, leesvoortgang, markeringen, statistieken en instellingen op in de lokale opslag van de app.

Cloud-synchronisatie (Google Drive / OneDrive / Dropbox) gebruikt door de gebruiker geconfigureerde OAuth-referenties; WebDAV / FTP / SFTP gebruikt door de gebruiker opgegeven serveradressen en referenties; Hibiki P2P verbindt rechtstreeks via een door de gebruiker geconfigureerd adres. Het maken van Anki-kaarten communiceert met AnkiDroid of een geconfigureerd AnkiConnect-adres.

## Dankbetuigingen

hibiki bouwt voort op de volgende projecten en het volgende ecosysteem:

| Project | Beschrijving |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanse immersieve leertool |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanse lezer; referentie voor de reader-paginamotor |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Native Japanse lezer voor Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++-woordenboekengine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Oplossing voor audioboeksynchronisatie |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referentie voor woordenboekformaat, transformatietabellen en opzoekervaring |
| [Lapis](https://github.com/donkuri/lapis) | Anki-notitietype |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android-integratie voor kaarten maken |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referentie voor lokale audio en AnkiDroid-interactie |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referentie voor lezer, statistieken en sync-compatibiliteit |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter-videoweergaveframework (libmpv-kern) |

## Licentie

Gedistribueerd onder de GNU General Public License v3.0. Zie [LICENSE](../../LICENSE) voor details.

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | **Nederlands** | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
