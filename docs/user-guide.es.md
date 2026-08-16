# La guía de Fushi que hasta Yui Hirasawa configura en 5 minutos

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | **Español** | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> La guía en chino simplificado está alojada en Feishu (enlace arriba). La guía en inglés también está disponible [en GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Introducción

**Fushi: convierte los atracones de lectura y de series en input lingüístico.**

Toca cualquier palabra para buscarla mientras lees novelas, ves anime o escuchas audiolibros, y envía las palabras nuevas a Anki junto con la frase de la que proceden.

Sin listas de vocabulario predefinidas: solo repasas las palabras con las que realmente te has topado. Funciona con cualquier idioma.

- 📖 Lectura de EPUB · toca para buscar
- 🎧 Audiolibros con resaltado frase por frase
- 🎬 Búsqueda en subtítulos de vídeo y creación de tarjetas
- 🃏 Creación de tarjetas de Anki con un toque + estadísticas de repaso
- 📚 Lectura de manga · busca palabras directamente en la página mediante OCR
- ⬇️ Descargas dentro de la app con un toque para anime y manga: se añaden automáticamente a tu biblioteca y se pueden reproducir mientras aún se descargan
- 🎮 Minería de voz en Galgame (Windows) · la línea de voz original se incluye en la tarjeta junto con el texto

Plataformas: Android / Windows / macOS / iOS (Linux se puede compilar desde el código fuente; todavía no hay paquetes precompilados)

### URL del proyecto

https://github.com/hajisensai/Fushi

En desarrollo activo: tus comentarios se atenderán con prontitud. Los informes de errores y las solicitudes de funciones son bienvenidos. Si Fushi te resulta útil, te agradeceríamos que lo compartieras con otras personas o que dejaras una ⭐ en el repositorio.

### Descarga

https://github.com/hajisensai/Fushi/releases/latest

Elige el archivo que corresponda a tu plataforma: **Android**: el APK `arm64-v8a` (todos los teléfonos de los últimos años lo usan; solo los dispositivos más antiguos necesitan `armeabi-v7a`, y los emuladores usan `x86_64`); **Windows**: `windows-setup.exe`; **macOS**: `macos.zip`; **iOS**: `ios.ipa`. **Linux** todavía no tiene paquete precompilado, así que hay que compilarlo desde el código fuente.

Los APK cuyo nombre empieza por `bridge-` son puentes de migración para los **usuarios del antiguo Hibiki**; puedes ignorarlos.

## Tutorial de configuración

### 1. Importar los diccionarios recomendados (diccionarios de palabras + acento tonal + frecuencia) y el audio local (bases de datos de audio en japonés e inglés) (Muy recomendado para principiantes!!! · opcional)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Descarga desde Cloudflare (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

En la aplicación: Ajustes -> Sincronización y copia de seguridad -> toca **Importar copia de seguridad**.

![Pantalla de importación de copia de seguridad](static-assets/user-guide/import-backup.png)

### 2. Descargar y configurar Anki desde el sitio oficial de Anki

Anki —cuyo nombre proviene de 暗記 (あんき)— es el [sistema de repetición espaciada (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) más utilizado del mundo y una herramienta muy importante.

Enlaces: [Sitio oficial de Anki](https://apps.ankiweb.net/) · [Manual (chino)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [Preguntas frecuentes](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(chino)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Página de descarga de Anki](static-assets/user-guide/anki-download.png)

Puedes darle a Anki cualquier material que quieras memorizar, y te permite lograr la mejor retención con el menor tiempo de estudio.

Anki incorpora [FSRS](https://github.com/open-spaced-repetition/fsrs4anki), uno de los mejores algoritmos de repetición espaciada del mundo.

**¡PERO!!!** El algoritmo predeterminado de Anki es SM2, un algoritmo de hace más de 30 años que rinde mal. Asegúrate de cambiar el algoritmo que usa Anki a **FSRS**.

#### Anki

##### Android

1. Instala y abre Anki.
2. Vuelve a Fushi y ve a Ajustes -> Creación de tarjetas.
3. Toca **Actualizar mazos y tipos de nota** (marcado con un "1" en la imagen); Fushi solicitará permiso: toca Permitir.
4. Toca **Crear mazo Lapis** (marcado con un "2" en la imagen).
5. Si no aparece ninguna advertencia ni error en rojo, la configuración fue exitosa.

![Configuración de Anki en Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Instala y abre Anki.
2. Haz clic en **Herramientas (Tools)** en la parte superior izquierda.

![Menú Herramientas de Anki en Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Pega el siguiente código del complemento de Anki para instalarlo: `2055492159`
4. Vuelve a Fushi y ve a Ajustes -> Creación de tarjetas.
5. Toca **Actualizar mazos y tipos de nota** (marcado con "1").
6. Toca **Crear mazo Lapis** (marcado con "2").
7. Si no aparece ninguna advertencia ni error en rojo, la configuración fue exitosa.

![Configuración de Anki en Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Revisa las opciones de configuración en Ajustes y comprueba si hay algo que quieras ajustar. (Opcional)

Es hora de empezar a sumergirte.

## Funciones recomendadas

### Buscar palabras fuera de la aplicación

**Android:** selecciona una palabra y luego toca **Traducir** o **Fushi** en el menú de selección.

**Windows:** selecciona una palabra y luego pulsa **Ctrl+Alt+D** (el atajo se puede cambiar en Ajustes -> Atajos de teclado).

### Búsqueda desde el portapapeles

Todo lo que copies se busca automáticamente. Hay dos modos de presentación disponibles —el **panel flotante** y la **ventana de texto transparente**—, ambos configurables en Ajustes -> Búsqueda.

### Búsqueda en el navegador / minería de subtítulos en streaming (Netflix)

Instala la extensión de navegador desde la página de inicio de Fushi.

## Agradecimientos

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
