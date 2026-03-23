# Audit Notes

## Contents

- [Scope](#scope)
- [System View](#system-view)
- [Key Data Structures](#key-data-structures)
  - [Shared and Support](#shared-and-support)
  - [Price Manager](#price-manager)
  - [Base Auction](#base-auction)
  - [GPV2 Compatible Auction](#gpv2-compatible-auction)
  - [Auction Bidder](#auction-bidder)
  - [Workflow Router](#workflow-router)
- [Math and Pricing Models](#math-and-pricing-models)
  - [Price normalization](#price-normalization)
  - [Price freshness model](#price-freshness-model)
  - [Auction start and end rules](#auction-start-and-end-rules)
  - [Bid value check](#bid-value-check)
  - [Auction price curve](#auction-price-curve)
  - [AssetOut amount calculation](#assetout-amount-calculation)
- [File Overviews](#file-overviews)
  - [PriceManager.sol](#pricemanagersol)
  - [BaseAuction.sol](#baseauctionsol)
  - [GPV2CompatibleAuction.sol](#gpv2compatibleauctionsol)
  - [AuctionBidder.sol](#auctionbiddersol)
  - [WorkflowRouter.sol](#workflowroutersol)
  - [Caller.sol](#callersol)
  - [IBaseAuction.sol](#ibaseauctionsol)
  - [IAuctionCallback.sol](#iauctioncallbacksol)
  - [IGPV2CompatibleAuction.sol](#igpv2compatibleauctionsol)
  - [IGPV2Settlement.sol](#igpv2settlementsol)
  - [IPriceManager.sol](#ipricemanagersol)
  - [Errors.sol](#errorssol)
  - [Roles.sol](#rolessol)
- [Short Risk Lens](#short-risk-lens)

## Scope

This note follows the scope rule in [out_of_scope.txt](/Users/max/code/defi-security/competetive-audit/2026-03-chainlink-max/out_of_scope.txt). The in-scope Solidity files are:

- `src/AuctionBidder.sol`
- `src/BaseAuction.sol`
- `src/Caller.sol`
- `src/GPV2CompatibleAuction.sol`
- `src/PriceManager.sol`
- `src/WorkflowRouter.sol`
- `src/interfaces/IAuctionCallback.sol`
- `src/interfaces/IBaseAuction.sol`
- `src/interfaces/IGPV2CompatibleAuction.sol`
- `src/interfaces/IGPV2Settlement.sol`
- `src/interfaces/IPriceManager.sol`
- `src/libraries/Errors.sol`
- `src/libraries/Roles.sol`

Out-of-scope contracts still matter for context. The most important ones are the pause/access-control base contracts, the LINK receiver, emergency withdrawal helpers, `Common.AssetAmount`, and the fee aggregator interface.

## System View

At a high level, this repo has two main parts:

- An auction stack: `PriceManager` -> `BaseAuction` -> `GPV2CompatibleAuction`, with `AuctionBidder` as the external solver.
- A workflow dispatch stack: `WorkflowRouter`, which forwards approved workflow calls to approved targets and selectors.

The auction flow is:

1. `PriceManager` stores and serves USD prices.
2. `BaseAuction` decides when an auction should start or end.
3. Bidders buy auctioned assets by paying `assetOut`.
4. `GPV2CompatibleAuction` lets the same auction be solved through CoW Protocol orders.
5. `AuctionBidder` is a helper contract that can execute a multi-step solution and then settle the bid.

## Key Data Structures

### Shared and Support

- `Caller.Call`
  - A target address plus calldata.
  - Used by `AuctionBidder` and `WorkflowRouter` to run arbitrary approved calls.

- `Errors`
  - A shared list of custom errors used across the system.
  - Main theme: zero values, stale prices, bad permissions, unchanged config, and reentrancy.

- `Roles`
  - Shared role IDs for admin, pausing, pricing, auction work, bidding, forwarding, and order invalidation.
  - The system depends heavily on role separation.

- `Common.AssetAmount` (out of scope but used by in-scope code)
  - Asset address plus amount.
  - Used when the auction pulls balances from the fee aggregator and when the bidder admin withdraws tokens.

### Price Manager

- `ReportV3`
  - Decoded Data Streams report.
  - Holds feed ID, validity window, fees, expiry, and price fields.
  - The contract mainly uses the feed ID, observation timestamp, and price.

- `FeedInfo`
  - The pricing config for one asset.
  - Holds the Data Streams feed ID, optional Chainlink USD data feed, staleness threshold, and Data Streams decimals.

- `ApplyFeedInfoUpdateParams`
  - Input struct for feed config updates.
  - Pairs an asset with its `FeedInfo`.

- `DataStreamsPriceInfo`
  - Cached Data Streams price for one asset.
  - Stores `usdPrice` and `timestamp`.

- `s_allowlistedAssets`
  - Set of assets that the system is willing to price and auction.

- `s_feedInfo`
  - Asset -> `FeedInfo`.

- `s_dataStreamsFeedIdToAsset`
  - Reverse lookup from feed ID to asset.

- `s_dataStreamsPrice`
  - Asset -> latest stored stream price.

### Base Auction

- `ConstructorParams`
  - Startup config for the auction system.
  - Includes admin settings, pricing config, bid floor, asset out settings, fee aggregator, and initial feeds.

- `AssetParams`
  - Core per-asset auction config.
  - Fields:
  - `minAuctionSizeUsd`: smallest allowed auction size in USD terms.
  - `startingPriceMultiplier`: price premium at auction start.
  - `endingPriceMultiplier`: price level at auction end.
  - `auctionDuration`: how long the auction lasts.
  - `decimals`: token decimals, checked against the token contract.

- `ApplyAssetParamsUpdate`
  - Input struct for adding or updating auction params for one asset.

- `s_assetParams`
  - Asset -> `AssetParams`.

- `s_auctionStarts`
  - Asset -> auction start timestamp.
  - A nonzero value means the auction is live.

- `s_minBidUsdValue`
  - Global bid floor in USD terms.

- `s_assetOut`
  - The token bidders pay with.

- `s_assetOutReceiver`
  - The address that receives collected `assetOut` after auction end or direct forwarding.

- `s_feeAggregator`
  - Source of assets to be auctioned, unless the auction contract acts as its own source.

- `s_entered`
  - Reentrancy guard for the bid path.

### GPV2 Compatible Auction

- `i_gpV2VaultRelayer`
  - The CoW vault relayer that receives token approval during a live auction.

- `i_gpV2Settlement`
  - Settlement contract used for domain separation and order invalidation.

- External struct in use: `GPv2Order.Data`
  - Not defined locally, but it is the main order format checked in `isValidSignature`.
  - Important fields in practice: sell token, buy token, receiver, sell amount, buy amount, expiry, fee, order kind, partial-fill flag, and balance markers.

### Auction Bidder

- `s_auction`
  - The auction contract this bidder works with.

- `s_receiver`
  - Optional address that receives leftover `assetOut` after a bid is solved.

### Workflow Router

- `TargetSelectors`
  - One target plus the function selectors allowed on that target.

- `AllowlistedWorkflow`
  - One workflow ID plus its full target-selector allowlist.

- `WorkflowInfo`
  - Internal storage for one workflow.
  - Holds:
  - a set of allowlisted targets
  - a mapping from each target to its allowlisted selectors

- `s_allowlistedWorkflowIds`
  - Set of approved workflow IDs.

- `s_workflowInfos`
  - Workflow ID -> `WorkflowInfo`.

## Math and Pricing Models

### Price normalization

All asset prices are normalized to 18 decimals.

- If a Data Streams price has fewer than 18 decimals, it is scaled up.
- If it has more than 18 decimals, it is scaled down.
- The same idea is used for the fallback Chainlink data feed price.

This makes later auction math simpler because every USD price uses the same unit.

### Price freshness model

Each asset has a `stalenessThreshold`.

- A Data Streams price is valid only if its timestamp is recent enough.
- If the stream price is stale and a Chainlink data feed exists, the contract tries the data feed.
- The newer valid price source wins.
- A zero price is always invalid.

This means pricing is "prefer streams, fallback to feed, reject stale or zero data."

### Auction start and end rules

An auction can start only when:

- the asset is allowlisted and configured
- the asset out price is valid
- the asset has no live auction
- the available balance is worth at least `minAuctionSizeUsd`

An auction ends when either:

- `auctionDuration` has passed, or
- the remaining asset balance is worth less than `minAuctionSizeUsd`

The second rule is a dust cleanup rule.

### Bid value check

Every bid is checked in USD terms:
//? what is the decimal of assetPrice
`bidUsdValue = amountIn * assetPrice / 10^assetDecimals`

The bid must be at least `s_minBidUsdValue`.

### Auction price curve

The auction price moves linearly over time from `startingPriceMultiplier` to `endingPriceMultiplier`.

Plain English:

- At the start, the bidder pays a premium.
- Over time, the price gets better for the bidder.
- The price never goes below the configured ending level.

The effective multiplier is:

`starting - ((starting - ending) * elapsed / duration)`

So the discount grows linearly with time.

### AssetOut amount calculation

The auction converts the sold asset into USD value, applies the time-based multiplier, then converts that USD value into `assetOut`.

Plain flow:

1. Get the input asset USD price.
2. Convert `amountIn` into USD value.
3. Apply the current auction multiplier.
4. Divide by the `assetOut` USD price.
5. Adjust for `assetOut` decimals.

The contract uses round-up math in key places so the payer does not underpay because of rounding.

## File Overviews

### PriceManager.sol

Purpose:
Stores trusted asset prices for the auction system. It accepts Data Streams reports, keeps per-asset feed config, and falls back to Chainlink data feeds when needed.

Main responsibilities:

- allowlist assets
- map assets to their price sources
- verify incoming reports
- cache recent prices
- expose a unified price getter

Function overview:

- `constructor`
  - Sets the verifier proxy, LINK token path, and optional initial feed config.

- `transmit`
  - Verifies Data Streams reports in bulk and stores fresh prices.
  - Rejects reports for feeds that are not allowlisted.

- `applyFeedInfoUpdates`
  - Admin entry point for feed config changes.

- `_applyFeedInfoUpdates`
  - Core add/update/remove logic for assets and their feed config.
  - Also handles feed ID rotation and cleanup of old mappings.

- `_onFeedInfoUpdate`
  - Empty hook for child contracts.
  - Lets child contracts block feed updates when their own state would be harmed.

- `getStreamsVerifierProxy`
  - Returns the verifier contract.

- `getAllowlistedAssets`
  - Returns the asset allowlist.

- `getFeedInfo`
  - Returns feed config for one asset.

- `getAssetFromDataStreamsFeedId`
  - Reverse lookup from feed ID to asset.

- `getAssetPrice`
  - Public read helper for the latest usable price.

- `_getAssetPrice`
  - Core price lookup logic.
  - Prefers stored stream price, then falls back to Chainlink feed if needed.

- `supportsInterface`
  - ERC165 support check.

### BaseAuction.sol

Purpose:
Implements the main auction engine. It decides when auctions start and end, holds per-asset auction settings, and lets bidders buy assets with the common payment token(asset out).

Main responsibilities:

- scan assets for auction start and end conditions
- pull assets from the fee source
- track live auctions
- compute time-based prices
- settle bids
- guard config changes during live auctions

Function overview:

- `constructor`
  - Wires pricing, admin config, bid floor, payment token, payment receiver, and fee source.

- `checkUpkeep`
  - Read-only scanner.
  - Finds assets that should start an auction and auctions that should end.
  - Returns encoded work for an external worker.

- `performUpkeep`
  - Trusted worker entry point.
  - Starts new auctions, pulls auction inventory, ends old auctions, and moves balances where needed.

- `_onAuctionStart`
  - Child hook.
  - Used by child contracts to add extra start logic.

- `_onAuctionEnd`
  - Default close logic.
  - Sends leftover auctioned asset back to the fee source and forwards collected `assetOut` to the receiver.

- `bid`
  - Main user entry point for buying auctioned assets.
  - Checks auction validity, computes the current price, transfers the auctioned asset out (user transfer to protocol), optionally runs a callback, and then pulls in `assetOut`.

- `setMinBidUsdValue`
  - Admin setter for the global bid floor.

- `_setMinBidUsdValue`
  - Internal validation and storage for the bid floor.

- `setAssetOut`
  - Admin setter for the common payment token.

- `_setAssetOut`
  - Internal payment-token update logic.
  - Only allowed when no live auction exists.

- `setAssetOutReceiver`
  - Admin setter for where collected payment tokens are sent.

- `_setAssetOutReceiver`
  - Internal receiver update logic.

- `setFeeAggregator`
  - Admin setter for the fee source contract.

- `_setFeeAggregator`
  - Internal fee source update logic.
  - Verifies interface support when the source is external.

- `applyAssetParamsUpdates`
  - Admin entry point for per-asset auction config updates.

- `_applyAssetParamsUpdates`
  - Core validation and storage for per-asset auction parameters.
  - Also blocks sensitive changes during live auctions.

- `_whenNoLiveAuctions`
  - Shared guard used by config functions.

- `_liveAuctionExists`
  - Checks whether any asset currently has a live auction.

- `_onFeedInfoUpdate`
  - Tightens the `PriceManager` hook.
  - Blocks feed config changes that would affect a live auction.

- `getAssetOut`
  - Returns the common payment token.

- `getAssetOutReceiver`
  - Returns the payment receiver.

- `getFeeAggregator`
  - Returns the configured fee source.

- `getAssetParams`
  - Returns auction config for one asset.

- `getAuctionStart`
  - Returns the live auction start time for one asset.

- `getMinPriceMultiplier`
  - Returns the global floor for ending multipliers.

- `getAssetOutAmount`
  - Read-only quote helper for the current auction price.
  - Returns zero for invalid timing or missing live auction.

- `_getAssetOutAmount`
  - Core auction math.
  - Applies the linear multiplier curve and converts input asset value into `assetOut`.

- `supportsInterface`
  - ERC165 support check.

### GPV2CompatibleAuction.sol

Purpose:
Adds CoW Protocol compatibility on top of `BaseAuction`. It lets the auction act like an EIP-1271 signer for valid CoW sell orders.

Main responsibilities:

- approve CoW vault relayer during live auctions
- validate CoW orders against live auction state
- invalidate old CoW orders through the settlement contract

Function overview:

- `constructor`
  - Sets the CoW vault relayer and settlement contract.

- `_onAuctionStart`
  - Extends the base hook.
  - Approves the CoW relayer to move the auctioned token.

- `_onAuctionEnd`
  - Extends the base hook.
  - Revokes the CoW relayer approval after the auction closes.

- `isValidSignature`
  - Core CoW order validator.
  - Rebuilds and checks the order hash, checks that the order matches the current auction rules, checks balances and expiry, and ensures the order price is good enough.

- `invalidateOrders`
  - Admin-like order management function.
  - Forwards order invalidation to the settlement contract.

- `getGPV2VaultRelayer`
  - Returns the vault relayer address.

- `getGPV2Settlement`
  - Returns the settlement contract.

### AuctionBidder.sol

Purpose:
Acts as a controlled bidder/solver contract. It can either do a simple direct bid or run custom call steps before settling the payment side of the auction.

Main responsibilities:

- point to one auction contract
- place bids
- run callback solution logic
- forward leftover tokens to a receiver
- let admin withdraw tokens

Function overview:

- `constructor`
  - Sets the auction contract and optional receiver.

- `bid`
  - Main bidder entry point.
  - If no custom solution is given, it pre-approves the auction for the quoted amount.
  - If a custom solution is given, it passes the encoded plan into the auction callback flow.

- `auctionCallback`
  - Called by the auction during a bid.
  - Runs the supplied call sequence and then approves the auction to pull the exact payment amount.

- `withdraw`
  - Admin token withdrawal helper.

- `setAuction`
  - Admin setter for the auction contract.

- `_setAuction`
  - Internal validation for the auction address and interface support.

- `setReceiver`
  - Admin setter for the leftover-funds receiver.

- `_setReceiver`
  - Internal receiver update logic.

- `getAuction`
  - Returns the configured auction contract.

- `getReceiver`
  - Returns the configured leftover-funds receiver.

- `supportsInterface`
  - ERC165 support check.

### WorkflowRouter.sol

Purpose:
Acts as a guarded forwarder for Chainlink workflow reports. It only lets approved workflow IDs call approved targets with approved selectors.

Main responsibilities:

- store workflow allowlists
- store per-workflow target allowlists
- store per-target selector allowlists
- decode workflow reports
- forward allowed calls

Function overview:

- `constructor`
  - Sets the admin and inherited role system.

- `onReport`
  - Main entry point for incoming workflow reports.
  - Extracts the workflow ID, checks it, checks the target and selector, then forwards the call.

- `applyAllowlistedWorkflowsUpdates`
  - Adds or removes whole workflows.
  - When removing a workflow, it also clears its targets and selectors.

- `applyAllowlistedTargetsUpdates`
  - Admin entry point for target-level updates inside one workflow.

- `_applyAllowlistedTargetsUpdates`
  - Core target add/remove logic.
  - Also clears selectors when a target is removed.

- `applyAllowlistedSelectorsUpdates`
  - Admin entry point for selector-level updates inside one workflow and target.

- `_applyAllowlistedSelectorsUpdates`
  - Core selector add/remove logic.

- `getAllowlistedWorkflowIds`
  - Returns all allowed workflow IDs.

- `getAllowlistedTargets`
  - Returns allowed targets for one workflow.

- `getAllowlistedSelectors`
  - Returns allowed selectors for one workflow and target.

- `supportsInterface`
  - ERC165 support check.

### Caller.sol

Purpose:
Small helper for low-level external calls.

Function overview:

- `_call`
  - Runs one low-level call and bubbles up the revert reason if the call fails.

- `_multiCall`
  - Runs a list of calls in order.
  - Reverts if the list is empty.

### IBaseAuction.sol

Purpose:
Defines the public auction surface used by workers and bidders.

Function overview:

- `checkUpkeep`
  - Simulates whether auction work is needed and returns encoded work.

- `performUpkeep`
  - Executes the encoded auction work.

- `bid`
  - Lets a bidder buy an auctioned asset.

- `getAssetOut`
  - Returns the common payment token.

- `getAssetOutAmount`
  - Returns a quote for how much payment token is needed.

### IAuctionCallback.sol

Purpose:
Defines the callback that the auction can use when a bidder wants custom logic during settlement.

Function overview:

- `auctionCallback`
  - Receives callback context and custom data from the auction bid flow.

### IGPV2CompatibleAuction.sol

Purpose:
Small extension interface for CoW-specific order invalidation.

Function overview:

- `invalidateOrders`
  - Invalidates one or more CoW order UIDs.

### IGPV2Settlement.sol

Purpose:
Minimal external interface to the CoW settlement contract.

Function overview:

- `domainSeparator`
  - Returns the EIP-712 domain separator used to rebuild order hashes.

- `settle`
  - Main CoW settlement entry point.
  - Not called directly by the in-scope auction logic, but part of the expected external system.

- `invalidateOrder`
  - Invalidates one CoW order UID.

### IPriceManager.sol

Purpose:
Defines the public pricing update entry point.

Function overview:

- `transmit`
  - Accepts Data Streams report payloads and updates stored prices.

### Errors.sol

Purpose:
Central error list shared across the system.

Overview:

- No functions.
- Defines reusable custom errors for invalid input, stale pricing, access control, allowlist mistakes, unchanged config, bad fee aggregator config, and reentrancy.

### Roles.sol

Purpose:
Central role ID list shared across the system.

Overview:

- No functions.
- Defines role constants for pausing, unpausing, asset management, pricing, workflow forwarding, auction work, bidding, and CoW order management.

## Short Risk Lens

The most important moving parts for audit attention are:

- price freshness and fallback choice in `PriceManager`
- live-auction state transitions in `BaseAuction`
- the linear pricing curve and rounding direction in `_getAssetOutAmount`
- callback and multicall behavior across `BaseAuction`, `AuctionBidder`, and `Caller`
- CoW order validation rules in `GPV2CompatibleAuction`
- selector-level forwarding rules in `WorkflowRouter`
