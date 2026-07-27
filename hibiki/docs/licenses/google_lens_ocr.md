# Google Lens manga OCR interoperability

Hibiki's optional full-page Google Lens OCR adapter is derived from the
protobuf interoperability approach in
[`W1ght/Niratan`](https://github.com/W1ght/Niratan/tree/3300679abadd9b7a5590dbe73391e9262bf62b25/Features/Manga)
and its upstream Mangatan implementation. Those projects and Hibiki are
licensed under GPL-3.0.

The adapter calls an undocumented Chromium Lens endpoint. It is not a
supported Google API and may change or stop working. Hibiki only calls it
after an explicit engine selection and a versioned first-use disclosure.
Automatic OCR routing never selects Lens.

The request contains a resized JPEG copy of the manga page. Hibiki does not
log or send telemetry containing page images, OCR text, protobuf request
bodies, or the Chromium client key. Per-page OCR results are cached only on
the local device and may be cleared without changing the source manga.
