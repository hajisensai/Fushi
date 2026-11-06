#!/usr/bin/env bash
# Generates throwaway test media in ~/fushi-test/dummy (WSL / any Linux).
set -euo pipefail
D="${DUMMY:-$HOME/fushi-test/dummy}"
rm -rf "$D"; mkdir -p "$D/manga"
cd "$D"

python3 - <<'PY'
import zipfile, json
# --- EPUB (Japanese, 2 chapters) ---
with zipfile.ZipFile('dummy_book.epub', 'w') as z:
    z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
    z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    chapters = {
        'ch1': ('第一章', '今日は日本語を勉強します。猫が窓の外を見ています。<ruby>漢字<rt>かんじ</rt></ruby>は難しいですが、面白いです。'),
        'ch2': ('第二章', '明日は図書館へ行きます。本を三冊借りるつもりです。'),
    }
    for cid, (title, body) in chapters.items():
        paras = ''.join(f'<p>{body}</p>' for _ in range(30))
        z.writestr(f'OEBPS/{cid}.xhtml', f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja"><head><title>{title}</title></head><body><h1>{title}</h1>{paras}</body></html>')
    z.writestr('OEBPS/nav.xhtml', '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目次</title></head><body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">第一章</a></li><li><a href="ch2.xhtml">第二章</a></li></ol></nav></body></html>')
    z.writestr('OEBPS/content.opf', '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">fushi-dummy-book-1</dc:identifier><dc:title>テスト本</dc:title><dc:language>ja</dc:language><dc:creator>Fushi Smoke</dc:creator><meta property="dcterms:modified">2026-11-03T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch1"/><itemref idref="ch2"/></spine></package>')

# --- Yomitan dictionary (format 3) ---
terms = [
    ["日本語", "にほんご", "n", "", 10, ["Japanese (language)"], 1, ""],
    ["勉強", "べんきょう", "n vs", "", 10, ["study"], 2, ""],
    ["猫", "ねこ", "n", "", 10, ["cat"], 3, ""],
    ["図書館", "としょかん", "n", "", 10, ["library"], 4, ""],
    ["漢字", "かんじ", "n", "", 10, ["kanji; Chinese characters"], 5, ""],
]
with zipfile.ZipFile('dummy_dict.zip', 'w') as z:
    z.writestr('index.json', json.dumps({"title": "Fushi Smoke Dict", "revision": "1", "format": 3, "sequenced": True}, ensure_ascii=False))
    z.writestr('term_bank_1.json', json.dumps(terms, ensure_ascii=False))

# --- PDF (3 pages, ASCII text) ---
objs = []
pages = 3
kids = ' '.join(f'{4 + i*2} 0 R' for i in range(pages))
objs.append('<< /Type /Catalog /Pages 2 0 R >>')
objs.append(f'<< /Type /Pages /Kids [{kids}] /Count {pages} >>')
objs.append('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
for i in range(pages):
    stream = f'BT /F1 36 Tf 72 700 Td (Fushi smoke PDF page {i+1}) Tj ET'
    objs.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {5 + i*2} 0 R >>')
    objs.append(f'<< /Length {len(stream)} >>\nstream\n{stream}\nendstream')
out = b'%PDF-1.4\n'; offs = []
for n, o in enumerate(objs, 1):
    offs.append(len(out)); out += f'{n} 0 obj\n{o}\nendobj\n'.encode()
x = len(out)
out += f'xref\n0 {len(objs)+1}\n0000000000 65535 f \n'.encode() + b''.join(f'{o:010d} 00000 n \n'.encode() for o in offs)
out += f'trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n'.encode()
open('dummy_doc.pdf', 'wb').write(out)

# --- Japanese subtitles for the video ---
open('dummy_clip.ja.srt', 'w', encoding='utf-8').write(
    "1\n00:00:01,000 --> 00:00:04,000\n今日は日本語を勉強します。\n\n"
    "2\n00:00:05,000 --> 00:00:08,000\n猫が窓の外を見ています。\n\n")
PY

ffmpeg -loglevel error -f lavfi -i testsrc=duration=10:size=1280x720:rate=30 \
  -f lavfi -i sine=frequency=440:duration=10 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest dummy_clip.mp4
ffmpeg -loglevel error -f lavfi -i sine=frequency=660:duration=12 -metadata title="Smoke Song" \
  -metadata artist="Fushi Smoke" -metadata album="Smoke Album" -c:a libmp3lame -q:a 6 dummy_song.mp3
for i in 1 2 3; do
  ffmpeg -loglevel error -f lavfi -i "testsrc2=size=800x1200:duration=1" -frames:v 1 "manga/page_00$i.png"
done
python3 -c "
import zipfile,glob
with zipfile.ZipFile('dummy_manga.cbz','w') as z:
    [z.write(p, p.split('/')[-1]) for p in sorted(glob.glob('manga/*.png'))]
"
rm -rf manga
ls -la "$D"
