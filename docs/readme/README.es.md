<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Lee un libro y haz tuya cada palabra nueva.</b></p>
<p align="center">Lector inmersivo multiplataforma y multilingüe —— lectura de EPUB · búsqueda de palabras con un toque · creación de tarjetas Anki · sincronización de audiolibros · búsqueda en subtítulos de vídeo</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Página del proyecto (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introducción

**hibiki** es un lector inmersivo de aprendizaje de idiomas multiplataforma. Dentro del texto del EPUB, **toca para buscar una palabra, selecciona para analizarla** y convierte las palabras desconocidas en tarjetas Anki con un solo toque; sincroniza el audio del audiolibro con el texto y resáltalo frase por frase; incluso puedes buscar palabras y crear tarjetas directamente desde los subtítulos de un vídeo. Una sola herramienta que cubre las tres entradas inmersivas: leer · escuchar · ver.

La búsqueda en diccionarios cubre **todos los idiomas de transformación de [Yomitan](https://github.com/yomidevs/yomitan)** (deflexión + normalización del texto previa a la búsqueda), la interfaz está localizada en **17 idiomas** y funciona en las cinco plataformas: **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Estantería" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Búsqueda" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Ajustes y temas" width="300">
</p>
<p align="center"><sub>Estantería · Búsqueda · Ajustes y temas</sub></p>

---

## Características

### 📖 Lectura de EPUB, toca para buscar

Un lector de EPUB renderizado en WebView (motor de paginación derivado de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) te permite buscar cualquier palabra al instante con un toque y analizar una selección al vuelo. Modos dobles de desplazamiento continuo y paginado, fuentes y temas personalizables (claro / oscuro / negro puro / personalizado), furigana, estadísticas de lectura y marcadores: lo tiene todo.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Lectura vertical · furigana · sincronización de audiolibro" width="300">
</p>
<p align="center"><sub>Texto vertical · furigana · resaltado de selección · barra de control de sincronización de audiolibro en la parte inferior</sub></p>

### 🔍 Búsqueda con un toque, cubriendo todos los idiomas de transformación de Yomitan

Importa diccionarios en varios formatos: **Yomitan** (antes Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Lematización multilingüe (tablas de transformación de Yomitan) más normalización del texto previa a la búsqueda (mayúsculas/minúsculas / diacríticos / harakat árabe), impulsada por puntos de código y sin necesidad de cambiar de idioma. Consultas paralelas en varios diccionarios, prioridad y activación/desactivación de subfuentes, anotaciones de acento tonal y frecuencia de palabras: todo se resuelve en una sola ventana emergente.

### 🎴 Creación de tarjetas Anki con un toque

Cuando encuentres una palabra nueva, expórtala a [AnkiDroid](https://github.com/ankidroid/Anki-Android) y AnkiConnect en un solo paso. El esquema de tipo de nota [Lapis](https://github.com/donkuri/lapis) integrado (vendorizado 1.7.0) te permite crear plantillas de tarjetas y mazos directamente dentro de la app; autocompleta la oración de contexto, admite grabación de audio y recorte de capturas de pantalla, múltiples perfiles de exportación (Profile), mapeo de campos personalizado y acciones rápidas (Quick Actions) para crear tarjetas en un paso.

### 🎧 Sincronización de audiolibros (Sasayaki)

Admite subtítulos SRT / LRC / VTT / ASS y alinea automáticamente el texto de los subtítulos con el cuerpo del EPUB. Durante la reproducción, **el resaltado de seguimiento y el paso de página sincronizado con el audio** iluminan el texto frase por frase mientras escuchas, junto con la barra de controles de reproducción (progreso, saltar, velocidad): la barra de control en la parte inferior de la captura de lectura de arriba es exactamente esta función.

### 🎬 Búsqueda en subtítulos de vídeo

Un reproductor de vídeo integrado basado en media_kit / libmpv admite subtítulos incrustados y externos. Mientras reproduces un vídeo, **busca palabras y crea tarjetas directamente desde los subtítulos**, incorporando también el material audiovisual a tu entrada inmersiva; además registra el tiempo de visualización y el número de tarjetas creadas.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Captura del reproductor de vídeo pendiente —— debe capturarse en un dispositivo real / en primer plano (cuadro de vídeo + barra de subtítulos + ventana emergente de búsqueda; consulta la nota más abajo).</sub></p>

### 🔗 Más

- **17 idiomas de interfaz**, totalmente localizados en todas las plataformas
- **Interconexión Hibiki**: sincroniza libros / diccionarios / audiolibros / progreso de lectura entre dispositivos
- **Múltiples perfiles de usuario (Profile)**, con cambio automático según el libro
- **Modo incógnito**; **comparte texto desde otras apps para buscar palabras directamente**

---

## Compatibilidad de plataformas

| Plataforma | Estado | Renderizado / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (EPUB renderizado por el `flutter_inappwebview_windows` bifurcado) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Mínimo Android 7.0 (API 24). Los idiomas disponibles para la búsqueda en diccionarios dependen de los diccionarios que importes y de las tablas de transformación de Yomitan, de forma independiente al idioma de la interfaz.

### Idiomas de interfaz (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Instalación y compilación

Preparación con un solo comando (`flutter pub get` + aplicar parches), luego compilar:

```bash
# 在仓库根目录
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` reúnen ① `flutter pub get` y ② `ci/apply-patches.sh` en un solo comando. Este proyecto está fijado a Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); algunas dependencias upstream se vendorizan en `third_party/` o las parchea `ci/apply-patches.sh` —— para los detalles del mecanismo, las compilaciones de las cinco plataformas y la lista de dependencias y parches, consulta [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Stack tecnológico de un vistazo</b></summary>

| Capa | Tecnología |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plataformas | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptativo) |
| Lector | Motor de paginación WebView (derivado de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Vídeo | media_kit / libmpv |
| Almacenamiento | Drift (SQLite, WAL) + hoshidicts (motor de diccionarios C++ FFI) |
| NLP | Tablas de transformación de Yomitan (lematización multilingüe) + kana_kit (conversión de kana); tokenización mediante hoshidicts FFI |
| Creación de tarjetas | AnkiDroid API + AnkiConnect |
| Internacionalización | Slang (17 idiomas) |

</details>

<details>
<summary><b>Estructura del proyecto</b></summary>

```
hibiki/                      # Raíz del repositorio (workspace Melos: hibiki_workspace)
├── hibiki/                  # Directorio principal de la aplicación Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalización (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (estantería, lector, diccionario, ajustes, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS de la WebView del lector
│   │   │   ├── media/       # Audiolibros, análisis de subtítulos, reader source
│   │   │   └── models/      # Modelos de datos y gestión de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Proyecto Android (manifest, hoshidicts nativo)
├── packages/                # Paquetes internos + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # Motor de diccionarios C++ hoshidicts (FFI)
├── third_party/             # Paquetes de parches vendorizados (referenciados por dependency_overrides)
├── ci/                      # Parches de compilación y scripts de pruebas de integración
├── tool/                    # Scripts bootstrap / i18n_sync, etc.
└── docs/                    # Documentación de desarrollo (incluye el manual de agente docs/agent/)
```

</details>

---

## Agradecimientos

| Proyecto | Descripción |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Herramienta de aprendizaje inmersivo de japonés |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lector de japonés para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motor de diccionarios C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lector de japonés para iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solución de sincronización de audiolibros |
| [Yomitan](https://github.com/yomidevs/yomitan) | Fuente del formato de diccionarios y las tablas de transformación |
| [Lapis](https://github.com/donkuri/lapis) | Tipo de nota de Anki |

## Licencia

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
