# SC-100 study toolkit

**Build your own SC-100 study knowledge base from Microsoft Learn's free training, then
search it by exam objective, with a citation on every passage, from the command line or
from any MCP host.**

You download Microsoft's SC-100 training to your own machine, cut it into searchable
passages, and get back Microsoft's own words with a link to the Learn page they came from.
The local path costs nothing and needs no Azure subscription. An optional Azure AI Search
path is included for when you want hybrid retrieval and are willing to pay for it by the
hour.

What you can do with it:

- **Verify a claim** before you memorize it: "does Microsoft Learn actually say Microsoft
  Entra Private Access replaces VPN?" Search, read the passage, open the `source_url`.
- **Find your weak objectives:** the coverage sweep tells you which of the 81 exam
  objectives the free training covers thinly, so you know where to spend time in the
  product documentation.
- **Catch retired product names** that older books, courses, and AI models still use
  (Microsoft Entra Permissions Management is the classic trap).
- **Give your AI assistant grounded answers** through the MCP server, with a citation it
  can show you.

---

## What you'll need

| For | You need |
|---|---|
| The five-minute path | Python 3.10 or later, git, and PowerShell (7.x on any OS, or Windows PowerShell 5.1) |
| The full path | All of the above, plus [uv](https://docs.astral.sh/uv/) |
| The optional Azure path | All of the above, plus an Azure subscription, the Azure CLI, and Owner or User Access Administrator on the target resource group |

Every command below runs from the **toolkit folder** of your clone. On macOS and Linux,
use `python3` wherever you see `python`.

```powershell
cd <path-to-your-clone>/toolkit
```

---

## The five-minute path: keyword search, nothing to install

**Two commands build the corpus and one searches it.** The chunker and the keyword search
use only Python's standard library, so there is no virtual environment and no package
install.

**1. Download the training** (about a minute; it lands in `corpus/`, which git ignores):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/Get-SC100Corpus.ps1
```

On Windows PowerShell 5.1, use `powershell` in place of `pwsh`.

**2. Cut it into citable passages** (writes `index/learn-chunks.jsonl`):

```powershell
python tools/chunk_learn.py
```

You should see `CHUNKS PRODUCED 1071` (the number moves when Microsoft revises the
training) and five validation gates reporting `PASS`.

**3. Search it.** Phrase mode is exact, which makes it the right tool for verifying a
product name. BM25 mode ranks by keyword relevance, which suits open questions.

```powershell
python tools/search_keyword.py phrase "Microsoft Entra Private Access"
python tools/search_keyword.py bm25 "immutable backup ransomware" --top 5
python tools/search_keyword.py bm25 "key vault" --domain 3
python tools/search_keyword.py stats
```

Every hit prints its module, unit, section, and `source_url`. `--domain` takes the **exam**
domain (1 to 4), not the Learn learning-path number.

---

## The full path: local vector store and MCP server

**This adds semantic search, objective coverage grades, and an MCP server your AI
assistant can call.** Still local, still free.

**1. Install the locked environment** (creates `.venv`; uv fetches Python 3.11 if you
don't have it):

```powershell
uv sync
```

**2. Build the objective table** from the skills-measured page in this repository
(`../docs/SC-100-Skills-Measured.md`). It must report 4 domains, 14 groups, and 81
statements, or it refuses to write:

```powershell
uv run python tools/extract_objectives.py
```

**3. Embed the passages into a local Chroma collection.** The first run downloads
Chroma's small embedding model (about 80 MB); after that everything works offline:

```powershell
uv run python tools/ingest_local.py
```

It finishes by proving citability: the count matches, every passage has a `source_url`,
and a live query returns text.

**4. Check the whole toolkit**, offline, in one command:

```powershell
uv run python tests/run_all.py
uv run python mcp/server.py --self-test
```

Both end in `ALL PASS` or `All 6 suites passed`. The server self-test also prints the MCP
protocol revisions the installed SDK supports. `run_all.py` is a plain script runner, so
run it as shown rather than through pytest.

---

## Register the server with your MCP host

The server speaks MCP over stdio. Each host launches it with `uv`, which resolves the
locked environment on every start, so the server always runs against the exact versions it
was tested with. Replace `<path-to-your-clone>` with the absolute path to your clone, and
use forward slashes even on Windows (JSON treats a single backslash as an escape
character).

If a host reports that it can't find `uv`, put the full path to the `uv` executable in
`command`. Find it with `where.exe uv` on Windows or `which uv` on macOS and Linux.

### Claude Desktop

Open **Settings > Developer > Edit Config**, or edit the file directly:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

Add this entry (also in [mcp/claude_desktop_config.example.json](mcp/claude_desktop_config.example.json)),
then quit Claude Desktop completely and start it again:

```json
{
  "mcpServers": {
    "sc100-knowledge": {
      "command": "uv",
      "args": ["--directory", "<path-to-your-clone>/toolkit", "run", "python", "mcp/server.py"]
    }
  }
}
```

Format and file locations follow the Model Context Protocol guide
[Connect to local MCP servers](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

### Claude Code

One command registers it for every project on your machine (`--scope user`). Everything
after `--` is the command that starts the server:

```powershell
claude mcp add --transport stdio --scope user sc100-knowledge -- uv --directory <path-to-your-clone>/toolkit run python mcp/server.py
claude mcp list
```

`claude mcp list` should show `sc100-knowledge` as connected. Syntax and scopes follow
[Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp).

### VS Code

Open the toolkit folder in VS Code and create `.vscode/mcp.json`. `${workspaceFolder}`
resolves to the folder you opened, so this file needs no editing:

```json
{
  "servers": {
    "sc100-knowledge": {
      "type": "stdio",
      "command": "uv",
      "args": ["--directory", "${workspaceFolder}", "run", "python", "mcp/server.py"]
    }
  }
}
```

If you open the repository root instead of the toolkit folder, change the directory to
`${workspaceFolder}/toolkit`. VS Code asks you to trust the server before it starts it.
Format follows the [VS Code MCP configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration),
which also documents a newer portable `.mcp.json` format with a top-level `mcpServers`
object.

### Try it

Ask your assistant something that forces a tool call and a citation:

- "Use sc100-knowledge to explain what Microsoft Entra Private Access replaces. Quote the
  passage and give me the source_url."
- "Run a coverage sweep over the Domain 3 objectives and tell me which ones Learn covers
  thinly."
- "Check product currency for cloud infrastructure entitlement management."

---

## The optional Azure AI Search path

**Use this only if you want BM25, vector search, and a semantic ranker fused in one
query, and tear it down the same day.**

> **Cost warning.** Azure AI Search Basic bills by the hour whether you query it or not:
> $0.101/hour in East US 2 when this was written, which is about $74/month if you forget
> to delete it. The deploy script prints the live retail rate for your region and asks
> before it creates anything. Run the teardown command when you finish.

Every service it deploys refuses API keys. You authenticate with Microsoft Entra ID
through your `az login` session, and the deploy script writes `.env` from the deployment
outputs so you never copy an endpoint by hand.

```powershell
az login
uv sync --group azure
./infra/deploy.ps1                        # bash: ./infra/deploy.sh
uv run python tools/create_index.py
uv run python tools/ingest_azure.py
```

Then set `SC100_BACKEND=azure` in `.env` and restart your MCP host. The tools behave the
same; retrieval comes from Azure AI Search instead of local Chroma.

**Tear it down when you finish.** This deletes the resource group and everything in it,
and leaves every local file alone:

```powershell
./infra/teardown.ps1                      # bash: ./infra/teardown.sh
```

Optionally, `uv run python tools/sync_corpus.py --dry-run` previews a snapshot of your
corpus into private, versioned blob storage, so you can later tell whether Microsoft
changed the training ([ADR-003](docs/ADR-003-source-archive.md)).

---

## How it stays honest

- **Every passage carries a `source_url`.** The chunker refuses to emit a chunk without
  one, the ingest refuses to index one, and the server's self-test fails if retrieval ever
  stops returning text. Open the link before you rely on a passage.
- **Quotes are Microsoft's words.** Each chunk is embedded with a short context header
  (learning path, domain, module, unit), but the header is split off before a passage is
  returned.
- **Dense retrieval blurs near-identical product names.** Microsoft Entra Internet Access
  and Microsoft Entra Private Access sit almost on top of each other in vector space. Ask
  for the exact product by name, read the `source_url` before quoting, and use
  `search_keyword.py phrase` when you need to pin a name exactly.
- **The corpus is a dated snapshot of training modules.** It isn't live product
  documentation, so a claim missing from it may still be true. `sc100_check_currency`
  flags retired names and preview language, and the server tells your assistant never to
  present a preview feature as generally available.
- **Coverage grades are calibrated, not counted.** A vector search always returns
  something, so the grade counts only passages above a measured relevance floor. The
  calibration is documented in `mcp/server.py`.
- **Exam domains are exam domains.** Learn path 03 covers exam Domain 4 and Learn path 04
  covers exam Domain 3. The chunker corrects for that with a tested lookup table.

---

## Settings

The local path needs no `.env`; every setting has a working default and every path
resolves relative to the toolkit folder. Copy `.env.example` to `.env` only to change
something:

| Setting | Default | What it does |
|---|---|---|
| `SC100_BACKEND` | `local` | `local` reads Chroma; `azure` reads Azure AI Search |
| `SC100_CHROMA_PATH` | `./index/learn-chroma` | Where the local vector store lives |
| `SC100_CHUNKS` | `./index/learn-chunks.jsonl` | The chunk file the ingest reads |
| `SC100_CORPUS_DIR` | `./corpus` | The corpus the snapshot archive reads |
| `AZURE_*` | written by `infra/deploy.ps1` | Endpoints for the optional Azure path |

---

## Licensing: the corpus stays on your machine

The SC-100 training content is Microsoft's copyrighted material. This toolkit downloads it
to **your** machine for **your** personal study, and this repository never redistributes
it. The toolkit's `.gitignore` blocks `corpus/` (except its README), `index/`, `.cache/`,
`.venv/`, and `.env`, so nothing downloaded or generated from the corpus can be committed
by accident.

If you take the Azure path, your passages live in a search service and, optionally, a
private storage container in **your own** subscription. Keep both private. Don't publish
the corpus, your index, or a public container holding either.

---

## Learn more

- [docs/PIPELINE.md](docs/PIPELINE.md): how each stage works, plus the full file map
- [docs/ADR-001-vector-store.md](docs/ADR-001-vector-store.md): why local Chroma is the default
- [docs/ADR-002-chunking-strategy.md](docs/ADR-002-chunking-strategy.md): why section-level chunks, with the measurements
- [docs/ADR-003-source-archive.md](docs/ADR-003-source-archive.md): the optional snapshot archive
- [SC-100 study guide](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/sc-100) and [course SC-100T00](https://learn.microsoft.com/en-us/training/courses/sc-100t00) on Microsoft Learn
