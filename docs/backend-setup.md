# Experimental Mac backend

The current models run on the Mac mini, not the iPhone. This prototype is useful for model evaluation; its English translation stage failed an everyday phrase benchmark. The launcher requires `--allow-experimental-models`, and the iPhone shows an accuracy warning. A working API does not establish trustworthy translation.

## Install and evaluate locally

From the repository root, create an isolated Python 3.12 environment:

```sh
uv venv --python 3.12 backend/.venv
uv pip install --python backend/.venv/bin/python -r backend/requirements.txt
PYTHONPATH=backend backend/.venv/bin/python -m pytest backend/tests -q
PYTHONPATH=backend backend/.venv/bin/python -m tashbridge.server --allow-experimental-models
```

The first start downloads pinned safetensors: MMS with its `shi` adapter (about 3.9 GB) and Marian English translation (about 957 MB). The CPU backend was tested on an M4 Pro with 24 GB unified memory. Default cache: `~/Library/Caches/TashEnglish/models`. Keep model weights out of Git.

The launcher creates a random token at `~/Library/Application Support/TashEnglish/server-token`, readable only by its owner. Never commit, screenshot, or paste it into a public issue. It binds HTTP only on `127.0.0.1:8000`; this address cannot be entered as the server on a physical iPhone. The token is required even for local evaluation.

The optional `TASH_MMS_MODEL_DIR` and `TASH_MT_MODEL_DIR` environment variables reuse existing local copies of those pinned snapshots. The operator must verify their provenance; use the default downloader otherwise. No hosted inference API is called. The backend does not record microphone audio or transcripts, and access logging is disabled.

## Connect away from the mini

For an explicit experimental evaluation, use a TLS reverse proxy. With Tailscale already installed and signed in on both devices:

```sh
tailscale serve --bg http://127.0.0.1:8000
tailscale serve status
```

Tailscale may require enabling HTTPS for the tailnet through its administrator link. Follow that account step yourself. Verify the status reports an HTTPS URL accessible inside your tailnet. Use that URL followed by `/inference` in the iPhone app, and enter the local server token in **Connection**. Tap **Test Connection** and read the accuracy warning before a trial. Do not enable public Funnel for this setup.

This configuration works away from home when the iPhone has internet and an active Tailscale connection. The mini and its backend must remain on and online. It is not offline iPhone inference. These instructions prepare the route; remote access is only verified after a successful request from the actual iPhone.

## Recovery and limits

- Stop the foreground backend with Control-C. No always-on service is installed automatically.
- 408 means the audio upload timed out; retry with a stable connection.
- 429 means another phrase owns the single slot; retry shortly.
- A model timeout returns 503 and quarantines inference. Restart the process before retrying; a stuck worker may need process termination. No new model jobs are allowed while it is quarantined.
- Models can return fluent but incorrect English. A native speaker and independent English references are needed for conversation acceptance. The prototype is not a substitute for that validation.

MMS is distributed under CC-BY-NC-4.0; the Marian checkpoint declares Apache-2.0. Check those model terms before distributing a derivative service. This repository does not redistribute model weights or the private evaluation fixture.
