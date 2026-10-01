# Translation backend: current evidence and next gate

Researched October 1, 2026 using primary model cards, source code, and papers through the DeepAPI skill. No model was downloaded or run, and no live translation was tested.

The research did not identify a validated, ready-to-use Tashelhit speech-to-English backend. A multilingual model claiming broad coverage is not sufficient evidence for Tashelhit. Moroccan Arabic (`ary`) and Standard Moroccan Tamazight (`tzm`) should not be silently substituted for Tachelhit/Tashelhit (`shi`).

| Candidate | Source-supported capability | What remains missing |
| --- | --- | --- |
| [Meta MMS-1B-all](https://huggingface.co/facebook/mms-1b-all) | Speech recognition; the [official language list](https://dl.fbaipublicfiles.com/mms/asr/mms1b_all_langs.html) includes `shi` as Tachelhit | Produces transcription, not English translation; local performance and conversation accuracy remain unmeasured |
| [Standard Whisper](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py) | Official language table does not contain `shi` | Header changes do not create Tashelhit support |
| [Tachelhiyt Whisper fine-tuning paper](https://aclanthology.org/2025.icnlsp-1.37/) | Reports improved Tachelhiyt ASR after training on a small speech corpus | The search did not locate a publicly released trained checkpoint; paper results require independent replay |
| [DATASHI](https://arxiv.org/abs/2603.21571) | English–Tashlhiyt sentence-pair corpus with expert-standardized data | Training/evaluation material, not a running translation model |
| [SeamlessM4T-v2](https://huggingface.co/facebook/seamless-m4t-v2-large) | Model card lists supported translation languages | No Tashelhit `shi` entry was identified in its source-language table |

The most concrete exploration would use MMS `shi` as an ASR baseline, then separately evaluate a Tashelhit-to-English text translator. That is a proposed two-stage prototype, not a claim that an accurate conversation translator already exists. The iPhone protocol can connect to a backend that performs the required translation internally, provided it truthfully advertises its loaded capabilities and returns validated English.

Before bundling or offering that backend, review model/data licenses. MMS's model card specifies CC-BY-NC 4.0. Training and runtime requirements also remain unverified on this machine.

The acceptance gate is bilingual human review of actual speech clips with reference meanings, including dialect variation, noise and code-switching, plus measured phrase-end-to-result latency on the intended Mac/iPhone network. An ASR benchmark or correctly formatted API response does not establish translated meaning.

Evidence provenance: delegated research streamed and filtered DeepAPI responses; raw payloads were not saved locally. Relevant request IDs were `f2ebb0b2-73ea-4fe1-839f-040c8a7e9a5d` (MMS), `ef9dee22-0590-4771-ad0c-bc51ccae0571` (Whisper language table), `a1a068a1-b15e-4961-8059-218207f692c0` (fine-tuning paper), and `0517edb1-0a93-4988-a647-83e961a3492a` (DATASHI). The links above are the primary sources to revisit before implementation.
