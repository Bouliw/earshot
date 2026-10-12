"""Live speech-to-text with Kyutai STT on MLX, for Earshot's "High" subtitles.

Usage: python kyutai-stt.py MODEL_DIR
Reads 24 kHz mono float32 audio on stdin and writes each piece of text as soon as it is recognized,
one per line (a piece that starts a word starts with a space). An empty line means the model is loaded:
audio sent before it is not waited for. Stops at the end of stdin.
"""
import json
import queue
import sys
import threading
from pathlib import Path

import mlx.core as mx
import numpy as np
import rustymimi
import sentencepiece
from moshi_mlx import models, utils

FRAME = 1920  # 80 ms at 24 kHz: one model step
MAX_STEPS = 6000  # 8 min of steps kept by the generator
BEHIND = 25  # frames waiting (2 s): drop audio to stay live


def main():
    folder = Path(sys.argv[1])
    raw = json.loads((folder / "config.json").read_text())
    config = models.LmConfig.from_config_dict(raw)
    model = models.Lm(config)
    model.set_dtype(mx.bfloat16)
    model.load_weights(str(folder / "model.safetensors"), strict=True)
    text_tokenizer = sentencepiece.SentencePieceProcessor(str(folder / raw["tokenizer_name"]))
    other = config.other_codebooks
    audio_tokenizer = rustymimi.Tokenizer(
        str(folder / raw["mimi_name"]), num_codebooks=max(config.generated_codebooks, other)
    )
    model.warmup()

    frames = queue.Queue()

    def read():
        while chunk := sys.stdin.buffer.read(FRAME * 4):
            frames.put(np.frombuffer(chunk[: len(chunk) // 4 * 4], dtype=np.float32))
        frames.put(None)

    threading.Thread(target=read, daemon=True).start()

    def fresh():
        for c in model.transformer_cache:
            c.reset()
        return models.LmGen(
            model=model,
            max_steps=MAX_STEPS,
            text_sampler=utils.Sampler(top_k=25, temp=0),
            audio_sampler=utils.Sampler(top_k=250, temp=0.8),
            check=False,
        )

    gen, quiet = fresh(), 0
    print(flush=True)
    while (block := frames.get()) is not None:
        if frames.qsize() > BEHIND:
            continue
        block = np.pad(block, (0, FRAME - len(block)))
        tokens = audio_tokenizer.encode_step(block[None, None, :])
        tokens = mx.array(tokens).transpose(0, 2, 1)[:, :, :other]
        token = gen.step(tokens[0])[0].item()
        if token not in (0, 3):  # padding
            print(text_tokenizer.id_to_piece(token).replace("▁", " "), flush=True)
            quiet = 0
        else:
            quiet += 1
        # The generator stores every step: start a new one at a pause, long before it is full.
        if (gen.step_idx > MAX_STEPS - 1500 and quiet > 12) or gen.step_idx >= MAX_STEPS - 1:
            gen, quiet = fresh(), 0


if __name__ == "__main__":
    main()
