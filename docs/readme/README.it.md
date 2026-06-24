<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Leggi un libro e fai tua ogni parola nuova.</b></p>
<p align="center">Lettore immersivo multipiattaforma e multilingue —— Lettura EPUB · Ricerca con tocco · Creazione schede Anki · Sincronizzazione audiolibri · Ricerca nei sottotitoli video</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Sito del progetto (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <b>Italiano</b> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduzione

**hibiki** è un lettore immersivo multipiattaforma per l'apprendimento delle lingue. Nel testo di un EPUB puoi **toccare per cercare nel dizionario e selezionare per analizzare**, trasformando ogni parola nuova in una scheda Anki con un solo tocco; sincronizza l'audio dell'audiolibro con il testo evidenziandolo frase per frase; e cerca e crea schede direttamente dai sottotitoli dei video. Un solo strumento per le tre forme di input immersivo: «leggere · ascoltare · guardare».

La ricerca nel dizionario copre **tutte le lingue di trasformazione** di [Yomitan](https://github.com/yomidevs/yomitan) (deflessione + normalizzazione del testo prima della ricerca), l'interfaccia è localizzata in **17 lingue** e supporta i cinque sistemi **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Libreria" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Ricerca" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Impostazioni e temi" width="300">
</p>
<p align="center"><sub>Libreria · Ricerca · Impostazioni e temi</sub></p>

---

## Funzionalità principali

### 📖 Lettura EPUB, ricerca con un tocco

Lettore EPUB renderizzato in WebView (motore di impaginazione derivato da [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)): tocca una parola qualsiasi per cercarla all'istante, seleziona una porzione di testo per analizzarla immediatamente. Doppia modalità scorrimento continuo e impaginazione, font e temi personalizzati (chiaro / scuro / nero puro / personalizzato), furigana, statistiche di lettura e segnalibri inclusi.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Lettura verticale · Furigana · Sincronizzazione audiolibri" width="300">
</p>
<p align="center"><sub>Testo verticale · Furigana · Evidenziazione selezione · Barra di controllo audiolibri in basso</sub></p>

### 🔍 Ricerca con tocco, copre tutte le lingue di trasformazione di Yomitan

Importa dizionari in più formati: **Yomitan** (ex Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Lemmatizzazione multilingue (tabelle di trasformazione Yomitan) + normalizzazione del testo prima della ricerca (maiuscole/minuscole / segni diacritici / harakat arabo), guidata dai code point e senza bisogno di cambiare lingua. Ricerca parallela su più dizionari, priorità e attivazione/disattivazione delle sotto-fonti, annotazione dell'accento tonale e frequenza, tutto in un unico popup.

### 🎴 Creazione di schede Anki con un tocco

Trovata una parola nuova, esportala in un passaggio verso [AnkiDroid](https://github.com/ankidroid/Anki-Android) e AnkiConnect. Schema del tipo di nota [Lapis](https://github.com/donkuri/lapis) integrato (vendored 1.7.0): puoi creare modelli di scheda e mazzi direttamente nell'app; compilazione automatica delle frasi di contesto, supporto per registrazione audio e ritaglio di screenshot, configurazioni di esportazione multiple (Profile), mappatura personalizzata dei campi e azioni rapide per creare una scheda in un solo passaggio.

### 🎧 Sincronizzazione audiolibri (Sasayaki)

Supporta sottotitoli SRT / LRC / VTT / ASS, allineando automaticamente il testo dei sottotitoli al contenuto EPUB. Durante la riproduzione **evidenzia il testo seguendo la lettura e cambia pagina in sincronia con l'audio**, insieme alla barra di controllo della riproduzione (progresso, ricerca, velocità): mentre ascolti, il testo si illumina frase per frase —— la barra di controllo in fondo allo screenshot di lettura in cima a questa pagina è proprio questa funzione.

### 🎬 Ricerca nei sottotitoli video

Lettore video integrato basato su media_kit / libmpv, con supporto per sottotitoli incorporati / esterni. Durante la riproduzione di un video puoi **cercare e creare schede direttamente sui sottotitoli**, includendo anche il materiale audiovisivo tra gli input immersivi; allo stesso tempo registra il tempo di visione e il numero di schede create.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Screenshot del lettore video da aggiungere.</sub></p>

### 🔗 Altro

- **17 lingue dell'interfaccia**, localizzazione su tutte le piattaforme
- **Hibiki Interconnect**: sincronizzazione tra dispositivi di libri / dizionari / audiolibri / progressi di lettura
- **Profili utente multipli (Profile)**, con cambio automatico per libro
- **Modalità in incognito**; **condivisione di testo da altre app per la ricerca diretta**

---

## Piattaforme supportate

| Piattaforma | Stato | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (rendering EPUB tramite il fork `flutter_inappwebview_windows`) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Minimo Android 7.0 (API 24). La lingua di ricerca del dizionario è determinata dai dizionari importati e dalle tabelle di trasformazione di Yomitan, indipendentemente dalla lingua dell'interfaccia.

### Lingue dell'interfaccia (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Installazione e compilazione

Preparazione con un solo comando (`flutter pub get` + applicazione delle patch), poi compila:

```bash
# nella radice del repository
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` raccoglie in un unico comando ① `flutter pub get` e ② `ci/apply-patches.sh`. Questo progetto è bloccato su Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); alcune dipendenze upstream sono vendorizzate in `third_party/` o corrette da `ci/apply-patches.sh` —— per i dettagli del meccanismo, la compilazione sui cinque sistemi e l'elenco di dipendenze e patch, vedi [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Stack tecnologico in breve</b></summary>

| Livello | Tecnologia |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Piattaforma | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adattivo) |
| Lettore | Motore di impaginazione WebView (derivato da [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Video | media_kit / libmpv |
| Archiviazione | Drift (SQLite, WAL) + hoshidicts (motore dizionario C++ FFI) |
| NLP | Tabelle di trasformazione Yomitan (lemmatizzazione multilingue) + kana_kit (conversione kana); la tokenizzazione passa per hoshidicts FFI |
| Creazione schede | AnkiDroid API + AnkiConnect |
| Internazionalizzazione | Slang (17 lingue) |

</details>

<details>
<summary><b>Struttura del progetto</b></summary>

```
hibiki/                      # Radice del repository (Melos workspace: hibiki_workspace)
├── hibiki/                  # Directory principale dell'app Flutter
│   ├── lib/
│   │   ├── i18n/            # Internazionalizzazione (17 lingue, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagine (libreria, lettore, dizionario, impostazioni, ecc.)
│   │   │   ├── reader/      # Script JS/CSS della WebView del lettore
│   │   │   ├── media/       # Audiolibri, parsing sottotitoli, reader source
│   │   │   └── models/      # Modelli dati e gestione dello stato (AppModel)
│   │   └── main.dart
│   └── android/             # Progetto Android (manifest, hoshidicts nativo)
├── packages/                # Pacchetti interni + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # Motore dizionario C++ hoshidicts (FFI)
├── third_party/             # Pacchetti patch vendorizzati (referenziati da dependency_overrides)
├── ci/                      # Patch di build e script di test di integrazione
├── tool/                    # Script bootstrap / i18n_sync, ecc.
└── docs/                    # Documentazione di sviluppo (incl. manuale agente docs/agent/)
```

</details>

---

## Ringraziamenti

| Progetto | Descrizione |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Strumento di apprendimento immersivo del giapponese |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lettore giapponese per Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motore dizionario C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lettore giapponese per iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Schema di sincronizzazione audiolibri |
| [Yomitan](https://github.com/yomidevs/yomitan) | Origine del formato dizionario e delle tabelle di trasformazione |
| [Lapis](https://github.com/donkuri/lapis) | Tipo di nota Anki |

## Licenza

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <b>Italiano</b> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
