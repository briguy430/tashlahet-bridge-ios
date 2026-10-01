from __future__ import annotations

import argparse
import os
from pathlib import Path
import secrets
import stat

import uvicorn

from .app import create_app


DEFAULT_TOKEN_FILE = Path.home() / "Library/Application Support/TashEnglish/server-token"
DEFAULT_CACHE = Path.home() / "Library/Caches/TashEnglish/models"


def load_token(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) & 0o022:
        raise ValueError("Token directory must be owned by you and not writable by other users.")
    if not path.exists():
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as file:
            file.write(secrets.token_urlsafe(32) + "\n")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as file:
        details = os.fstat(file.fileno())
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) & 0o077:
            raise ValueError("Token must be a regular file readable only by its owner (chmod 600).")
        return file.read().strip()


def main():
    from .engine import MMSTranslationEngine

    parser = argparse.ArgumentParser(description="Private, experimental Tashelhit speech bridge for a Mac mini.")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    parser.add_argument("--model-cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--allow-experimental-models", action="store_true", help="Run the research prototype despite its failed everyday translation benchmark.")
    arguments = parser.parse_args()
    if not arguments.allow_experimental_models:
        parser.error("These models failed the everyday translation quality check. For explicit evaluation only, pass --allow-experimental-models.")
    token = load_token(arguments.token_file)
    print("Loading pinned Tashelhit ASR and English translation models. No microphone audio is logged.", flush=True)
    engine = MMSTranslationEngine(arguments.model_cache)
    print("Models loaded. Translation quality is experimental; native-speaker validation is required.", flush=True)
    uvicorn.run(create_app(token, engine), host="127.0.0.1", port=arguments.port, access_log=False, log_level="warning")


if __name__ == "__main__":
    main()
