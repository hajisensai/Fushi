#!/usr/bin/env python3
"""Export the pinned Chimahon YOLO26n panel detector to a static ONNX asset.

The repository intentionally does not contain weights. Install the exporter in an
isolated environment (torch, ultralytics, onnx, onnxruntime), download the exact
revision recorded in model_manifest.json, and run this script. The output is a
release asset, never a source checkout file.
"""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path

MODEL_REVISION = "535bbe1fc1e922d2108f918cd1bce29ba3516196"
MODEL_REPO = "leoxs22/manga-panel-detector-yolo26n"
MODEL_FILENAME = "manga_panel_detector_fp32.pt"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=Path("tool/manga_panel/model_manifest.json"))
    parser.add_argument("--asset-url", required=True, help="immutable GitHub release asset URL")
    args = parser.parse_args()
    if not args.weights.is_file():
        raise SystemExit(f"weights not found: {args.weights}")
    try:
        from ultralytics import YOLO
    except ImportError as exc:
        raise SystemExit("install torch and ultralytics in an isolated environment") from exc
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model = YOLO(str(args.weights))
    exported = Path(model.export(
        format="onnx", imgsz=640, batch=1, dynamic=False,
        simplify=False, opset=17, nms=True,
    ))
    exported.replace(args.output)
    metadata = {
        "model": "manga-panel-detector-yolo26n",
        "source": f"https://huggingface.co/{MODEL_REPO}",
        "sourceRevision": MODEL_REVISION,
        "sourceFile": MODEL_FILENAME,
        "assetUrl": args.asset_url,
        "assetFile": args.output.name,
        "sha256": sha256(args.output),
        "bytes": args.output.stat().st_size,
        "license": "Apache-2.0",
        "input": {"shape": [1, 3, 640, 640], "layout": "NCHW", "color": "RGB", "normalization": "0..1"},
        "output": {"shape": [1, 300, 6], "layout": "xyxy-score-class", "classes": {"0": "panel", "1": "text"}},
        "confidenceThreshold": 0.25,
        "nmsIouThreshold": 0.50,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
