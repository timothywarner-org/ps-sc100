#!/usr/bin/env python3
"""
sync_corpus.py -- snapshot your downloaded Learn corpus into private, versioned Azure Blob Storage.

Part of the OPTIONAL Azure path. Nothing in the local path needs it.

WHY THIS EXISTS
---------------
Microsoft Learn is a moving target. The April 2026 refresh inserted nine AI units
across all four SC-100 learning paths without renumbering anything around them. When
that happens again, you will want to answer one question precisely:

    "Did my answers change because Microsoft changed the training, or because I
     changed the chunker?"

Blob versioning answers it. Every upload preserves the prior version, and the snapshot
manifest records a SHA-256 per file, so a changed unit becomes a diff rather than an
argument from memory. Those two causes have opposite remedies and are
indistinguishable without a snapshot. See docs/ADR-003-source-archive.md.

ARCHIVE, NOT INGESTION SOURCE
-----------------------------
Nothing in Azure reads this container. There is no indexer and no data source pointed
at it, deliberately: ADR-002 rejected indexer-driven chunking for this corpus, and
adding a container does not reopen that decision. chunk_learn.py still chunks locally
and ingest_azure.py still pushes. This is where the inputs are KEPT.

KEEP IT PRIVATE
---------------
The corpus is Microsoft's copyrighted training content, downloaded for YOUR personal
study. The storage account in infra/main.bicep refuses anonymous access
(`allowBlobPublicAccess: false`) and account keys (`allowSharedKeyAccess: false`), and
the containers are created with `publicAccess: None`. Leave all three that way. A
public container would turn a personal study snapshot into redistribution.

AN ALLOW-LIST, NOT A GUESS
--------------------------
Only file types the downloader actually produces are uploaded: Markdown, JSON, and
images. An unfamiliar file type is skipped by default rather than shipped, so a stray
download, a cache file, or a credential someone saved into the folder never leaves
your machine by accident. Run --dry-run first and read the list.

USAGE
-----
    uv sync --group azure                                   # once: the Azure SDKs
    uv run python tools/sync_corpus.py --self-test          # prove the classifier works
    uv run python tools/sync_corpus.py --dry-run            # classify everything, upload nothing
    uv run python tools/sync_corpus.py                      # archive the snapshot
    uv run python tools/sync_corpus.py --artifacts-only     # just the chunk JSONL and stats

EXIT CODES
----------
    0  snapshot archived (or dry run / self-test passed)
    1  a precondition failed
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import pathlib
import sys

from _common import (
    CHUNK_STATS_FILE,
    CHUNKS_FILE,
    CORPUS_DIR,
    INDEX_DIR,
    explain_403,
    fail,
    get_credential,
    info,
    load_env,
    ok,
    require,
    resolve_path,
    step,
    warn,
)

# Only these extensions are ever uploaded. They are exactly what the downloader writes:
# one Markdown file per module, a combined _full.md per learning path, and the figures
# each unit references. Anything else is skipped, which is the safe default.
ALLOW_EXTENSIONS = frozenset(
    {".md", ".markdown", ".json", ".jsonl", ".png", ".jpg", ".jpeg", ".svg", ".gif", ".webp"}
)

# Never archive scratch, caches, environments, or version-control internals.
SKIP_DIR_NAMES = frozenset({".git", "__pycache__", ".venv", "node_modules", ".pytest_cache", "index", ".cache"})

# Never archive anything that looks like configuration or a secret, even if someone
# saved it with an allowed extension. Checked against the bare file name.
SKIP_FILE_NAMES = frozenset({".env", "secrets.json", "local.settings.json"})


def classify(path: pathlib.Path, root: pathlib.Path) -> tuple[str, str]:
    """Classify one candidate file as "allow" or "skip".

    Returns (verdict, reason). Both the bare filename and the relative path are
    considered, because a file can be excluded by its own name or by a directory above
    it (".venv/lib/site-packages/.../data.json").
    """
    try:
        rel = path.relative_to(root)
    except ValueError:
        rel = path

    if any(part in SKIP_DIR_NAMES for part in rel.parts):
        return "skip", "scratch, cache, or version-control directory"

    if path.name.lower() in SKIP_FILE_NAMES:
        return "skip", "configuration or secrets file"

    if path.suffix.lower() not in ALLOW_EXTENSIONS:
        return "skip", f"extension '{path.suffix}' is not on the allow-list"

    return "allow", "corpus content"


def sha256_of(path: pathlib.Path) -> str:
    """Content hash, streamed so a large figure does not need to fit in memory."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def self_test() -> int:
    """Exercise the classifier against the file shapes the downloader produces."""
    print("sync_corpus.py self-test\n")
    root = pathlib.Path("/corpus")
    ok_all = True

    must_allow = [
        "Microsoft Cybersecurity Architect/01-Design solutions/01-Introduction to Zero Trust.md",
        "Microsoft Cybersecurity Architect/01-Design solutions/_full.md",
        "Microsoft Cybersecurity Architect/01-Design solutions/images/zero-trust-principles.png",
        "Microsoft Cybersecurity Architect/02-Design security operations/images/diagram.svg",
    ]
    must_skip = [
        "Microsoft Cybersecurity Architect/notes.docx",
        "Microsoft Cybersecurity Architect/archive.7z",
        "mystery.bin",
        ".env",
        "secrets.json",
        ".venv/lib/site-packages/pkg/data.json",
        ".git/config",
        "__pycache__/x.json",
    ]

    print("  [test] downloader output is ALLOWED")
    for rel in must_allow:
        verdict, reason = classify(root / rel, root)
        good = verdict == "allow"
        ok_all &= good
        print(f"         {'pass' if good else 'FAIL'}  {verdict:<6} {rel[:64]}")
        if not good:
            print(f"                 expected allow, got {verdict} ({reason})")

    print("\n  [test] everything else is SKIPPED, never uploaded")
    for rel in must_skip:
        verdict, reason = classify(root / rel, root)
        good = verdict == "skip"
        ok_all &= good
        print(f"         {'pass' if good else 'FAIL'}  {verdict:<6} {rel[:64]}")
        if not good:
            print(f"                 expected skip, got {verdict} ({reason})")

    print("\n  self-test:", "ALL PASS" if ok_all else "FAILURES PRESENT")
    return 0 if ok_all else 1


