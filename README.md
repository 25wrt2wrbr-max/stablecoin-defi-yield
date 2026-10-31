# Stablecoin Yield

A macOS app that lists places to park one stablecoin for yield, ranked from highest APY to lowest.

Each rate is cross-checked. The app reads the protocol API, then crawls that protocol's own page with Moli, and marks a figure verified only when the two agree. Deposit links open inside the app. Rows also show protocol risk flags and pool size. The default list is single-sided stablecoin vaults with at least $250K in the pool.

## Build and run

```bash
./build.sh
open "Stablecoin Yield.app"
```

Needs macOS 14 or later, Apple silicon, and the Command Line Tools Swift compiler. Verification crawls need Moli installed, looked up at `~/.local/bin/moli`, `/opt/homebrew/bin/moli`, `/usr/local/bin/moli`, or on `PATH`.
