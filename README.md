# Blackhull methodology

How Blackhull measures what it sells: the finding codes, every threshold, how organic demand is told apart from funded
demand, and how a finding is disputed. Generated from the method the live service uses
(<https://blackhullsystems.com/methodology>), version **findings-v1**, as of **2026-11-04**.

Every answer Blackhull sells is a **measurement of public data with its evidence**. It is not financial, investment or
legal advice, and a code describes what was measured, never anyone's intent.

## Where the data comes from

- **Payments:** USDC `Transfer` events on Base, read directly from the chain: the payments into the wallets that x402
  listings publish (`payTo`), read forward from the day Blackhull starts watching each wallet; plus short windows across
  each day in which every EIP-3009 authorized USDC payment on Base is read, which also covers wallets no directory
  lists.
- **Listings:** the x402 directories' own published listings (price, description, payment wallet).
- **Hosting:** public routing and address-registry data (which network a service runs on).
- **Tokens:** live JSON-RPC reads of the token's contract on Base (code, storage, `owner()`), and of its pools against
  WETH, ETH or USDC on Uniswap v2, v3 and v4, Aerodrome and Aerodrome Slipstream.

No logins, no private data, free public sources first.

## Service and wallet findings

A report grades a service **`WARNING` / `CAUTION` / `CLEAN` / `INSUFFICIENT_DATA`**. A negative or caution finding is only stated after the service has been
watched long enough (see thresholds); before that the grade is `INSUFFICIENT_DATA` and the report is free.

| Code | Kind | What it means |
|---|---|---|
| `NO_SALES_OBSERVED` | negative | no payment at a listed price in the hours Blackhull watched its wallet |
| `FEW_BUYERS` | negative | fewer than 3 distinct wallets paid a listed price |
| `CONCENTRATED_DEMAND` | negative | one wallet made a large share of the payments into its wallet |
| `INFLOW_NOT_AT_LISTED_PRICES` | negative | most payments into its wallet were not at any price it lists |
| `REVENUE_NOT_FROM_LISTING` | negative | most USDC into its wallet did not come from its listed prices |
| `DIRECTORY_DISAGREES_WITH_CHAIN` | negative | the directory's call count and the chain's payments differ widely |
| `STALE` | negative | no recent use: the directory's last call is old |
| `UNPLACED` | negative | its host does not resolve, or its address is in no announced route |
| `PRICE_OUTLIER` | negative | its listed price is far above what its category is actually paid |
| `FUNDED_FROM_FEW_SOURCES` | negative | most of its traced buyers were funded from one source shortly before paying |
| `CIRCULAR_FUNDING` | negative | some of its traced buyers were funded by its own payment wallet shortly before paying it |
| `SHARED_WALLET` | info | one payment wallet sits behind many listings |
| `PAID_AS_LISTED` | positive | nearly all payments into its wallet were at a price it lists |
| `DIVERSE_BUYERS` | positive | many distinct buyers, none dominant |
| `ACTIVE` | positive | paid at a listed price within the last day |

### Thresholds

| Name | Value |
|---|---|
| `min_hours_caution` | 24 |
| `min_hours_warning` | 72 |
| `concentration_caution` | 0.5 |
| `concentration_warning` | 0.8 |
| `concentration_min_payments` | 20 |
| `few_buyers_below` | 3 |
| `unlisted_inflow_share_below` | 0.5 |
| `unlisted_inflow_min_payments` | 20 |
| `revenue_from_listing_below` | 0.1 |
| `revenue_min_usdc` | 10 |
| `shared_wallet_listings` | 10 |
| `directory_ratio_above` | 5 |
| `directory_ratio_below` | 0.2 |
| `directory_min_calls30` | 300 |
| `stale_days` | 14 |
| `price_outlier_times_category` | 10 |
| `paid_as_listed_share` | 0.9 |
| `diverse_min_payers` | 20 |
| `diverse_max_top1` | 0.25 |
| `funder_share_caution` | 0.6 |
| `funder_min_traced` | 10 |
| `circular_caution` | 0.3 |
| `circular_warning` | 0.5 |

## Token check codes

| Code | Kind | What it means |
|---|---|---|
| `NO_CONTRACT` | info | no contract code at this address on Base |
| `NOT_ERC20` | info | the contract does not answer totalSupply() as an ERC-20 does |
| `OWNER_ACTIVE` | caution | owner() returns a non-zero address: someone holds the contract's admin role |
| `OWNER_RENOUNCED` | positive | owner() returns the zero address |
| `CAN_MINT` | caution | the bytecode contains a mint function selector |
| `CAN_PAUSE` | caution | the bytecode contains pause() |
| `CAN_BLACKLIST` | caution | the bytecode contains a blacklist-setting selector |
| `CAN_SET_FEE` | caution | the bytecode contains a fee/tax-setting selector |
| `UPGRADEABLE` | caution | the contract is a proxy whose implementation slot points at code: the code can be replaced |
| `LIQUIDITY` | positive | a pool holds at least 0.1 WETH/ETH or 250 USDC against this token |
| `THIN_LIQUIDITY` | caution | pools exist, but none holds 0.1 WETH/ETH or 250 USDC |
| `NO_POOL_FOUND` | caution | no pool was found (on Uniswap v4: among the pool configurations most used on Base) |
| `SELL_OK` | positive | a simulated buy and an immediate sale of everything bought both went through |
| `SELL_BLOCKED` | caution | a simulated buy went through, and the immediate sale of what it bought reverted |
| `HIGH_TAX` | caution | the simulated buy or sale lost 10% or more of the tokens moved to the token itself (a transfer tax) |
| `BUY_FAILED` | info | the simulated buy reverted (trading not open, or a pool hook that refuses it), so selling was not tested |
| `RECENT_SELLS` | positive | the deepest pool recorded sales of the token in at least 3 separate transactions in the last few hours (checks.trades says how many, and over what window) |

**How powers are found:** the deployed bytecode is scanned for the 4-byte function selectors of known admin
functions (for example `mint(address,uint256)`). If the contract is a proxy, its implementation is found by reading
each 32-byte storage slot the proxy's own code names (`PUSH32` constants, covering EIP-1967 and older layouts) and the
implementation's code is scanned too. A selector's presence means the code *can* call that function; it does not mean
anyone will.

**How a sale is simulated (`SELL_OK`, `SELL_BLOCKED`, `HIGH_TAX`, `BUY_FAILED`):** on the deepest pool that holds
liquidity, a small buy (0.001 ETH or 1 USDC, and never more than 0.1% of the pool's quote reserve) is followed at once by
a sale of everything it bought, in one `eth_call`. The contract that trades,
[`sell-simulation/SellCheck.sol`](sell-simulation/SellCheck.sol), is never deployed: the call places its code at an
unused address with a state override and gives it the ETH (or USDC) to spend, so nothing is sent, signed or paid and
the chain is unchanged. It buys from the pool itself and **sells the way a user does**: on Uniswap pools (v2, v3, and v4 including the pool's
hook) through Uniswap's own Universal Router, the token pulled by Permit2, so a token or hook that treats the router
differently from a direct trade cannot pass a sale no user could make. If the router's sale fails, the same sale is
tried straight to the pool: one that goes through only that way is `SELL_BLOCKED`, and the answer says so
(`sells_only_directly`). On Aerodrome and Slipstream pools the sale goes straight to the pool, through a second address
that pulls the tokens with `transferFrom` as a router would; Aerodrome's own router is not simulated.

- A **tax** is measured from balances, not read from the token: the buy tax is the share of what the pool released that
  did not arrive; the sell tax, the share of what was sent that the pool did not receive. `HIGH_TAX` is 10% or more
  on either leg. A fee that a pool or its hook keeps is not a token tax; it shows in `round_trip_back_pct`, the share of
  the spend the sale returned (pool fees and price movement included).
- **A token cannot tell it is being tested.** Each check trades from a fresh random address, with random bytes after the
  simulator's code (so it has no code hash to look for), at the network's current gas price, with a buy size that varies.
  A token that let only the simulator sell would otherwise read as sellable while trapping real buyers.
- **Text the token wrote is labelled as such.** A token's name and symbol, and the reason its code gives when a trade
  reverts, are written by its deployer. They are cleaned of hidden characters, shortened, and listed in every answer's
  `untrusted_text`: data to show, never instructions. Blackhull's findings are the codes.
- **What real traders did (`RECENT_SELLS`):** the same pool's own swap events over the last ten minutes, widening to the
  last hour and then about five hours while too few sales show (each answer says which window), counted as buys, sales and the transactions that sold. A simulation
  shows a sale can go through; this shows whether real wallets are getting out. A pool showing buys and no sales gets
  no code yet: in validation it fired on a token with dozens of real sales over the days before, so the counts are
  given for a reader to judge, and a code will follow only once it is shown to separate honeypots from quiet hours.
- **What it does not show:** the result is for this pool, this block and this size, by a contract holder. A token can
  change its rules later, treat other holders or larger sales differently, or limit sales over time; one simulation
  sees none of that.

Compiled with solc 0.8.28 (optimizer 200 runs, via-IR, EVM version cancun). Every answer's evidence names the
keccak-256 of the bytecode the simulation ran (`simulator_keccak256`), and that bytecode ends in the metadata hash of
exactly this source, so anyone can compile it and compare.

## Organic and funded demand

A seller's payment count can be inflated by wallets funded for the purpose. For each paying wallet Blackhull traces the
last USDC transfer into it before its first payment, within 5,000 blocks (about 2.8 hours).
A funder is classed a **faucet** when it funded at least **20** traced payers, at least
**80%** of them with the same amount. A seller's **organic share** is the share of its payments, among payers whose funder is known, that do *not* come from
faucet-funded wallets. Payers whose funding could not be found are reported as **unknown**, never counted as organic.

## Disputes

1. Send a dispute to /dispute, free: the service's URL, the finding code and a reason.
2. The next daily run measures the finding again from fresh data.
3. The outcome is upheld (still observed, with the fresh evidence attached) or withdrawn (no longer observed).
4. A dispute alone never removes a finding.
5. Every dispute and its outcome is listed at [/disputes](https://blackhullsystems.com/disputes).

Reasons: `data-outdated`, `method-error`, `listing-changed`, `other`. A dispute is one request, no account needed:

```
https://blackhullsystems.com/dispute?url=<the service's x402 URL>&code=<finding code>&reason=<reason>
```

## Corrections

When a published measurement or method turns out wrong, the correction is recorded here, dated, with what changed.
See [CORRECTIONS.md](CORRECTIONS.md).

---

Findings are measurements of public data, not financial, investment or legal advice.

<sub>Built and maintained by Blackhull's AI system; every release is reviewed and signed by its owner.</sub>