def scan(root: pathlib.Path) -> tuple[list[pathlib.Path], int]:
    """Walk the corpus and partition it into allowed files and a skipped count."""
    allowed: list[pathlib.Path] = []
    skipped = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        verdict, _ = classify(path, root)
        if verdict == "allow":
            allowed.append(path)
        else:
            skipped += 1
    return allowed, skipped


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--corpus", default=None,
                    help="Corpus directory (default: SC100_CORPUS_DIR from .env, else corpus/).")
    ap.add_argument("--dry-run", action="store_true",
                    help="Classify everything and report. No uploads, no cost.")
    ap.add_argument("--artifacts-only", action="store_true",
                    help="Upload only the chunk JSONL and stats report, not the source corpus.")
    ap.add_argument("--self-test", action="store_true",
                    help="Exercise the classifier against the downloader's file shapes.")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    # required=False: --dry-run must work BEFORE any deployment exists. Checking what
    # would be uploaded is precisely the thing you want to do before spending money.
    # The storage settings are demanded later, at the point of actual upload.
    cfg = load_env(required=False)

    step("Scanning")
    to_upload: list[tuple[pathlib.Path, str, str]] = []  # (path, container, blob_name)

    corpus_root: pathlib.Path | None = None
    if not args.artifacts_only:
        corpus_root = resolve_path(args.corpus, cfg.get("SC100_CORPUS_DIR"), CORPUS_DIR)
        if not corpus_root.is_dir():
            fail(f"Corpus directory not found: {corpus_root}",
                 "Run scripts/Get-SC100Corpus.ps1 first, or pass --corpus.")

        info(f"corpus {corpus_root}")
        allowed, skipped = scan(corpus_root)
        ok(f"{len(allowed)} files to archive, {skipped} skipped")

        src_container = cfg.get("AZURE_CORPUS_SOURCE_CONTAINER", "corpus-source")
        for path in allowed:
            to_upload.append((path, src_container, path.relative_to(corpus_root).as_posix()))

    # Derived artifacts, kept beside the source so a snapshot and the chunks produced
    # from it can be recovered as a matched pair.
    art_container = cfg.get("AZURE_CORPUS_ARTIFACTS_CONTAINER", "corpus-artifacts")
    for artifact in (CHUNKS_FILE, CHUNK_STATS_FILE):
        if artifact.exists():
            to_upload.append((artifact, art_container, artifact.name))
        else:
            warn(f"{artifact.name} not found. Run tools/chunk_learn.py to produce it.")

    if not to_upload:
        fail("Nothing to upload.")

    total_bytes = sum(p.stat().st_size for p, _, _ in to_upload)
    info(f"{len(to_upload)} blobs, {total_bytes / 1_048_576:.1f} MB total")

    # -- Manifest: the actual provenance payload --------------------------
    step("Building the snapshot manifest")
    snapshot_id = _dt.datetime.now(_dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    manifest = {
        "snapshot_id": snapshot_id,
        "created_utc": _dt.datetime.now(_dt.UTC).isoformat(),
        "note": "Microsoft Learn SC-100 training content, downloaded for personal study. "
                "Keep this container private.",
        "file_count": len(to_upload),
        "total_bytes": total_bytes,
        "files": [],
    }
    for path, container, blob in to_upload:
        manifest["files"].append({
            "blob": blob,
            "container": container,
            "bytes": path.stat().st_size,
            # The hash is what makes the manifest useful: it lets a future run prove
            # whether a unit changed without downloading anything.
            "sha256": sha256_of(path),
        })
    ok(f"snapshot {snapshot_id}: {len(manifest['files'])} files hashed")

    if args.dry_run:
        step("Dry run")
        by_container: dict[str, int] = {}
        for _, container, _ in to_upload:
            by_container[container] = by_container.get(container, 0) + 1
        for container, n in sorted(by_container.items()):
            info(f"{n:>5} blobs -> {container}")
        info("")
        info("first 10 blob names:")
        for _, container, blob in to_upload[:10]:
            info(f"  {container}/{blob}")
        ok("Dry run complete. Nothing uploaded, nothing charged.")
        return 0

    # -- Upload -----------------------------------------------------------
    account, = require(cfg, "AZURE_STORAGE_ACCOUNT")
    blob_endpoint = cfg.get("AZURE_STORAGE_BLOB_ENDPOINT") or f"https://{account}.blob.core.windows.net"

    try:
        from azure.storage.blob import BlobServiceClient
    except ImportError:
        fail("azure-storage-blob is not installed.", "The Azure path is optional. Run: uv sync --group azure")

    credential = get_credential()
    service = BlobServiceClient(account_url=blob_endpoint, credential=credential)

    step(f"Uploading to {blob_endpoint}")
    uploaded = 0
    for path, container, blob_name in to_upload:
        try:
            client = service.get_blob_client(container=container, blob=blob_name)
            with path.open("rb") as fh:
                # overwrite=True with versioning enabled on the account keeps the prior
                # version rather than destroying it. That is the whole point.
                client.upload_blob(fh, overwrite=True)
            uploaded += 1
            if uploaded % 25 == 0 or uploaded == len(to_upload):
                info(f"uploaded {uploaded}/{len(to_upload)}")
        except Exception as exc:  # noqa: BLE001
            fail(f"Upload failed for {blob_name}: {exc}", explain_403(exc))

    # The manifest goes up last, so its presence means the snapshot is complete. A
    # manifest written first would describe an upload that might have failed halfway.
    manifest_blob = f"manifests/{snapshot_id}.json"
    service.get_blob_client(container=art_container, blob=manifest_blob).upload_blob(
        json.dumps(manifest, indent=2).encode("utf-8"), overwrite=True
    )
    ok(f"{uploaded} blobs uploaded")
    ok(f"manifest at {art_container}/{manifest_blob}")

    # Keep a local copy too, so provenance survives a teardown of the storage account.
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    local_manifest = INDEX_DIR / f"snapshot-{snapshot_id}.json"
    local_manifest.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    ok(f"local copy at {local_manifest}")

    print(
        f"\nSnapshot {snapshot_id} archived.\n"
        "Blob versioning is on, so re-running after a fresh download preserves this\n"
        "version and turns any change into a diff instead of a memory.\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
