#!/usr/bin/env python3
"""Regenerate scripts/whisperkit_files.tsv: every file of each curated WhisperKit
model, pinned to one Hugging Face commit, with its size and SHA-256.

Maintainer tool (not run by setup). Bumping a pin: edit MODELS / revisions
below, run `python3 -I scripts/pin_whisperkit_models.py > scripts/whisperkit_files.tsv`,
then copy the printed per-model bytes + manifest digests (stderr) into
WhisperKitCatalog.swift; WhisperKitCatalogScriptParityTests checks the two agree.

LFS files' SHA-256 comes from the Hub's metadata; small git files are
downloaded and hashed.
"""
import hashlib
import json
import sys
import urllib.request

HF = "https://huggingface.co"
COREML_REPO = "argmaxinc/whisperkit-coreml"
COREML_REV = "0f63a7800b00dd0226abd051b906c246e1907482"

# id (local folder name) -> (folder in COREML_REPO, tokenizer repo)
MODELS = [
    ("tiny.en", "openai_whisper-tiny.en", "openai/whisper-tiny.en"),
    ("tiny", "openai_whisper-tiny", "openai/whisper-tiny"),
    ("base.en", "openai_whisper-base.en", "openai/whisper-base.en"),
    ("base", "openai_whisper-base", "openai/whisper-base"),
    ("small.en_217MB", "openai_whisper-small.en_217MB", "openai/whisper-small.en"),
    ("small.en", "openai_whisper-small.en", "openai/whisper-small.en"),
    ("small", "openai_whisper-small", "openai/whisper-small"),
    ("large-v3-v20240930_626MB", "openai_whisper-large-v3-v20240930_626MB", "openai/whisper-large-v3"),
    ("large-v3-v20240930", "openai_whisper-large-v3-v20240930", "openai/whisper-large-v3"),
]
TOKENIZER_FILES = ["tokenizer.json", "tokenizer_config.json"]


def get_json(url):
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def sha256_of(url):
    h = hashlib.sha256()
    with urllib.request.urlopen(url) as r:
        while chunk := r.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def tree(repo, rev, path=""):
    return get_json(f"{HF}/api/models/{repo}/tree/{rev}/{path}?recursive=true")


def main():
    revisions = {}
    print("# id\tsource (repo/resolve/rev/path)\tlocal path\tbytes\tsha256")
    for model_id, folder, tok_repo in MODELS:
        rows = []
        for e in tree(COREML_REPO, COREML_REV, folder):
            path = e["path"]
            local = path[len(folder) + 1:]
            # Only the compiled models (+ configs); .mlpackage sources are unused.
            if e["type"] != "file" or ".mlpackage/" in path:
                continue
            src = f"{COREML_REPO}/resolve/{COREML_REV}/{path}"
            sha = (e.get("lfs") or {}).get("oid") or sha256_of(f"{HF}/{src}")
            rows.append((local, src, e["size"], sha))
        if tok_repo not in revisions:
            revisions[tok_repo] = get_json(f"{HF}/api/models/{tok_repo}")["sha"]
        rev = revisions[tok_repo]
        sizes = {e["path"]: e for e in tree(tok_repo, rev)}
        for name in TOKENIZER_FILES:
            src = f"{tok_repo}/resolve/{rev}/{name}"
            e = sizes[name]
            sha = (e.get("lfs") or {}).get("oid") or sha256_of(f"{HF}/{src}")
            rows.append((name, src, e["size"], sha))
        rows.sort()
        manifest = "".join(f"{sha}  {local}\n" for local, _, _, sha in rows)
        digest = hashlib.sha256(manifest.encode()).hexdigest()
        total = sum(r[2] for r in rows)
        for local, src, size, sha in rows:
            print(f"{model_id}\t{src}\t{local}\t{size}\t{sha}")
        print(f"{model_id}: bytes={total} manifest={digest}", file=sys.stderr)


if __name__ == "__main__":
    main()
