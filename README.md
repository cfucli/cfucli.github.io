# cfucli.github.io

The site at [cfucli.github.io](https://cfucli.github.io), and the remote configuration the tool reads at runtime.

The tool itself lives at [cfucli/cfucli](https://github.com/cfucli/cfucli).

## Why the config lives here and not in the app repo

`config/relay.json` says where the shared rendezvous is. It is deliberately kept outside the application repository so it can be changed without cutting a release — the whole point of the indirection is that every installed copy can be re-pointed at a new endpoint without anyone downloading anything.

## The schema

```json
{
  "schema_version": 1,
  "status": "not-deployed" | "live" | "full",
  "relay_url": "https://... or null",
  "fallback_url": "https://... or null",
  "message": "text shown to the user, or null"
}
```

`schema_version` is checked first. A client that does not understand the version it finds must ignore the whole file and use its compiled-in defaults, rather than guessing at fields it does not know.

`status` is what the client acts on. `not-deployed` means there is no shared rendezvous yet and the client should use whatever the user configured locally. `live` means `relay_url` is usable. `full` means the shared pool is at capacity today — show `message` and fall back to the user's own credentials.

`message` lets a notice reach every user without a release. Keep it short and keep it true.

## Rules for anything that reads this file

These are requirements on the client, not suggestions.

**Never make this file a hard dependency.** If the fetch fails, if GitHub is unreachable, if the JSON does not parse, or if the version is unrecognised, the tool carries on with the defaults compiled into the binary. A configuration server that can take the product down when it is unavailable is worse than no configuration server.

**Cache it locally with a short TTL.** Do not fetch on every invocation. The command line is invoked once per command an agent runs, and hitting GitHub each time is both slow and rude.

**Prefer a pinned commit SHA over the mutable branch URL.** This file is effectively an auto-update channel for where user traffic gets routed. Fetched from `.../main/...` it is a live single point of trust: anyone who gained write access here could silently repoint every installed copy. Pinning to an immutable SHA and moving the pin deliberately costs the ability to hot-fix instantly and buys the guarantee that a repository compromise cannot redirect traffic on its own.

## The site

`index.html` is one self-contained file. No build step, no framework, no external stylesheet or font — which is why there is nothing here to install and nothing to go stale. Edit it and push.
