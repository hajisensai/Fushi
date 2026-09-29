/// Offline Python worker for the original manga-ocr checkpoint.
///
/// Keep the source in the Dart bundle so installed/compiled apps can materialize
/// exactly the worker version that their JSONL client understands.
const String kMangaOcrCudaWorkerSource = r'''
import argparse
import base64
import ctypes
import gc
import io
import json
import os
import queue
import re
import sys
import threading
import time


def emit(value):
    protocol_output.write(json.dumps(value, ensure_ascii=True) + "\n")
    protocol_output.flush()


protocol_output = sys.stdout
# Library diagnostics must never appear on the JSONL protocol stream.
sys.stdout = sys.stderr
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

parser = argparse.ArgumentParser()
parser.add_argument("--model-dir", required=True)
parser.add_argument("--batch-size", type=int, default=8)
parser.add_argument("--parent-pid", type=int, required=True)
args = parser.parse_args()
if not 1 <= args.batch_size <= 8:
    parser.error("batch size must be between 1 and 8")

requests = queue.SimpleQueue()


def read_requests():
    # This thread starts before torch import/model loading. An isolate killed
    # during startup or inference closes its pipe even while the app lives on.
    try:
        if os.name == "nt":
            # A blocking CRT stdin read during NumPy/OpenBLAS DLL loading can
            # deadlock (numpy/numpy#24290). Read the pipe directly without the
            # CRT file lock so cancellation still works before heavy imports.
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.GetStdHandle.argtypes = [ctypes.c_uint32]
            kernel.GetStdHandle.restype = ctypes.c_void_p
            kernel.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
            kernel.ReadFile.restype = ctypes.c_int
            handle = kernel.GetStdHandle(0xFFFFFFF6)  # STD_INPUT_HANDLE (-10)
            buffer = ctypes.create_string_buffer(65536)
            received = ctypes.c_uint32()
            pending = bytearray()
            while kernel.ReadFile(handle, buffer, len(buffer),
                                  ctypes.byref(received), None) and received.value:
                pending.extend(buffer.raw[:received.value])
                while True:
                    boundary = pending.find(b"\n")
                    if boundary < 0:
                        break
                    requests.put(bytes(pending[:boundary]).decode("utf-8"))
                    del pending[:boundary + 1]
        else:
            for line in sys.stdin:
                requests.put(line)
    finally:
        os._exit(0)


def watch_parent():
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel.WaitForSingleObject.restype = ctypes.c_uint32
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x00100000, False, args.parent_pid)
        if not handle:
            os._exit(0)
        try:
            # Keep a process handle, not a repeatedly looked-up PID which could
            # be reused after the parent dies.
            kernel.WaitForSingleObject(handle, 0xFFFFFFFF)
        finally:
            kernel.CloseHandle(handle)
            os._exit(0)
    else:
        while True:
            if os.getppid() != args.parent_pid:
                os._exit(0)
            time.sleep(0.5)


threading.Thread(target=read_requests, daemon=True).start()
threading.Thread(target=watch_parent, daemon=True).start()


def main():
    import torch
    import jaconv
    from PIL import Image
    from transformers import (
        BertTokenizer, GenerationMixin, ViTImageProcessor,
        VisionEncoderDecoderModel,
    )

    class MangaOcrModel(VisionEncoderDecoderModel, GenerationMixin):
        pass

    torch.set_num_threads(2)
    model_dir = os.path.abspath(args.model_dir)
    if not os.path.isdir(model_dir):
        raise ValueError("local model directory does not exist")
    processor = ViTImageProcessor.from_pretrained(
        model_dir, local_files_only=True, trust_remote_code=False,
    )
    # Recognition only decodes character IDs. BertTokenizer preserves that
    # vocabulary without loading MeCab/fugashi or a Japanese input dictionary.
    tokenizer = BertTokenizer.from_pretrained(
        model_dir, local_files_only=True, trust_remote_code=False,
    )
    model = MangaOcrModel.from_pretrained(
        model_dir, local_files_only=True, trust_remote_code=False,
    ).eval()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    batch_size = args.batch_size
    reasons = []
    if device == "cpu":
        reasons.append("CUDA is unavailable; using CPU")
        batch_size = 1
    load_out_of_memory = False
    try:
        model.to(device)
    except torch.cuda.OutOfMemoryError:
        load_out_of_memory = True
    if load_out_of_memory:
        device = "cpu"
        batch_size = 1
        reasons.append("CUDA out of memory while loading the model; using CPU")
        model.to(device)
        gc.collect()
        torch.cuda.empty_cache()

    def status(event, **extra):
        return dict(event=event, protocol=1, device=device,
                    batch_size=batch_size, degrade_reasons=list(reasons), **extra)

    def normalize(text):
        text = "".join(text.split()).replace("…", "...")
        text = re.sub("[・.]{2,}", lambda match: "." * len(match.group()), text)
        return jaconv.h2z(text, ascii=True, digit=True)

    def infer(images):
        pixels = processor(images=images, return_tensors="pt").pixel_values.to(device)
        with torch.inference_mode():
            tokens = model.generate(
                pixels, use_cache=True, num_beams=4, early_stopping=True,
                max_length=300, length_penalty=2.0, no_repeat_ngram_size=3,
                decoder_start_token_id=2, pad_token_id=0, eos_token_id=3,
            )
        return [normalize(text) for text in
                tokenizer.batch_decode(tokens, skip_special_tokens=True)]

    emit(status("ready"))
    while True:
        request_id = None
        try:
            request = json.loads(requests.get())
            request_id = request["id"]
            if type(request_id) is not int or request.get("op") != "recognize":
                raise ValueError("invalid recognition request")
            encoded = request["images"]
            if not isinstance(encoded, list) or not 1 <= len(encoded) <= 8:
                raise ValueError("each request must contain between 1 and 8 images")
            images = []
            for value in encoded:
                with Image.open(io.BytesIO(base64.b64decode(value, validate=True))) as image:
                    # Official manga-ocr preprocessing: PIL gray -> RGB, then
                    # its saved ViTImageProcessor resize/normalization config.
                    images.append(image.convert("L").convert("RGB"))
            texts = []
            offset = 0
            while offset < len(images):
                count = min(batch_size, len(images) - offset)
                out_of_memory = False
                try:
                    decoded = infer(images[offset:offset + count])
                except torch.cuda.OutOfMemoryError:
                    if device != "cuda":
                        raise
                    out_of_memory = True
                if out_of_memory:
                    # Leave the except scope first so its traceback does not
                    # retain the failed generation tensors during cache cleanup.
                    gc.collect()
                    torch.cuda.empty_cache()
                    if count > 1:
                        batch_size = max(1, count // 2)
                        reasons.append("CUDA out of memory; batch size reduced to " + str(batch_size))
                    else:
                        model.to("cpu")
                        device = "cpu"
                        batch_size = 1
                        reasons.append("CUDA out of memory at batch size 1; using CPU")
                        gc.collect()
                        torch.cuda.empty_cache()
                    emit(status("status"))
                    continue
                if len(decoded) != count:
                    raise RuntimeError("model returned the wrong number of texts")
                texts.extend(decoded)
                offset += count
            emit(status("result", id=request_id, texts=texts))
        except Exception as error:
            emit(dict(event="error", id=request_id,
                      message=type(error).__name__ + ": " + str(error)))


try:
    main()
except Exception as error:
    emit(dict(event="error", message=type(error).__name__ + ": " + str(error)))
    sys.exit(1)
''';
