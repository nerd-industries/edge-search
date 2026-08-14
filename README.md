# edge-search

Lock Microsoft Edge's default search engine to **Google** or **DuckDuckGo** on a
Windows PC, and permanently stop Microsoft's "switch back to Bing / use
recommended settings" popup — the thing that keeps flipping customers back.

Served via Cloudflare Pages at **https://edge.nerdyneighbor.net** so the latest
committed version always runs.

## Run it (elevated Windows PowerShell)

Interactive — it asks Google / DuckDuckGo / Revert:

```powershell
irm edge.nerdyneighbor.net | iex
```

Non-interactive (RMM / SuperOps), pick ahead of time:

```powershell
$env:NN_SEARCH = 'google'      # or 'duckduckgo'
irm edge.nerdyneighbor.net | iex
```

Undo everything (unlock Edge, remove policy + MDM stub):

```powershell
$env:NN_SEARCH = 'revert'
irm edge.nerdyneighbor.net | iex
```

## What it does (edition-aware)

Always, on every edition — writes the **nag-suppression policies**
(`DefaultBrowserSettingsCampaignEnabled`, `ShowRecommendationsEnabled`,
`HideFirstRunExperience`, `SpotlightExperiencesAndRecommendationsEnabled`).
These need no management and kill the "switch to Bing / recommended settings"
popup — the thing that was reverting customers.

Then it branches on the Windows edition:

- **Pro / Education / Enterprise:** adds a minimal **fake-MDM enrollment stub**
  so the `DefaultSearchProvider*` policy applies, then **locks** the engine to
  your choice. The user can no longer change it.
- **Windows Home:** Microsoft **blocks** `DefaultSearchProvider*` on Home and the
  stub can't fake it — so the script does **not** write the stub (it's harmful
  there) and does **not** write the blocked policy. It applies only the nag
  suppression; with the popup gone, you set the engine once in Edge settings and
  it stays.

It also fully restarts Edge (all `msedge.exe`, not just the window) so the
policies take effect, and logs to `C:\ProgramData\NerdyNeighbor\edge-search.log`.

## Verify

- **Pro/Edu/Ent:** `edge://policy` → `DefaultSearchProvider*` rows say **OK**
  (not "Error / This policy is blocked"). If blocked, reboot once and re-check.
- **Home:** those rows should be **absent**; set the engine at
  `edge://settings/searchEngines` and confirm no Bing popup on relaunch.

## Caveats

- On Pro/Edu/Ent, Edge shows "managed by your organization" (cosmetic) and the
  engine becomes **locked** (user can't change it) — that's the point.
- The MDM stub can turn **off** Defender Tamper Protection; re-enable in Windows
  Security if needed. (Home path removes the stub and warns about this.)
- Windows **Home cannot be hard-locked** — popup suppression + manual set is the
  supported result there.

## Why not just "debloat" Edge?

Tools like ChrisTitusTech/winutil set `DefaultBrowserSettingsCampaignEnabled=0`
but never touch `DefaultSearchProvider*` and add no MDM stub — so they clean up
nags but don't *enforce* the engine, and the reconfirmation popup survives.
Enforcing the provider by policy is the piece that actually makes it stick.
