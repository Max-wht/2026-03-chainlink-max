# QA

## 1. What is the Data Streams report schema V3 in `PriceManager`? What role does Data Streams play in the whole process?

  In [PriceManager.sol](/Users/max/code/defi-security/competetive-audit/2026-03-chainlink-max/src/PriceManager.sol), `ReportV3` is the struct format used to decode Chainlink Data Streams reports after they are verified by the `VerifierProxy`.

  It contains fields such as:

  - `dataStreamsFeedId`: identifies which asset feed the report belongs to
  - `validFromTimestamp` and `observationsTimestamp`: describe the time window of the report
  - `nativeFee` and `linkFee`: verification fee fields
  - `expiresAt`: report expiry time
  - `price`: the main reported price
  - `bid` and `ask`: extra market data fields

  In this system, Data Streams is the main source of fresh price data.

  The process is:

  1. An address with `PRICE_ADMIN_ROLE` calls `transmit`.
  2. `PriceManager` sends the raw reports to Chainlink `VerifierProxy`.
  3. The proxy verifies that the reports are valid.
  4. `PriceManager` decodes the verified `ReportV3` data.
  5. The contract stores the normalized USD price for each asset.
  6. The auction logic later uses these stored prices to:
    - decide whether an auction should start or end
    - compute how much `assetOut` a bidder must pay

  So, Data Streams is the primary pricing input for the auction system.

  ## 2. Is `PriceManager` using the Chainlink Price Oracle interface?

  Not in the simple sense of using only one Chainlink price feed interface.

  `PriceManager` combines two Chainlink price sources:

  - Chainlink Data Streams through `IVerifierProxy`
  - Chainlink Data Feeds through `AggregatorV3Interface`

  Its logic is:

  - first try the stored Data Streams price
  - if that price is stale, and a normal Chainlink data feed is configured, try the data feed
  - use the newer usable price
  - normalize all prices to 18 decimals

  So `PriceManager` is better described as a price manager with fallback logic, not just a thin wrapper around one oracle interface.

## 3. What is the difference between `minPriceMultiplier` and the per-asset price multipliers? What are their targets?

  The original question seems to have a typo because it compares `minPriceMultiplier` with itself.

  The meaningful comparison is:

  - `minPriceMultiplier`
  - `startingPriceMultiplier`
  - `endingPriceMultiplier`

  Their roles are:

  - `minPriceMultiplier`
    - a global lower bound for the whole system
    - it limits how low an auction price is allowed to go
    - it is used as a safety check when asset parameters are configured

  - `startingPriceMultiplier`
    - a per-asset starting point
    - it defines the auction price at the beginning
    - usually this is above `1e18`, meaning the auction starts at a premium

  - `endingPriceMultiplier`
    - a per-asset ending point
    - it defines the lowest price that asset can reach by the end of the auction
    - it must not be lower than the global `minPriceMultiplier`

  Plain English:

  - `minPriceMultiplier` protects the protocol globally
  - `startingPriceMultiplier` sets the opening price for one asset
  - `endingPriceMultiplier` sets the final floor for one asset

  Example:

  - `startingPriceMultiplier = 1.10e18` means the auction starts at a 10% premium
  - `endingPriceMultiplier = 0.98e18` means the auction can end at a 2% discount
  - `minPriceMultiplier = 0.95e18` means no asset is allowed to end below a 5% discount

  So the target of `minPriceMultiplier` is system-wide safety, while the target of `startingPriceMultiplier` and `endingPriceMultiplier` is per-asset auction pricing.

## 4. what the role AuctionBidder plays in the auction process

  `AuctionBidder` is a helper contract that acts as the auction solver/bid executor.

  Its role in the process is:

  1. It connects to one auction contract through `IBaseAuction`.
  2. A trusted address with `AUCTION_BIDDER_ROLE` calls its `bid` function.
  3. `AuctionBidder` either:
    - does a simple bid by approving the needed `assetOut`, or
    - runs a custom solution path using callback logic and multicalls
  4. The auction contract sends the auctioned asset to `AuctionBidder`.
  5. `AuctionBidder` makes sure the auction contract can pull the required `assetOut`.
  6. Any leftover `assetOut` can be forwarded to a configured receiver.

  So, `AuctionBidder` is not the auction itself. It is a controlled execution contract that helps a solver participate in the auction, perform any extra on-chain steps needed to source funds, and settle the payment side correctly.

  In plain English:

  - `BaseAuction` decides the price and sells the asset
  - `AuctionBidder` is the tool that actually carries out the bid
  - it is especially useful when bidding needs multiple steps, not just a simple token transfer
