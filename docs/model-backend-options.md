# Tashelhit model research and local tests

Researched and executed on October 1, 2026 on an M4 Pro Mac mini with 24 GB unified memory. DeepAPI searches and primary-source scraping found released models with explicit Tashelhit (`shi`) coverage. Local inference used downloaded weights; no hosted inference API was used.

The search found real Tashelhit models, but the tested pipeline has not passed conversational translation acceptance. Moroccan Arabic (`ary`), Standard Moroccan Tamazight (`tzm`/`zgh`), and a generic Berber family label are not interchangeable with Tashelhit.

| Candidate | Declared capability | Observed local result |
| --- | --- | --- |
| [Meta MMS-1B-all](https://huggingface.co/facebook/mms-1b-all) | ASR with a dedicated `shi` adapter; [official language list](https://dl.fbaipublicfiles.com/mms/asr/mms1b_all_langs.html) | Downloaded and executed on a real six-second public Tashelhit clip. CPU 0.669 s, MPS 1.559 s. Identical output across devices. Reference is Arabic script and output Latin script, so no fair ASR accuracy score was established. |
| [Helsinki opus-mt-tc-bible-big-afa-en](https://huggingface.co/Helsinki-NLP/opus-mt-tc-bible-big-afa-en) | Explicit `shi` source and English target; Marian, Apache-2.0 | Runs on CPU. On 20 everyday DATASHI sentences in two spellings, 0/40 exact matches and several clear meaning errors. Exact-match rate alone is not semantic accuracy; the unrelated outputs are the substantive failure. |
| [Stock Whisper large-v3](https://huggingface.co/openai/whisper-large-v3) | [Official language table](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py) has no `shi` entry | Runs on MPS. On the same clip it detected Arabic and transcribed text different from the supplied reference. Direct English output was recorded but has no independent English reference. One clip is a failure example, not a population accuracy estimate. |
| Local `gemma4:12b-mlx` | Installed general model; Tashelhit speech support not established | Direct English translation of 20 standard text inputs gave many unrelated meanings. Nine published orthography examples improved a few inputs, but many remained unrelated. These experiments do not prove that all Gemma variants or prompts fail. |
| [Tachelhiyt Whisper fine-tuning paper](https://aclanthology.org/2025.icnlsp-1.37/) | Reports improved Tachelhiyt ASR after domain training | No public downloadable fine-tuned checkpoint was located in this search. A paper result is not a released runtime. |
| [DATASHI](https://arxiv.org/abs/2603.21571) | English–Tashelhit sentence pairs with expert-standardized data | Private evaluation material, not a speech model. Repository has no declared dataset license; fixtures and full predictions remain local and uncommitted. |

## Pinned runtime

- MMS revision: `3d33597edbdaaba14a8e858e2c8caa76e3cec0cd`; adapter `shi`; core SHA-256 `0f1d95ce43d27e03d5d8dd56c697c805460f967c793dd2cbec2e8e8012deda98`; adapter SHA-256 `82af05a7ea4176643a762ad64f56dfccd929f8f8c960c68ea7e22c8aa276aeb2`.
- Marian revision: `f45a5c7710f5707677b215710026d7aa69cb552c`; safetensors SHA-256 `50877591d55dc8d738437a2ed1be89836d0a35d040a2e4eaa50c5fd54b71d847`.
- Public audio dataset: `NoureddineMOR/tachelhiyt-darija`, revision `59e75e9103ffb1351f4033f6e06ab5333f31df0f`, row-group 0 / row 42 of the first training shard. The dataset offers only a train split, so this is a public probe, not established held-out ASR evaluation.
- MMS parameters: about 965 M, F32, roughly 3.9 GB. Marian safetensors: about 957 MB. MMS model card specifies CC-BY-NC-4.0; weights are not redistributed here.

Warm Marian sentence inference took 0.236–0.536 s; a cached fresh process completed 40 translations in 5.72 s. A real five-second audio POST through the local prototype produced model-generated English with the correct chunk/language fields. Observed request times varied from 0.738 to 8.508 s during the local session. These are request timings, not phrase-end-to-result measurements on an iPhone away from the mini. The clip has no English reference, so this proves execution rather than meaning.

## Evidence and rebuild paths

Ignored local evidence under `build/`:

- `mms-baseline/report.json`, `reproducible_probe.py`, and `sample/sample_metadata.json`: model/audio pins, acquisition, resources, actual ASR and Whisper outputs.
- `research/backend-models/PRIMARY_CANDIDATE.md` and `scrape-06-helsinki-pinned.json`: downloaded primary-source evidence.
- `research/backend-models/marian_predictions.json`, `marian_mms_probes.json`, and `run_marian_benchmark.py`: actual MT outputs and replay.
- `research/backend-models/ollama_gemma4_datashi_fewshot_comparison.md` and `run_ollama_gemma_fewshot_benchmark.py`: comparison and reference-exclusion evidence.
- `backend-e2e-report.json` and `backend-e2e-warm-report.json`: actual audio HTTP inference results. Tokens are not included.

The text fixture has 20 categories and excludes the nine published prompt examples. It is not an official held-out MT split. English references were withheld from every Gemma prompt. No native speaker has reviewed the ASR clip or the final translated audio results.

## Remaining acceptance requirement

The next useful model step is a released Tashelhit fine-tune, or domain training with appropriate bilingual speech/text data and independent evaluation. The app and experimental backend are ready to exercise such a model; neither fluent English nor a correct capability response establishes accurate translation. Acceptance needs actual family/conversation clips, independent English meanings, native-speaker review, and measured latency on the intended phone/network.
