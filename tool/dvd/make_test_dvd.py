"""Author a small UNENCRYPTED menu DVD for the native DVD probes.

    python tool/dvd/make_test_dvd.py --output NEW_DIR \
        [--ffmpeg ffmpeg] [--dvdauthor dvdauthor] [--spumux spumux]

The disc is generated from scratch (lavfi colour sources, Pillow-drawn button
subpictures), so it carries no third-party content and can be rebuilt anywhere
dvdauthor / spumux and an FFmpeg with the mpeg2video + ac3 encoders exist:

- First Play jumps to the VMGM title menu: a still (pause="inf") with three
  buttons in a row; select/action highlight colours are opaque so
  verify_menu_render.py can find them in the rendered frame.
- Title 1 (3 chapters) and title 2 are short NTSC MPEG-2 programmes whose
  post command returns to the title menu.
- VTS 1 also has a root menu with one button, so DVD_MENU_Root (discnav menu)
  and DVD_MENU_Title (discnav title-menu) reach two different domains.

Writes <output>/DVD/VIDEO_TS and <output>/manifest.json (the authored button
rectangles and colours, the expected titles and chapters).
"""
import argparse
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw

WIDTH, HEIGHT = 720, 480
# Button rectangles in source pixels (even coordinates: SPU fields).
BUTTONS = [(80, 360, 240, 400), (280, 360, 440, 400), (480, 360, 640, 400)]
NORMAL = (255, 255, 255)
HIGHLIGHT = (255, 224, 0)   # select state (focused)
ACTION = (230, 32, 32)      # action state (activated)


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def subpicture(path, colour, outline_only):
    image = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for x0, y0, x1, y1 in BUTTONS:
        if outline_only:
            draw.rectangle((x0, y0, x1 - 1, y1 - 1), outline=colour + (255,), width=4)
        else:
            draw.rectangle((x0, y0, x1 - 1, y1 - 1), fill=colour + (255,))
    image.save(path)


def mpeg(ffmpeg, path, seconds, video):
    sep = ":" if "=" in video else "="
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"{video}{sep}s={WIDTH}x{HEIGHT}:r=30000/1001",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-t", str(seconds), "-target", "ntsc-dvd", "-aspect", "4:3", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--dvdauthor", default="dvdauthor")
    parser.add_argument("--spumux", default="spumux")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"use a new output directory: {args.output}")
    work = args.output / "work"
    work.mkdir(parents=True)

    mpeg(args.ffmpeg, work / "menu_bg.mpg", 2, "color=c=0x203060")
    mpeg(args.ffmpeg, work / "root_bg.mpg", 2, "color=c=0x306020")
    mpeg(args.ffmpeg, work / "title1.mpg", 6, "testsrc2")
    mpeg(args.ffmpeg, work / "title2.mpg", 3, "smptebars")
    subpicture(work / "normal.png", NORMAL, outline_only=True)
    subpicture(work / "highlight.png", HIGHLIGHT, outline_only=False)
    subpicture(work / "select.png", ACTION, outline_only=False)

    buttons = "\n".join(
        f'      <button name="b{i + 1}" x0="{x0}" y0="{y0}" x1="{x1}" y1="{y1}"'
        f' left="b{max(i, 1)}" right="b{min(i + 2, len(BUTTONS))}"/>'
        for i, (x0, y0, x1, y1) in enumerate(BUTTONS))
    (work / "menu_spu.xml").write_text(f"""<subpictures format="NTSC">
  <stream>
    <spu start="00:00:00.00" force="yes" image="normal.png"
         highlight="highlight.png" select="select.png">
{buttons}
    </spu>
  </stream>
</subpictures>
""", encoding="utf-8")
    root_button = BUTTONS[1]
    (work / "root_spu.xml").write_text(f"""<subpictures format="NTSC">
  <stream>
    <spu start="00:00:00.00" force="yes" image="normal.png"
         highlight="highlight.png" select="select.png">
      <button name="r1" x0="{root_button[0]}" y0="{root_button[1]}"
              x1="{root_button[2]}" y1="{root_button[3]}"/>
    </spu>
  </stream>
</subpictures>
""", encoding="utf-8")
    for name in ("menu", "root"):
        with open(work / f"{name}_bg.mpg", "rb") as source, \
                open(work / f"{name}.mpg", "wb") as target:
            subprocess.run([args.spumux, "-m", "dvd", f"{name}_spu.xml"], stdin=source,
                           stdout=target, cwd=work, check=True)

    (work / "dvd.xml").write_text("""<dvdauthor dest="../DVD" jumppad="yes">
  <vmgm>
    <fpc>jump menu 1;</fpc>
    <menus>
      <video format="ntsc" aspect="4:3"/>
      <pgc entry="title">
        <vob file="menu.mpg" pause="inf"/>
        <button name="b1">jump title 1;</button>
        <button name="b2">jump title 1 chapter 2;</button>
        <button name="b3">jump title 2;</button>
      </pgc>
    </menus>
  </vmgm>
  <titleset>
    <menus>
      <video format="ntsc" aspect="4:3"/>
      <pgc entry="root">
        <vob file="root.mpg" pause="inf"/>
        <button name="r1">jump title 1;</button>
      </pgc>
    </menus>
    <titles>
      <video format="ntsc" aspect="4:3"/>
      <pgc>
        <vob file="title1.mpg" chapters="0,0:02,0:04"/>
        <post>call vmgm menu 1;</post>
      </pgc>
      <pgc>
        <vob file="title2.mpg"/>
        <post>call vmgm menu 1;</post>
      </pgc>
    </titles>
  </titleset>
</dvdauthor>
""", encoding="utf-8")
    # dvdauthor resolves vob paths and dest against its working directory.
    subprocess.run([args.dvdauthor, "-x", "dvd.xml"], cwd=work, check=True)
    video_ts = args.output / "DVD" / "VIDEO_TS"
    if not (video_ts / "VIDEO_TS.IFO").is_file():
        raise SystemExit("dvdauthor produced no VIDEO_TS/VIDEO_TS.IFO")
    (args.output / "manifest.json").write_text(json.dumps({
        "video_ts": str(video_ts),
        "source_size": [WIDTH, HEIGHT],
        "vmgm_buttons": [list(b) for b in BUTTONS],
        "vtsm_root_buttons": [list(root_button)],
        "colours": {"normal": NORMAL, "highlight": HIGHLIGHT, "action": ACTION},
        "titles": {"1": {"chapters": 3, "seconds": 6}, "2": {"chapters": 1, "seconds": 3}},
    }, indent=2) + "\n", encoding="utf-8")
    print(video_ts)


if __name__ == "__main__":
    main()
