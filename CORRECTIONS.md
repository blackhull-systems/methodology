# Corrections

Dated corrections to Blackhull's methods and published measurements, newest first.

## 2026-11-02 — unknown funding is no longer counted as organic

**What changed:** the organic-demand measurement now reports a payer whose funding could not be traced as *unknown*.
The first version counted such payers as organic, which overstated a seller's organic share when its heaviest buyers
had no traceable funding. The same day, an analysis that treated a faucet's many small wallets as a large share of a
seller's demand was corrected: by payment volume, those wallets were a small share.

**Effect:** organic shares are now computed only over payers with a known funder; the count of unknown payers is
reported alongside.

## 2026-11-02 — proxy implementations found from the proxy's own code

**What changed:** the token check first read only the standard EIP-1967 implementation slot, so a proxy using an older
layout (for example USDC on Base) was scanned without its implementation and showed no admin powers. It now reads each
storage slot the proxy's own code names.

**Effect:** admin powers held in a proxy's implementation (mint, pause, blacklist) are now reported.
