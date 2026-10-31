# stablecoin-defi-yield

## What this project is

A **native macOS `.app`** — double-clickable, no web browser and no terminal needed
to open it — that answers one question: *where can I park my stablecoins to earn yield?*

The original request, verbatim:

> build a macos application (no need of web browser and terminal to open the app) .app
> which shows where i could park my stablecoin and get yield (in APY) - with link as to
> where i could deposit my stablecoin for the aforementioned yield. the yield figure must
> be verified by software/code by going to the defi app website itself i.e. crawling
> before showing it to the user. rank from highest yield to lowest yield.

### Hard requirements

1. Ships as a `.app` bundle. Launching it must not require a browser or a terminal.
2. Lists stablecoin yield opportunities **ranked highest APY → lowest APY**.
3. Shows the **APY** for each opportunity.
4. Shows a **deposit link** — the actual place you go to put the money in.
5. The APY must be **verified by code crawling the DeFi app's website** before it is
   shown. A number that was not confirmed at display time must not be presented as fact.

Requirement 5 is the one that makes this non-trivial and the one the user cares most
about. See "Open decision" below — it is not yet settled.

## Working style the user has asked for

- **Prefer Moli for anything web-facing.** The user's words: "use moli browser to gather
  info from the internet. it's more efficient. bash is wasteful." Use `moli fetch` /
  `moli search` for web data rather than `curl`-and-grep pipelines. Reach for bash for
  local file work, builds, and Swift compilation.
- Keep the "verified" claim honest. If a figure could not be crawled at display time,
  say so in the UI rather than showing a stale number as if it were live.

## Environment (verified 2026-09-26)

| Thing | Value |
|---|---|
| Moli | `1.1.10` at `~/.local/bin/moli` |
| Swift | `6.4` (swift-driver 1.168.6), target `arm64-apple-macosx27.0.0` |
| Xcode | `/Library/Developer/CommandLineTools` (CommandLineTools only — **no full Xcode**) |
| macOS | `27.0` (build 26A428) |

Because only CommandLineTools is installed, build the app with `swiftc` /
`swift build` directly and assemble the `.app` bundle by hand. Do **not** assume
`xcodebuild`, an `.xcodeproj`, or SwiftUI previews are available.

**Verified 2026-09-26:** `SwiftUI.framework`, `AppKit.framework`, `WebKit.framework`,
`Foundation.framework`, and `Combine.framework` are all present in
`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, and a test program importing
SwiftUI + AppKit **compiles and links** with the CLT `swiftc`. So a native SwiftUI app
is viable without full Xcode. WebKit is available too, which means deposit links can
open in an embedded `WKWebView` rather than shelling out to an external browser —
directly satisfying the "no need of web browser" requirement.

## Crawl verification — PROVEN WORKING 2026-09-26

The (c) cross-check is not theoretical; it was tested end-to-end against a live vault.

**Getting the app to render is the hard part.** Protocol app pages are SPAs:

- A vault URL must be the *real* one. `https://app.beefy.com/vault/convex-mim-3pool`
  is a **404** (the page renders, but shows "We can't find the page"); the correct id
  is `convex-mim`, i.e. `https://app.beefy.com/vault/convex-mim`. The vault `id` field
  from the API is what goes in the path.
- `https://app.beefy.com/vaults` (the list page) renders only ~20 lines and **zero**
  extractable rows — it is virtualized/lazy. Do **not** plan on one bulk list crawl to
  verify many rows at once. Verify **per vault page**.
- Use `--wait networkidle`, not the default, or the SPA body is empty.

**Proven result on `app.beefy.com/vault/convex-mim`:**

| Source | Value |
|---|---|
| Beefy API `totalApy` | `0.3464` → **34.64%** |
| Moli UI crawl of the rendered page | **34.64%** |
| Cross-check | **agree** |

Extraction pattern that worked, in `moli fetch --eval-file <js>` JS: find elements whose
text contains `apy`, walk up ≤3 parents, and take the first container with a `%`. The
stable label→value pairing was `"APY\n34.64%"`. Also seen on the page and usable as
corroboration: `"TOTAL APY\n34.64%"`, `"VAULT APR\n29.65%"`, `"TRADING APR\n0.09%"`.

Two practical notes:

- `--dump semantic_tree_text` output is enormous (thousands of lines of
  `generic [backendNodeId=…]`); never dump it to stdout unfiltered.
- `timeout` is **not** available in this shell (zsh here has no `timeout` binary) — use
  Moli's own `--timeout <MS>` instead.

