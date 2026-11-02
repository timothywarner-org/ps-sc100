"""
_common.py -- shared paths, console output, configuration, and Azure auth for the toolkit.

WHY A SHARED MODULE
-------------------
The ingest scripts, the optional Azure tools, and mcp/server.py all need the same
things: one definition of where the index lives, the values from .env, an Entra
credential when you take the Azure path, and a consistent way to fail loudly when
something is missing. Copying that into every file is how the copies drift apart, and
a drifted path or auth helper is the kind of bug that only shows up when you need the
tool to work.

EVERY PATH IS RELATIVE TO THE TOOLKIT
-------------------------------------
TOOLKIT_ROOT is computed from this file's own location, so every script works the same
whether you run it from the toolkit folder, from tools/, or from an MCP host that
launches the server from somewhere else entirely. Nothing here assumes a drive letter,
a user name, or a working directory.

NO KEYS ANYWHERE
----------------
The local path needs no credentials at all. The optional Azure path authenticates with
DefaultAzureCredential, which picks up your `az login` session. infra/main.bicep sets
`disableLocalAuth: true` on the search service and the Foundry account, and
`allowSharedKeyAccess: false` on storage, so none of them accepts an API key even if
one were offered. A toolkit that teaches Zero Trust while pasting an admin key into a
config file would teach the opposite of what it says.
"""

from __future__ import annotations

import os
import pathlib
import sys
from typing import NoReturn

# ---------------------------------------------------------------------------
# Paths. Everything resolves from this file, never from the current directory.
# ---------------------------------------------------------------------------

TOOLKIT_ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_FILE = TOOLKIT_ROOT / ".env"
CORPUS_DIR = TOOLKIT_ROOT / "corpus"
CORPUS_ROOT = CORPUS_DIR / "Microsoft Cybersecurity Architect"
INDEX_DIR = TOOLKIT_ROOT / "index"
CHUNKS_FILE = INDEX_DIR / "learn-chunks.jsonl"
CHUNK_STATS_FILE = INDEX_DIR / "learn-chunks.stats.json"
CHROMA_DIR = INDEX_DIR / "learn-chroma"
OBJECTIVES_FILE = INDEX_DIR / "objectives.json"


# ---------------------------------------------------------------------------
# Console output. Word-labelled, never colour-coded.
#
# Roughly one man in twelve has some form of colour vision deficiency, and red/green
# is the most common. A pipeline whose success and failure states differ only by ANSI
# colour is also unreadable in a CI log, a piped file, or a terminal with a different
# theme. The label carries the meaning; any colour is decoration on top.
# ---------------------------------------------------------------------------

def step(message: str) -> None:
    print(f"\n==> {message}", file=sys.stderr, flush=True)


def ok(message: str) -> None:
    print(f"    [ok] {message}", file=sys.stderr, flush=True)


def info(message: str) -> None:
    print(f"    {message}", file=sys.stderr, flush=True)


def warn(message: str) -> None:
    print(f"    [warning] {message}", file=sys.stderr, flush=True)


def fail(message: str, hint: str | None = None) -> NoReturn:
    print(f"\n[error] {message}", file=sys.stderr)
    if hint:
        print(f"        {hint}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def load_env(required: bool = True) -> dict[str, str]:
    """Load .env and return it as a dict.

    Uses python-dotenv when available and falls back to a small hand parser when it
    is not, so a fresh clone can still report a useful error before dependencies are
    installed rather than dying on an ImportError.

    Args:
        required: When False, a missing .env returns {} instead of exiting. Every
            local-path tool passes False, because the local path needs no .env at all.

    Returns:
        The settings, with process environment variables winning over the file.
    """
    if not ENV_FILE.exists():
        if not required:
            return {}
        fail(
            f"No .env found at {ENV_FILE}",
            "Run infra/deploy.ps1 (or infra/deploy.sh) first. It writes .env from the "
            "deployment outputs, so no endpoint is ever copied by hand.",
        )

    try:
        from dotenv import dotenv_values  # type: ignore

        values = {k: v for k, v in dotenv_values(ENV_FILE).items() if v is not None}
    except ImportError:
        values = {}
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            values[key.strip()] = val.strip()

    # Environment variables win over the file. That is what lets CI inject settings
    # without rewriting .env, and what lets you flip a setting for a single run.
    for key in list(values):
        if os.environ.get(key):
            values[key] = os.environ[key]

    return values


def resolve_path(cli_value: str | None, env_value: str | None, default: pathlib.Path) -> pathlib.Path:
    """Resolve a path from a CLI argument, a .env value, or a built-in default, in that order.

    The two configurable sources use DIFFERENT relative-path bases, and mixing them up
    is a classic bug:

      * A CLI argument is relative to your CURRENT WORKING DIRECTORY, because that is
        what every command-line tool does and what tab completion produces.
      * A .env value is relative to the TOOLKIT ROOT, because .env lives there and its
        values (`./index/learn-chroma`) are written from the root's point of view.

    Args:
        cli_value: The command-line value, or None.
        env_value: The .env or environment value, or None.
        default: The built-in default, already absolute.

    Returns:
        An absolute path.
    """
    if cli_value:
        return pathlib.Path(cli_value).expanduser().resolve()
    if env_value:
        p = pathlib.Path(env_value).expanduser()
        return p.resolve() if p.is_absolute() else (TOOLKIT_ROOT / p).resolve()
    return pathlib.Path(default).resolve()


def require(cfg: dict[str, str], *keys: str) -> tuple[str, ...]:
    """Fetch required config keys, failing with the full list of what is missing.

    Reporting every missing key at once matters more than it sounds: failing on the
    first one turns a single fix into four round trips through a five-minute deploy.
    """
    missing = [k for k in keys if not cfg.get(k)]
    if missing:
        fail(
            f"Missing required settings in .env: {', '.join(missing)}",
            "Re-run infra/deploy.ps1 to regenerate .env from the deployment outputs.",
        )
    return tuple(cfg[k] for k in keys)


# ---------------------------------------------------------------------------
# Authentication (optional Azure path only)
# ---------------------------------------------------------------------------

def get_credential():
    """Return a DefaultAzureCredential, with a readable error if it cannot be built.

    DefaultAzureCredential walks an ordered chain: environment variables, managed
    identity, Azure CLI, and so on. On a developer machine the Azure CLI link is the
    one that fires, which is why `az login` is the only setup step.
    """
    try:
        from azure.identity import DefaultAzureCredential
    except ImportError:
        fail(
            "azure-identity is not installed.",
            "The Azure path is an optional dependency group. Run: uv sync --group azure",
        )

    try:
        return DefaultAzureCredential(exclude_interactive_browser_credential=False)
    except Exception as exc:  # noqa: BLE001 - surface the real reason, whatever it is
        fail(f"Could not construct an Azure credential: {exc}", "Try: az login")


def explain_403(exc: Exception) -> str:
    """Turn an authorization failure into the sentence that actually helps.

    A raw 403 from Azure AI Search says almost nothing about which of the possible
    causes applies. On a fresh deployment it is nearly always Entra role-assignment
    replication lag, and the right move is to wait rather than to start debugging the
    template.
    """
    text = str(exc)
    if "403" in text or "Forbidden" in text or "AuthorizationFailed" in text:
        return (
            "Authorization failed. On a freshly deployed environment this is almost "
            "always Entra role-assignment replication lag: wait 60 seconds and retry. "
            "If it persists, confirm the deployment granted your principal both "
            "'Search Service Contributor' and 'Search Index Data Contributor':\n"
            "        az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all -o table"
        )
    return text
