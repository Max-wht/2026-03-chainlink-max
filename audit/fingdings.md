# M-01: `PriceManager.transmit()` accepts out-of-order Data Streams reports and can roll back the stored price

**Severity**: Medium

**Impacted Contracts**

- [PriceManager.sol]
- [BaseAuction.sol]
- [GPV2CompatibleAuction.sol]

## Summary

`PriceManager.transmit()` verifies that a Data Streams report is signed and not older than the configured `stalenessThreshold`, but it does not enforce that `report.observationsTimestamp` is newer than the timestamp already stored for the same asset.

As a result, an older but still valid signed report can overwrite a newer stored report. Once this happens, the protocol continues using the rolled-back price until the stale-path fallback to the configured Chainlink Data Feed is triggered.

Because the cached price is consumed by auction start logic, bid validation, `getAssetOutAmount()`, and GPv2 order validation, this bug can misprice live auctions and weaken the auction curve invariant described in the contest README.

## Root Cause

In [`PriceManager.transmit()`], each verified report is written directly into `s_dataStreamsPrice[asset]`:

```solidity
if (report.observationsTimestamp < block.timestamp - feedInfo.stalenessThreshold) {
  revert Errors.StaleFeedData();
}

s_dataStreamsPrice[asset] =
  DataStreamsPriceInfo({usdPrice: usdPrice.toUint224(), timestamp: report.observationsTimestamp});
```

This only checks whether the report is too old relative to `block.timestamp`. It does not check whether the new report is older than the currently stored report for the same asset.

Therefore, the following sequence is accepted:

1. Store report A with timestamp `T2` and price `P2`
2. Later submit report B with timestamp `T1`, where `T1 < T2`
3. As long as `T1` is still within `stalenessThreshold`, report B is accepted
4. The protocol state rolls back from `(P2, T2)` to `(P1, T1)`

## Impact

This is not just a stale UI/view issue. The rolled-back Data Streams price is directly used by core auction paths:

- [`BaseAuction.bid()`] uses `_getAssetPrice(asset, true)` to value the bid in USD and compute the required `assetOutAmount`
- [`BaseAuction.getAssetOutAmount()`] uses the cached price to quote auction output
- [`BaseAuction.checkUpkeep()`] uses asset prices to decide whether an auction should start or end
- [`GPV2CompatibleAuction.isValidSignature()`] derives the minimum acceptable buy amount from the cached price

Practical consequences:

- an auctioned asset can be undervalued or overvalued using an older report
- `minBuyAmount` checks can be relaxed or tightened incorrectly
- bids can settle against an outdated price curve
- auction start/end eligibility can be evaluated from rolled-back prices

I rate this as **Medium** because the impact is real and protocol-facing, but the strongest direct-loss path still depends on the delivery of out-of-order reports through the trusted reporting pipeline rather than a fully permissionless attacker-controlled entrypoint.

## Proof of Concept

A runnable PoC was added in:

```js
  function testSubmissionValidity() public {
    uint256 initialTimestamp = block.timestamp;
    uint256 newerTimestamp = initialTimestamp + 30 minutes;
    uint256 olderTimestamp = initialTimestamp + 10 minutes;

    // First store a fresher report.
    vm.warp(newerTimestamp);
    _transmitPrices(4_500e18, 1e18, 20e18);

    (uint256 latestPrice, uint256 latestUpdatedAt, bool latestIsValid) = auction.getAssetPrice(address(mockWETH));
    assertEq(latestPrice, 4_500e18, "newer report should set the latest WETH price");
    assertEq(latestUpdatedAt, newerTimestamp, "newer report should set the latest timestamp");
    assertTrue(latestIsValid, "newer report should be valid");

    // Then submit an older but still non-stale signed report. transmit() accepts it and rolls back state.
    _transmitPricesWithObservationTimestamp(3_000e18, 1e18, 20e18, uint32(olderTimestamp));

    (uint256 rolledBackPrice, uint256 rolledBackUpdatedAt, bool rolledBackIsValid) =
      auction.getAssetPrice(address(mockWETH));

    assertEq(rolledBackPrice, 3_000e18, "older report should overwrite the fresher stored price");
    assertEq(rolledBackUpdatedAt, olderTimestamp, "timestamp should roll back to the older observation");
    assertTrue(rolledBackIsValid, "rolled back report remains valid until staleness fallback triggers");
    assertLt(rolledBackUpdatedAt, latestUpdatedAt, "PoC requires the stored timestamp to move backwards");
  }

```