### Reading raw JSON APIs through Moli

`moli fetch <api> --dump json` does **not** emit the raw body. It emits a wrapper —
`{final_url, status, title, headers, redirect_chain, html}` — and the response body is
in the `html` field, itself wrapped in `<html><head></head><body>…</body></html>`. For a
JSON endpoint the payload is inside those `<body>` tags. Parse it as:

```python
d = json.load(open(p))
payload = json.loads(re.search(r'<body>(.*)</body>', d['html'], re.S).group(1))
```

Feeding `d['html']` straight to `json.loads` fails with `Expecting value: line 1 column 1`
(the leading `<html>` tag), and slicing from the first `[` fails with `Extra data`
(the trailing `</body>`). Both mistakes were made here before the wrapper was understood.

## Data sources (probed live 2026-09-26)

All responses below were fetched and inspected directly; no numbers here were guessed.

| Source | Endpoint | Status | Notes |
|---|---|---|---|
| Beefy | `https://api.beefy.finance/vaults` | **live**, ~5.0 MB, 4042 vaults | has `chain`, `assets`, `platformId`, `status`, `tokenAddress`, `earnContractAddress` |
| Beefy APY | `https://api.beefy.finance/apy/breakdown` | **live**, ~881 KB, 6279 entries | keyed by vault id; `totalApy` is a **fraction** (0.3464 → 34.64%) |
| Morpho | `https://blue-api.morpho.org/graphql` | **live** | `markets(first:, where:{chainId_in:[1]})`. Market has `marketId`, `collateralAsset`, `loanAsset`; `state` has `supplyApy`, `netSupplyApy`, `supplyAssetsUsd`, `utilization`. APYs are fractions. |
| Curve | `https://api.curve.finance/v1/getPools/all/ethereum` | **live**, ~4.8 MB | pool objects expose `gaugeCrvApy`, `usdTotal`, `coins` — **no plain supply APY**; needs composition from gauge + trading fees |
| Yearn | `https://api.yearn.fi/v1/chains/1/vaults/all` | **not reachable** at probe time | host may have moved; re-check before relying on it |
| Sky/DSR | `https://info-sky.blockanaliz.org/api/dsr` | **not reachable** at probe time | re-check before relying on it |

Beefy is the richest single source: filtered to `chain == "ethereum"`, `status ==
"active"`, assets intersecting a stablecoin list, **and single-sided** it yields **16
vaults** with real APYs (measured 2026-09-26). Before the single-sided filter was added
the same query returned 63 — the other 47 were multi-asset LP vaults (23 stakedao, 16
convex, 5 curve, 3 fx). It also carries deposit/withdraw URLs, which maps directly onto
requirement 4.

**Single-sided scope — DECIDED 2026-09-26.** The user's requirement: *only a single
stablecoin must be needed to get the APY shown.* LP vaults quote a blended yield on a
basket (e.g. `pmUSD/frxUSD`), which you cannot capture by depositing one stablecoin, so
they are excluded regardless of headline APY. The filter is on Beefy's `assets` array —
a vault qualifies only when it lists **exactly one** asset and that asset is a
stablecoin. That array is the precise fact: it names the tokens a deposit requires. On
today's Ethereum data it coincides exactly with the single-sided strategy ids
(`single` 14, `single-lp` 1, `lendingNoBorrow` 1); asset count is what the code keys on
because it is the semantic fact and does not depend on Beefy's id vocabulary staying
stable.

Effect on the ranking, and it is large: the unmodified multi-asset list opened on
`stakedao-pmusd-ireet` at **44.50%** in a $14,555 pool. The single-sided list tops out
at **7.95%** (`morpho-v2-ethereum-steakhouse-prime-instant-pyusd`) — a roughly 5.6×
lower headline, and every one of those 16 is a genuine one-token deposit.

The `id` → `app.beefy.com/vault/<id>` path mapping held for every row tested: all 16 in
the 2026-09-26 self-test resolved to a real page with a matching figure. If a path ever
does break, the row surfaces as `UNVERIFIED` with a reason rather than as a wrong number
— the self-test always prints API and site side by side, so that is visible, not silent.

Earlier probe artifacts from a prior session may still exist under `/tmp/probe/`
(`beefy.json`, `beefyvaults.out`, `curve.json`, `csn.out`). They are scratch data and
may be cleaned up by the OS — re-fetch rather than trusting them.

## Verification model — DECIDED 2026-09-26: option (c), cross-checked

