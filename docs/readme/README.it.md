<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="logo hibiki" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | **Italiano** | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[Guida utente](../user-guide.it.md) | [Scarica l'ultima versione](https://github.com/hajisensai/hibiki/releases)

hibiki è uno strumento immersivo per l'apprendimento delle lingue per Android e Windows che unisce la lettura di EPUB, la sincronizzazione degli audiolibri, la ricerca di parole nei sottotitoli dei video e la creazione di carte Anki con un solo tocco, così che ogni input diventi naturalmente vocabolario da ripassare.

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Libreria" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Videoteca" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Lettura verticale su desktop con finestra di ricerca" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Ricerca nel video (finestre annidate)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Ricerca nel video (elenco dei sottotitoli)" width="100%"></td>
  </tr>
</table>

</div>

## Funzionalità

### Libreria

- Importa EPUB singolarmente, in blocco o ricorsivamente per cartella; visualizza l'avanzamento di lettura sullo scaffale.
- Organizza i libri con scaffali personalizzati, filtro per etichette e riordino tramite trascinamento.
- Trascina e rilascia i file per importare libri, sottotitoli o video (desktop).
- Associa automaticamente i file di sottotitoli / audio con lo stesso nome durante l'importazione.

### Lettura

- Leggi in disposizione verticale o orizzontale; passa tra le modalità impaginata e scorrimento continuo.
- Personalizza temi (chiaro / scuro / nero puro / personalizzato), caratteri, spaziatura dei paragrafi e controlli del lettore.
- Annotazioni furigana (ふりがな).
- Scala dell'interfaccia regolabile; i controlli della barra inferiore seguono la scala.
- Profili multiutente (Profile), cambiati automaticamente in base al libro.

### Ricerca

- Importa dizionari [Yomitan](https://github.com/yomidevs/yomitan) (in precedenza Yomichan), ABBYY Lingvo (DSL), MDict (MDX) e Migaku.
- Tocca il testo nel lettore per cercare parole, esegui ricerche nella pagina del dizionario o condividi testo da altre app.
- Deflessione che copre **tutte le lingue di trasformazione di Yomitan** + normalizzazione del testo prima della ricerca (maiuscole/minuscole / segni diacritici / harakat arabo), guidata dai code point senza cambio di lingua.
- Tocca le parole all'interno delle definizioni per una ricerca ricorsiva (finestre annidate).
- Query parallele su più dizionari, priorità e attivazione delle sottofonti, annotazioni di accento tonale e frequenza.
- Audio delle parole online e locale.
- Inietta CSS personalizzato.

### Evidenziazioni e statistiche

- Aggiungi evidenziazioni in cinque colori mentre leggi; salta a qualsiasi evidenziazione in qualsiasi momento.
- Statistiche di lettura: caratteri letti, durata, velocità di lettura — mostrate in tempo reale durante la lettura.
- Statistiche video: tempo di visione, carte create e preferiti.

### Creazione di carte Anki

- Crea carte tramite [AnkiDroid](https://github.com/ankidroid/Anki-Android) o AnkiConnect.
- Tipo di nota [Lapis](https://github.com/donkuri/lapis) integrato (incluso 1.7.0); crea modelli di carte e mazzi all'interno dell'app con un solo tocco.
- Compila automaticamente le frasi di contesto; registrazione audio e ritaglio degli screenshot.
- Più profili di esportazione (Profile) e mappatura dei campi personalizzata.
- Parole preferite; le carte create e i preferiti vengono conteggiati nelle statistiche.

### Sincronizzazione degli audiolibri (Sasayaki)

- Supporto per sottotitoli SRT / LRC / VTT / ASS; allinea automaticamente il testo dei sottotitoli al corpo dell'EPUB.
- Evidenziazione delle frasi con tracciamento e avanzamento automatico delle pagine durante la riproduzione.
- Velocità di riproduzione, azioni di ricerca e controlli multimediali di sistema.
- «Riproduci da questa frase» con continuazione fluida tra i capitoli.

### Ricerca nei sottotitoli dei video

- Lettore video integrato basato su [media_kit](https://github.com/media-kit/media-kit) (core libmpv).
- Sottotitoli incorporati (tracce testuali + grafiche) ed esterni; importazione di playlist .m3u8.
- Cerca parole e crea carte direttamente dai sottotitoli durante la riproduzione.
- Gestione della videoteca, filtro per etichette, raggruppamento in serie e operazioni in blocco.

### Sincronizzazione dei dati

- Sette backend di sincronizzazione: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP e Hibiki P2P.
- Sincronizza l'avanzamento di lettura, le statistiche e i libri.

### Altro

- **17 lingue dell'interfaccia**, completamente localizzate su tutte le piattaforme.
- Condividi testo da altre app per cercare parole direttamente.

## Supporto delle piattaforme

| Piattaforma | Stato | Rendering / Interfaccia |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> Minimo Android 7.0 (API 24). Le lingue disponibili per la ricerca nei dizionari sono determinate dai dizionari importati e dalle tabelle di trasformazione di Yomitan, indipendentemente dalla lingua dell'interfaccia.

### Lingue dell'interfaccia (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installazione e compilazione

Preparazione con un solo comando (`flutter pub get` + applicazione delle patch), poi compila:

```bash
# Dalla radice del repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop Windows
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` racchiudono `flutter pub get` e `ci/apply-patches.sh` in un unico comando. Questo progetto è bloccato su Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); alcune dipendenze upstream sono incluse in `third_party/` o sottoposte a patch da `ci/apply-patches.sh` — vedi [docs/agent/build.md](../agent/build.md) per i dettagli.

<details>
<summary><b>Stack tecnologico</b></summary>

| Livello | Tecnologia |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Piattaforme | Android / Windows (Material Design 3) |
| Lettore | Motore di impaginazione WebView (derivato dalla famiglia Hoshi Reader) |
| Video | media_kit (libmpv core) |
| Archiviazione | Drift (SQLite, WAL) + hoshidicts (motore di dizionari FFI in C++) |
| NLP | Tabelle di trasformazione di Yomitan (lemmatizzazione multilingue) + kana_kit (conversione kana); tokenizzazione tramite hoshidicts FFI |
| Creazione di carte | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 lingue) |

</details>

<details>
<summary><b>Struttura del progetto</b></summary>

```
hibiki/                      # Radice del repository (workspace Melos: hibiki_workspace)
├── hibiki/                  # Directory principale dell'app Flutter
│   ├── lib/
│   │   ├── i18n/            # Internazionalizzazione (17 lingue, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagine (libreria, lettore, dizionario, impostazioni, ecc.)
│   │   │   ├── reader/      # Script JS/CSS del WebView del lettore
│   │   │   ├── media/       # Audiolibri, analisi dei sottotitoli, sorgente del lettore
│   │   │   └── models/      # Modelli di dati e gestione dello stato (AppModel)
│   │   └── main.dart
│   └── android/             # Progetto Android (manifest, hoshidicts nativo)
├── packages/                # Pacchetti interni + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Motore di dizionari in C++ hoshidicts (FFI)
├── third_party/             # Pacchetti con patch inclusi (dependency_overrides)
├── ci/                      # Patch di compilazione e script per i test di integrazione
├── tool/                    # Script bootstrap / i18n_sync e altri
└── docs/                    # Documentazione di sviluppo (incl. manuale operativo docs/agent/)
```

</details>

## Privacy e dati

hibiki memorizza i libri importati, i dizionari, i caratteri, i dati degli audiolibri, i video, l'avanzamento di lettura, le evidenziazioni, le statistiche e le impostazioni nell'archiviazione locale dell'app.

La sincronizzazione nel cloud (Google Drive / OneDrive / Dropbox) utilizza credenziali OAuth configurate dall'utente; WebDAV / FTP / SFTP utilizza indirizzi del server e credenziali forniti dall'utente; Hibiki P2P si connette direttamente tramite un indirizzo configurato dall'utente. La creazione di carte Anki comunica con AnkiDroid o con un indirizzo AnkiConnect configurato.

## Ringraziamenti

hibiki si basa sui seguenti progetti ed ecosistema:

| Progetto | Descrizione |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Strumento di apprendimento immersivo del giapponese |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lettore di giapponese per iOS; riferimento per il motore di impaginazione del lettore |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lettore di giapponese nativo per Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motore di dizionari in C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Soluzione di sincronizzazione degli audiolibri |
| [Yomitan](https://github.com/yomidevs/yomitan) | Riferimento per formato del dizionario, tabelle di trasformazione ed esperienza di ricerca |
| [Lapis](https://github.com/donkuri/lapis) | Tipo di nota Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integrazione della creazione di carte su Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Riferimento per audio locale e interazione con AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Riferimento per compatibilità di lettore, statistiche e sincronizzazione |
| [media_kit](https://github.com/media-kit/media-kit) | Framework di riproduzione video di Flutter (core libmpv) |

## Licenza

Distribuito sotto la GNU General Public License v3.0. Vedi [LICENSE](../../LICENSE) per i dettagli.

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | **Italiano** | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
