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

## What it does

1. Writes a minimal **fake-MDM enrollment stub** so Edge treats the (unmanaged,
   residential) PC as managed — this is what makes the search-provider policy
   actually apply.
2. Sets the **DefaultSearchProvider\*** policy to Google or DuckDuckGo. This is
   the real fix: a policy is enforced silently and can't be reverted by clicking
   Microsoft's popup.
3. Sets the nag-suppression policies (`DefaultBrowserSettingsCampaignEnabled`,
   `ShowRecommendationsEnabled`, `HideFirstRunExperience`,
   `SpotlightExperiencesAndRecommendationsEnabled`).
4. Verifies and logs to `C:\ProgramData\NerdyNeighbor\edge-search.log`.

**Always confirm at `edge://policy`** that the `DefaultSearchProvider*` rows show
**Applied** (not Ignored) after a full Edge restart.

## Caveats

- Edge shows "managed by your organization" (cosmetic) and the search engine
  becomes **locked** (user can't change it) — that's the point.
- The MDM stub can turn **off** Defender Tamper Protection; re-enable in Windows
  Security if needed.
- Windows **Home**: usually works, but verify at `edge://policy` per machine.

## Why not just "debloat" Edge?

Tools like ChrisTitusTech/winutil set `DefaultBrowserSettingsCampaignEnabled=0`
but never touch `DefaultSearchProvider*` and add no MDM stub — so they clean up
nags but don't *enforce* the engine, and the reconfirmation popup survives.
Enforcing the provider by policy is the piece that actually makes it stick.