The user was asked what "verified by crawling the website" should mean, and chose
**(c): both, cross-checked.** This is settled — implement it, don't re-litigate it.

The rule for every APY shown in the app:

1. **Fetch** the protocol's first-party endpoint to get a candidate APY and a deposit URL.
2. **Crawl** that protocol's own app page with Moli (headless, real DOM) and extract the
   APY the site actually renders.
3. **Compare** the two. Define a tolerance (APYs drift between the two reads and are
   often rounded in the UI):
   - **Agree** (within tolerance) → show the APY as **verified**, and record both values,
     both source URLs, and the crawl timestamp.
   - **Disagree** → **do not** silently show one. Surface it: show the UI-crawled value
     (the site is the ground truth per requirement 5) clearly marked as a *mismatch*,
     with the API value alongside so the discrepancy is visible.
   - **Crawl failed / unextractable** → mark the row **unverified** and say why. Never
     present an uncrawled number as if it had been confirmed.

The UI must make verification state legible per row — verified, mismatched, or
unverified — not just show a bare number. Requirement 5 is the whole point of the app;
if the app can't substantiate a figure, it has to admit that rather than imply trust it
hasn't earned.

## Risk and size disclosure — DECIDED 2026-09-26

Verified is not the same as *safe*, and the app must not let the verification badge
imply otherwise. A number can be perfectly confirmed against the live site and still be
a bad place to put money.

Two disclosures, both driven by data the API already provides:

**1. `risks` flags.** Beefy's `/vaults` carries a per-vault `risks` object. Surfaced in
the UI, never hidden. Live per-flag counts among the **16 single-sided stablecoin
candidates the app actually ranks** (measured 2026-09-26; this table was taken against
the earlier 63-row multi-asset set and shrinks sharply once LPs are excluded):

| Flag | Candidates | Meaning |
|---|---|---|
| `curated` | 14 | **Positive signal.** Manually reviewed. Not a defect. |
| `notBattleTested` | 1 | New, no track record |
| `complex` | 0 | Leveraged / multi-step strategy |
| `notAudited` | 0 | Strategy contracts unaudited |
| `notCorrelated` | 0 | Assets can diverge — real impermanent-loss exposure |
| `notTimelocked` | 0 | Upgrades take effect without delay |
| `notVerified` | 0 | Contract source unverified on-chain |
| `synthAsset` | 0 | Synthetic asset exposure |

**Only 2 of the 16 carry any warning flag.** So the flags are genuinely sparse, and
they are *not* what makes the top of the ranking untrustworthy — the tiny pool sizes are
(point 2 below). Counting distinct flag *combinations* instead of per-flag totals gives
wrong numbers here; get the counts per flag.

Worth noting: excluding LPs drops `notCorrelated` (real impermanent-loss exposure on a
supposedly stable pair) to **zero**. That flag was concentrated almost entirely in the
multi-asset pools — which is exactly what it should mean. A single-sided vault has no
second asset to diverge from, so the flag and the single-sided filter are measuring the
same underlying hazard from two directions, and the filter removes it outright.

**Do not treat `curated == false` as a warning.** Only ~30% of vaults carry it, so
flagging its absence would mark most rows and turn the flags into noise users learn to
ignore. It is shown as a green "curated by the protocol" note when present, and counted
as nothing when absent. This was the first draft's mistake — it was written before the
live distribution was measured, and would have been wrong.

**2. Pool size — the bigger problem in practice.** Measured TVL distribution across the
16 single-sided stablecoin candidates (2026-09-26):

| TVL | Rows | Share |
|---|---|---|
| < $10K | 9 | 56% |
| < $50K | 12 | 75% |
| < $100K | 14 | 88% |
| < $250K | 14 | 88% |
| < $1M | 15 | 94% |

**Excluding LPs makes this worse, not better**, and that is the counter-intuitive result
worth keeping. The multi-asset set was 70% under $250K; the single-sided set is 88%.
LP pools on Curve/Convex/StakeDAO carry real, often multi-million-dollar TVL, so
removing them strips out most of the large pools and leaves a set dominated by small
Morpho vaults. Only **2 of 16** clear the $250K floor — so with the default filter on,
the app now legitimately opens on a two-row list.

The old headline was `pmUSD/iREET` at **44.50%** in a **$14,555** pool (`CLAUDE.md`
previously recorded 47.25% for this row from an earlier fetch — the APY moved between
reads). The single-sided headline is `morpho-v2-ethereum-steakhouse-prime-instant-pyusd`
at **7.95%**, in a pool holding **$2**. Lower, and *still* dust — which is precisely why
the size disclosure survives the LP removal unchanged. A rate that cannot be captured at
size is misleading whether the pool has two assets or one. Hence:

