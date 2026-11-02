# ADR-003: Blob archive for your corpus snapshots

**Status:** Accepted (optional Azure path)
**Decides:** whether downloaded corpus snapshots live in Azure Storage, and under what constraints
**Extends:** ADR-002 (chunking, and push rather than indexer)

---

## Decision

**On the optional Azure path, archive each corpus download in a private Azure Blob
Storage account with versioning on. Never use it as an ingestion source.**

| Container | Contents | Read by anything in Azure? |
|---|---|---|
| `corpus-source` | Your downloaded Learn training: Markdown units and figures | **No** |
| `corpus-artifacts` | Derived chunk JSONL, stats reports, snapshot manifests | **No** |

The archive is optional. The local path never needs it, and you can deploy the search
service without ever running `tools/sync_corpus.py`.

---

## Why an archive at all

Microsoft Learn is a moving target. The April 2026 refresh inserted **nine AI units**
across all four SC-100 learning paths without renumbering anything around them: new units
arrived at letter-suffixed slugs (`3a-`, `2a-`, `6a-`) wedged between existing numbered
ones. That will happen again.

When it does, one question matters:

> Did my answers change because Microsoft changed the training, or because I changed the
> chunker?

Without an archive you answer that from memory. With blob versioning it is a diff. Every
upload preserves the prior version, and the snapshot manifest carries a SHA-256 per file,
so "did this unit change?" is answerable without downloading anything. The two causes have
opposite remedies, and they are indistinguishable without a snapshot.

---

## Archive, not ingestion source

Adding a storage account to a retrieval pipeline usually means one thing: an indexer is
coming. Blob, then data source, then skillset, then index projections is the canonical
Azure AI Search shape, and it is what a reviewer will assume this container is for.

It is not, and **ADR-002 is not being reopened**.

There is no indexer, no data source, and no skillset in `main.bicep`. Nothing in Azure
has read access to these containers; the only role assignment is yours, for upload.
`chunk_learn.py` still chunks locally and `ingest_azure.py` still pushes, for the reasons
ADR-002 gives.

**Blob is where the inputs are kept. It is not where they are read from.**

---

## Keep it private

The corpus is Microsoft's copyrighted training content, downloaded for your own study. A
private container in your own subscription keeps it that way; a public one would turn a
study snapshot into redistribution. Three settings enforce private, and you should leave
all three alone:

- `allowBlobPublicAccess: false` on the account, so no container can ever be anonymous.
- `publicAccess: 'None'` on both containers.
- `allowSharedKeyAccess: false`, so there is no account key to leak or share.

`tools/sync_corpus.py` adds a fourth guard on your machine: it uploads only the file types
the downloader produces (Markdown, JSON, and images) and skips everything else, including
`.env`, environment folders, and caches. Run `--dry-run` first and read the list.

---

## Storage configuration, and the reasoning behind each setting

| Setting | Value | Why |
|---|---|---|
| SKU | `Standard_LRS` | The authoritative copy is the downloader plus Microsoft Learn. Paying for geo-redundancy to protect a regenerable snapshot is spending on the wrong risk. |
| `isVersioningEnabled` | `true` | The entire point. Re-upload preserves the prior version. |
| `deleteRetentionPolicy` | 30 days | An archive that one bad command can destroy is not an archive. |
| `allowBlobPublicAccess` | `false` | A "public" container is how a private snapshot quietly becomes a public one. |
| `allowSharedKeyAccess` | `false` | Keyless, matching the search service and Foundry account. No account key to leak, rotate, or commit. |
| `minimumTlsVersion` | `TLS1_2` | Baseline. |

---

## Consequences

**Good.** Corpus drift becomes measurable instead of remembered. An index can be tied to
an exact snapshot ID and a per-file hash. And the storage account is a compact study
example in its own right: a keyless, versioned, private archive that no cloud service is
allowed to read.

**Costs.** One more resource in the deploy and teardown cycle, and an upload step whose
runtime scales with the corpus (the figures dominate). Standard LRS storage for a corpus
this size is small next to the search service, but it is not zero, and teardown removes
it along with everything else in the resource group.

**Revisit if** upload time becomes an obstacle to the deploy-study-teardown rhythm (the
fix is incremental upload keyed on the manifest hashes, not abandoning the archive), or a
genuine need for indexer-driven ingestion arises, in which case it needs an ADR that
argues against ADR-002 directly.
