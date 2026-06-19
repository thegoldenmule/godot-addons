# Publishing & checking drift

**Status:** active

## Body
Publishing is a manual paste of one JSON document into your backend console; this tool assembles that document from the committed blobs so a paste can never drop a key or corrupt a value.

## The manifest

The manifest lists the document's keys — one entry per feature — each naming a content `file`, the `version_field` inside that file, and a `label`. The published document is `{ <key>: <blob>, … }` in manifest order.

```json
{
  "app_config_version": "v1",
  "entries": [
    { "key": "story_catalog", "file": "story_catalog.json", "version_field": "catalog_version", "label": "Story catalog" },
    { "key": "daily_login",   "file": "daily_login.json",   "version_field": "version",         "label": "Daily Login" }
  ]
}
```

## Aggregate & copy

- The table shows each key with its file, version, and present / missing status.
- The preview shows the exact bytes that will be published (the verbatim raw splice).
- **Copy publish payload** validates first; if anything is wrong (missing or duplicate key, missing blob, missing version field, unset `content_dir`) it refuses and lists the problems.
- On success, paste the clipboard into your backend console under the manifest's document version.

Values are spliced verbatim from disk, so integers, 64-bit IDs, and formatting survive byte-for-byte — the payload is never re-serialized through Godot's JSON (which would coerce every integer to a float).

## Check drift

When a `sync` command is configured, **Check sync** runs it and reports per-key status:

- `match` — the live value equals the committed blob.
- `drift` — live and committed differ (the row shows both versions); re-copy and paste to republish.
- `absent` — the key is missing from the live document.

The compare itself lives in your own comparator (the tool only runs it and reads its `results` JSON), so the editor and your CLI verifier can never disagree. With no `sync` configured, the button is hidden.

## References
_None._

## Child pages
_None._