- `minTVL` defaults to **$250K**, as a *user-visible picker* ("Any" restores everything).
  Nothing is silently discarded; the status bar reports "N of 16 shown".
- Rows under $250K are labelled "tiny pool — rate unlikely to hold at size".

### API decoding gotcha: `risks` is not uniformly shaped

4,005 of 4,042 vaults carry `risks` as an object; **37 carry it as a legacy array** of
tags (`["COMPLEXITY_LOW", "IL_NONE", "AUDIT", ...]`) — all `eol` vaults on retired chains
(`real`, `one`, `heco`, `harmony`), none of them Ethereum+active. Decoding happens before
filtering, so a strict `Decodable` throws on one of these and **the entire fetch fails**
with "not in the correct format". `RiskFlags.init(from:)` is therefore tolerant: a
non-object shape decodes to "no flags known". Safe in that direction only — it can never
invent a warning the protocol did not declare.

Also note `updatedAt` (an `Int`) lives in the same object, so `[String: Bool]` is the
wrong decode type.

## Toolchain constraint — CommandLineTools has no SwiftUI macros

`@State` **cannot be used**. It expands via `SwiftUIMacros.StateMacro`, and CLT's
`usr/lib/swift/host/plugins/` ships only `libObservationMacros.dylib`, `libSwiftMacros.dylib`
and `testing` — there is no `SwiftUIMacros`, and no full Xcode installed to borrow it from.
The build fails with `external macro implementation type 'SwiftUIMacros.StateMacro' could
not be found for macro 'State()'`.

Isolated by testing each wrapper separately: `@StateObject` OK, `@Environment` OK,
`@ObservedObject` OK, `@Binding` OK, **`@State` FAIL**.

Workaround: hold presentation state on the `ObservableObject` model as `@Published`
(e.g. `AppModel.depositTarget`) and bind to `$model.depositTarget`. Do not reach for
`@State` when adding a feature.

## Project state

- The app is **built and working**. Run `./build.sh` then
  `"./Stablecoin Yield.app/Contents/MacOS/StablecoinYield" --selftest <n>` for a headless
  verification report; launch the `.app` directly for the GUI.
- Last self-test (2026-09-26, `--selftest 16`, after the single-sided filter): **16
  verified, 0 mismatched, 0 unverified.** `--selftest 16` now covers the entire candidate
  set, not just a sample — the filter left exactly 16 rows.
- No git repository is initialized here.

### Confirming the GUI without Screen Recording

`screencapture` and `CGWindowListCreateImage` both fail here — this shell has no Screen
Recording permission, and `osascript`/System Events is refused assistive access. Neither
can be granted from inside the session. Two checks that *do* work, and together are
enough to prove the GUI is live:

1. **The window exists on screen.** `CGWindowListCopyWindowInfo` needs no permission as
   long as you don't request image data:
   ```python
   Quartz.CGWindowListCopyWindowInfo(
       Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
       Quartz.kCGNullWindowID)
   ```
   Finds an owner named `Stablecoin Yield` with a 1000×732 window at layer 0 — i.e. a
   real, mapped, front-layer window, listed beside Finder/Safari/Terminal. (1000×700
   content + 32pt title bar, so the `NSWindow` was built with the hosting view attached.)

2. **The SwiftUI view is actually mounted.** `ContentView` mounts `AppModel` and kicks
   work off from a `.task` modifier. Observing exactly **4** concurrent `moli fetch`
   processes right after launch (`pgrep -f "moli fetch" | wc -l`, matching
   `AppModel.crawlConcurrency`) proves that task fired — which cannot happen unless the
   view was constructed and appeared.

Note `lsappinfo` reports `!cgsConnection` for a windowed app here. That is misleading and
is **not** evidence of a headless/failed window — trust the `CGWindowList` result instead.
- `codesign` is ad-hoc and unsigned. If the app is ever distributed, the sandbox /
  hardened-runtime implications of spawning `moli` as a subprocess need addressing.
- `Sources/Verifier.swift:222` emits a Swift 6 `@Sendable` warning on the local
  `finish` function. Harmless today; it becomes an error under `-swift-version 6`.

## Harness notes

- In this session, emitting **more than one tool call per assistant message** has
  reliably failed with `No such tool available: tool` / input-validation errors. Send
  one tool call at a time and wait for the result.