The PoC demonstrates:

1. a newer WETH report is stored first
2. an older but still non-stale report is submitted afterwards
3. `auction.getAssetPrice(mockWETH)` returns the older price and older timestamp

## Recommended Mitigation

Reject any report whose `observationsTimestamp` is not strictly newer than the currently stored timestamp:

```solidity
uint32 lastTimestamp = s_dataStreamsPrice[asset].timestamp;
if (report.observationsTimestamp <= lastTimestamp) {
  continue; // ignore stale or duplicate reports
}

s_dataStreamsPrice[asset] =
  DataStreamsPriceInfo({usdPrice: usdPrice.toUint224(), timestamp: report.observationsTimestamp});
```

This preserves monotonic price updates per asset and prevents rollback from out-of-order or replayed reports.

# M-02: Sold-out or dust auctions can remain live after the auctioned asset price turns stale

**Severity**: Medium

**Impacted Contracts**

- [BaseAuction.sol]

## Summary

[`BaseAuction.checkUpkeep()`] only closes a live auction when either:

1. the auction duration has elapsed, or
2. the remaining balance is below `minAuctionSizeUsd` and the asset price is still fresh

This creates a liveness bug for auctions that are fully cleared, or reduced to economically untradeable dust, shortly before the asset price turns stale.

Once the asset feed becomes stale, the non-expiry close path is disabled by `isPriceValid`, so the auction can remain marked as live in `s_auctionStarts[asset]` until `auctionDuration` elapses even though there is nothing meaningful left to sell.

## Root Cause

The close condition in [`BaseAuction.checkUpkeep()`] is:

```solidity
if (
  auctionStart + assetParams.auctionDuration < block.timestamp
    || (isPriceValid && assetBalanceUsdValue < assetParams.minAuctionSizeUsd)
) {
  endedAuctions[endedAuctionsIdx++] = asset;
}
```

This means the dust-close branch only works while the price is fresh.

At the same time, a live auction is tracked only by whether [`s_auctionStarts[asset] != 0`]. When a bidder fully clears the inventory in [`BaseAuction.bid()`], the auctioned asset balance can drop to zero immediately, but the live flag is not cleared there.

Therefore, the following sequence is possible:

1. An auction is started for `asset`
2. A bidder buys the full remaining balance, or leaves only residual dust
3. The asset price becomes stale before the next upkeep check
4. `checkUpkeep()` does not add the auction to `endedAuctions` because:
   - it is not expired yet, and
   - the residual-size branch is gated on `isPriceValid`
5. `s_auctionStarts[asset]` stays nonzero until expiry

## Impact

This is a temporary denial-of-service / stuck-state issue for the affected asset:

- the collected `assetOut` remains inside the auction contract because [`_onAuctionEnd()`] is not reached
- the asset cannot cleanly transition into a new auction while the old live flag is pinned
- admin flows guarded by live-auction checks can also be blocked for the same asset until expiry

The issue does not directly steal funds, but it can delay reserve forwarding and auction recycling for the full auction duration. I rate this as **Medium** because it affects protocol liveness and fund flow for a live production path.

## Proof of Concept

A runnable PoC was added in:

- [test/poc/C4PoC.t.sol]

The PoC does the following:

1. Starts a USDC auction
2. Fully clears the auction inventory through `bid()`
3. Waits until the USDC feed is stale, but not until auction expiry
4. Calls `checkUpkeep()`
5. Observes that:
   - `upkeepNeeded == false`
   - the auction start timestamp is still pinned
   - the collected LINK remains in the auction contract instead of being forwarded to reserves

## Recommended Mitigation

A fix based only on `assetBalance == 0` is too narrow. It fixes the exact sold-out case, but not the broader case where the remaining balance has become untradeable dust.

The more complete fix is to end a live auction whenever its remaining inventory falls below the minimum executable auction size, without requiring the price to still be fresh at that moment.

Because `minAuctionSizeUsd` is USD-denominated, the clean implementation is to cache a token-denominated residual threshold when the auction starts, then close the auction whenever:

```solidity
assetBalance < minExecutableResidualBalance
```

independent of later feed freshness.

If the team wants a minimal short-term patch, treating `assetBalance == 0` as an unconditional end condition is still an improvement, but it should be viewed as a partial mitigation rather than the complete fix.
