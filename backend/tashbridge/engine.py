from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import torch
from huggingface_hub import snapshot_download
from transformers import AutoProcessor, MarianMTModel, MarianTokenizer, Wav2Vec2ForCTC


MMS_REPO = "facebook/mms-1b-all"
MMS_REVISION = "3d33597edbdaaba14a8e858e2c8caa76e3cec0cd"
MT_REPO = "Helsinki-NLP/opus-mt-tc-bible-big-afa-en"
MT_REVISION = "f45a5c7710f5707677b215710026d7aa69cb552c"


class MMSTranslationEngine:
    """Pinned Tashelhit ASR followed by a released, experimental English MT model."""

    model_description = f"{MMS_REPO}@{MMS_REVISION} (shi) → {MT_REPO}@{MT_REVISION}"

    def __init__(self, cache: Path):
        cache.mkdir(parents=True, exist_ok=True)
        mms_path = os.environ.get("TASH_MMS_MODEL_DIR") or snapshot_download(
            MMS_REPO, revision=MMS_REVISION, cache_dir=cache,
            allow_patterns=["*.json", "model.safetensors", "adapter.shi.safetensors", "vocab*/shi*"],
        )
        mt_path = os.environ.get("TASH_MT_MODEL_DIR") or snapshot_download(
            MT_REPO, revision=MT_REVISION, cache_dir=cache,
            allow_patterns=["*.json", "*.spm", "model.safetensors"],
        )
        self.processor = AutoProcessor.from_pretrained(mms_path, local_files_only=True)
        self.asr = Wav2Vec2ForCTC.from_pretrained(mms_path, local_files_only=True, use_safetensors=True)
        self.processor.tokenizer.set_target_lang("shi")
        self.asr.load_adapter("shi", local_files_only=True, use_safetensors=True)
        self.asr.eval().to("cpu")
        self.tokenizer = MarianTokenizer.from_pretrained(mt_path, local_files_only=True)
        self.translator = MarianMTModel.from_pretrained(mt_path, local_files_only=True, use_safetensors=True)
        self.translator.eval().to("cpu")

    def translate(self, samples: np.ndarray) -> str:
        encoded = self.processor(samples, sampling_rate=16000, return_tensors="pt")
        with torch.inference_mode():
            logits = self.asr(input_values=encoded.input_values).logits
            transcript = self.processor.decode(torch.argmax(logits, dim=-1)[0])
            if not transcript.strip():
                return ""
            text_inputs = self.tokenizer(transcript, return_tensors="pt", truncation=True, max_length=256)
            generated = self.translator.generate(**text_inputs, num_beams=4, max_new_tokens=96)
            return self.tokenizer.decode(generated[0], skip_special_tokens=True).strip()
