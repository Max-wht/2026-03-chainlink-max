// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// CONTRACTS IN SCOPE:
//   - src/AuctionBidder.sol       (103 nSLOC) - Bidding on auctions and executing arbitrary solve logic
//   - src/BaseAuction.sol         (420 nSLOC) - Core dutch auction logic with linear price decay
//   - src/Caller.sol              (33 nSLOC)  - Multi-call utility for executing batched calls
//   - src/GPV2CompatibleAuction.sol (104 nSLOC) - CowSwap GPv2-compatible auction with EIP-1271
//   - src/PriceManager.sol        (227 nSLOC) - Data Streams & Chainlink price feed management
//   - src/WorkflowRouter.sol      (125 nSLOC) - CRE workflow routing for price/auction/bidder ops
//   - src/interfaces/IAuctionCallback.sol (3 nSLOC)
//   - src/interfaces/IBaseAuction.sol (3 nSLOC)
//   - src/interfaces/IGPV2CompatibleAuction.sol - CowSwap order invalidation interface
//   - src/interfaces/IGPV2Settlement.sol (6 nSLOC)
//   - src/interfaces/IPriceManager.sol (3 nSLOC)
//   - src/libraries/Errors.sol    (15 nSLOC)
//   - src/libraries/Roles.sol     (15 nSLOC)
//
// CONTRACTS OUT OF SCOPE (deployed as dependencies only):
//   - src/FeeAggregator.sol
//   - src/PausableWithAccessControl.sol
//   - src/EmergencyWithdrawer.sol
//   - src/LinkReceiver.sol
//   - src/NativeTokenReceiver.sol
//
// ============================================================================================== //

// ─── Source contracts
// ────────────────────────────────────────────────────────
import {AuctionBidder} from "src/AuctionBidder.sol";
import {BaseAuction} from "src/BaseAuction.sol";
import {Caller} from "src/Caller.sol";
import {FeeAggregator} from "src/FeeAggregator.sol";
import {GPV2CompatibleAuction} from "src/GPV2CompatibleAuction.sol";
import {PriceManager} from "src/PriceManager.sol";
import {WorkflowRouter} from "src/WorkflowRouter.sol";
import {Common} from "src/libraries/Common.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Roles} from "src/libraries/Roles.sol";

// ─── Interfaces
// ──────────────────────────────────────────────────────────────
import {IAuctionCallback} from "src/interfaces/IAuctionCallback.sol";
import {IBaseAuction} from "src/interfaces/IBaseAuction.sol";
import {IGPV2CompatibleAuction} from "src/interfaces/IGPV2CompatibleAuction.sol";
import {IGPV2Settlement} from "src/interfaces/IGPV2Settlement.sol";
import {IPriceManager} from "src/interfaces/IPriceManager.sol";

// ─── Mock contracts
// ──────────────────────────────────────────────────────────
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockGPV2Settlement} from "test/mocks/MockGPV2Settlement.sol";
import {MockLinkToken} from "test/mocks/MockLinkToken.sol";
import {MockUniswapQuoterV2} from "test/mocks/MockUniswapQuoterV2.sol";
import {MockUniswapRouter} from "test/mocks/MockUniswapRouter.sol";
import {MockVerifierProxy} from "test/mocks/MockVerifierProxy.sol";
import {MockWrappedNative} from "test/mocks/MockWrappedNative.sol";

// ─── External dependencies
// ───────────────────────────────────────────────────
import {IVerifierProxy} from "@chainlink/contracts/src/v0.8/llo-feeds/v0.5.0/interfaces/IVerifierProxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// ─── Forge
// ───────────────────────────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @title C4PoC - Code4rena Proof of Concept Testbed for Chainlink Payment Abstraction V2
/// @notice This contract deploys the full in-scope system with mock dependencies and exposes
///         helpers for wardens to write Proof-of-Concept exploits.
///
/// @dev INSTRUCTIONS FOR WARDENS:
///      1. Write your exploit code inside the `testSubmissionValidity()` function.
///      2. You have access to all deployed contracts and actors listed below.
///      3. Use the helper functions provided to set up auction state quickly.
///      4. Run your PoC with: `forge test --match-test testSubmissionValidity -vvv`
///
/// @dev DEPLOYED CONTRACTS (accessible as state variables):
///      - `auction`          : GPV2CompatibleAuction  (the main auction contract in scope)
///      - `auctionBidder`    : AuctionBidder          (the bidder contract in scope)
///      - `workflowRouter`   : WorkflowRouter         (the workflow router in scope)
///      - `feeAggregator`    : FeeAggregator          (out of scope, deployed as dependency)
///      - `mockGPV2Settlement` : MockGPV2Settlement    (mock CowSwap settlement)
///
/// @dev MOCK TOKENS:
///      - `mockWETH` : MockWrappedNative (18 decimals, price $4,000)
///      - `mockLINK` : MockLinkToken     (18 decimals, price $20) — also the assetOut
///      - `mockUSDC` : MockERC20         (6 decimals, price $1)
///      - `mockWBTC` : MockERC20         (8 decimals, no feed configured)
///
/// @dev ACTOR ADDRESSES (use with `vm.prank()` or `_changePrank()`):
///      - `owner`          : DEFAULT_ADMIN_ROLE on all contracts
///      - `pauser`         : PAUSER_ROLE
///      - `unpauser`       : UNPAUSER_ROLE
///      - `assetAdmin`     : ASSET_ADMIN_ROLE on auction & feeAggregator
///      - `priceAdmin`     : PRICE_ADMIN_ROLE on auction
///      - `auctionAdmin`   : AUCTION_WORKER_ROLE on auction
///      - `bidder`         : AUCTION_BIDDER_ROLE on auctionBidder
///      - `forwarder`      : FORWARDER_ROLE on auction & workflowRouter
///      - `attacker`       : Unprivileged address for exploit scenarios
///      - `reserves`       : Receives assetOut (LINK) after auction settlement
///      - `orderManager`   : ORDER_MANAGER_ROLE on auction (can invalidate CowSwap orders)
///
contract C4PoC is Test {
  // ═══════════════════════════════════════════════════════════════════════════
  //                              CONSTANTS
  // ═══════════════════════════════════════════════════════════════════════════

  bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
  uint48 internal constant DEFAULT_ADMIN_TRANSFER_DELAY = 0;
  uint88 internal constant MIN_BID_USD_VALUE = 100e18; // $100
  uint64 internal constant MIN_PRICE_MULTIPLIER = 0.98e18; // 2% max discount
  uint96 internal constant MIN_AUCTION_SIZE_USD = 1_000e18; // $1,000

  bytes32 internal constant PRICE_ADMIN_WORKFLOW_ID = keccak256("priceAdminWorkflowId");
  bytes32 internal constant AUCTION_WORKER_WORKFLOW_ID = keccak256("auctionWorkerWorkflowId");
  bytes32 internal constant AUCTION_BIDDER_WORKFLOW_ID = keccak256("auctionBidderWorkflowId");

  // ═══════════════════════════════════════════════════════════════════════════
  //                          IN-SCOPE CONTRACTS
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice The main GPV2-compatible auction contract (in scope).
  GPV2CompatibleAuction public auction;

  /// @notice The auction bidder contract (in scope).
  AuctionBidder public auctionBidder;

  /// @notice The workflow router contract (in scope).
  WorkflowRouter public workflowRouter;

  // ═══════════════════════════════════════════════════════════════════════════
  //                       OUT-OF-SCOPE DEPENDENCIES
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice The fee aggregator (out of scope, deployed as dependency).
  FeeAggregator public feeAggregator;

  // ═══════════════════════════════════════════════════════════════════════════
  //                            MOCK CONTRACTS
  // ═══════════════════════════════════════════════════════════════════════════

  MockWrappedNative public mockWETH;
  MockLinkToken public mockLINK;
  MockERC20 public mockUSDC;
  MockERC20 public mockWBTC;

  MockAggregatorV3 public mockLinkUsdFeed;
  MockAggregatorV3 public mockWethUsdFeed;
  MockAggregatorV3 public mockUsdcUsdFeed;

  MockUniswapRouter public mockUniswapRouter;
  MockUniswapQuoterV2 public mockUniswapQuoterV2;

  MockVerifierProxy public mockStreamsVerifierProxy;
  MockGPV2Settlement public mockGPV2Settlement;

  // ═══════════════════════════════════════════════════════════════════════════
  //                              ACTORS
  // ═══════════════════════════════════════════════════════════════════════════

  address public owner;
  address public pauser;
  address public unpauser;
  address public assetAdmin;
  address public priceAdmin;
  address public auctionAdmin;
  address public bidder;
  address public forwarder;
  address public attacker;
  address public reserves;
  address public orderManager;
  address public gpV2VaultRelayer;

  // ═══════════════════════════════════════════════════════════════════════════
  //                          FEED IDS
  // ═══════════════════════════════════════════════════════════════════════════

  bytes32 internal immutable i_mockWETHFeedId = _generateDataStreamsFeedId("MockWETH");
  bytes32 internal immutable i_mockUSDCFeedId = _generateDataStreamsFeedId("MockUSDC");
  bytes32 internal immutable i_mockLINKFeedId = _generateDataStreamsFeedId("MockLINK");

  // ═══════════════════════════════════════════════════════════════════════════
  //                              SETUP
  // ═══════════════════════════════════════════════════════════════════════════

  function setUp() public {
    // ── Create actor addresses
    // ───────────────────────────────────────────
    owner = makeAddr("owner");
    pauser = makeAddr("pauser");
    unpauser = makeAddr("unpauser");
    assetAdmin = makeAddr("assetAdmin");
    priceAdmin = makeAddr("priceAdmin");
    auctionAdmin = makeAddr("auctionAdmin");
    bidder = makeAddr("auctionBidder");
    forwarder = makeAddr("forwarder");
    attacker = makeAddr("attacker");
    reserves = makeAddr("Reserves");
    orderManager = makeAddr("orderManager");
    gpV2VaultRelayer = makeAddr("GPV2VaultRelayer");

    vm.startPrank(owner);

    // Advance block.timestamp to avoid underflows
    skip(1 weeks);

    // ── Deploy mock tokens
    // ───────────────────────────────────────────────
    mockWETH = new MockWrappedNative();
    mockLINK = new MockLinkToken();
    mockUSDC = new MockERC20("USDC", "USDC", 6);
    mockWBTC = new MockERC20("WBTC", "WBTC", 8);

    // ── Deploy mock price feeds
    // ──────────────────────────────────────────
    mockLinkUsdFeed = new MockAggregatorV3();
    mockWethUsdFeed = new MockAggregatorV3();
    mockUsdcUsdFeed = new MockAggregatorV3();

    // Set initial prices (8 decimals, matching Chainlink convention)
    mockLinkUsdFeed.transmit(20e8); // $20 per LINK
    mockWethUsdFeed.transmit(4_000e8); // $4,000 per WETH
    mockUsdcUsdFeed.transmit(1e8); // $1 per USDC

    // ── Deploy mock Uniswap
    // ──────────────────────────────────────────────
    mockUniswapRouter = new MockUniswapRouter(address(mockLINK));
    mockUniswapQuoterV2 = new MockUniswapQuoterV2();

    // ── Deploy FeeAggregator (out of scope, needed as dependency) ────────
    feeAggregator = new FeeAggregator(
      FeeAggregator.ConstructorParams({
        adminRoleTransferDelay: DEFAULT_ADMIN_TRANSFER_DELAY,
        admin: owner,
        linkToken: address(mockLINK),
        ccipRouterClient: makeAddr("mockCCIPRouterClient"),
        wrappedNativeToken: address(mockWETH)
      })
    );

    // ── Deploy MockVerifierProxy & MockGPV2Settlement ────────────────────
    mockStreamsVerifierProxy = new MockVerifierProxy();
    mockGPV2Settlement = new MockGPV2Settlement();

    // ── Deploy GPV2CompatibleAuction (IN SCOPE)
    // ──────────────────────────
    PriceManager.ApplyFeedInfoUpdateParams[] memory feedInfos = new PriceManager.ApplyFeedInfoUpdateParams[](3);
    feedInfos[0] = PriceManager.ApplyFeedInfoUpdateParams({
      asset: address(mockWETH),
      feedInfo: PriceManager.FeedInfo({
        dataStreamsFeedId: i_mockWETHFeedId,
        usdDataFeed: AggregatorV3Interface(mockWethUsdFeed),
        dataStreamsFeedDecimals: 18,
        stalenessThreshold: 1 hours
      })
    });
    feedInfos[1] = PriceManager.ApplyFeedInfoUpdateParams({
      asset: address(mockUSDC),
      feedInfo: PriceManager.FeedInfo({
        dataStreamsFeedId: i_mockUSDCFeedId,
        usdDataFeed: AggregatorV3Interface(mockUsdcUsdFeed),
        dataStreamsFeedDecimals: 18,
        stalenessThreshold: 1 hours
      })
    });
    feedInfos[2] = PriceManager.ApplyFeedInfoUpdateParams({
      asset: address(mockLINK),
      feedInfo: PriceManager.FeedInfo({
        dataStreamsFeedId: i_mockLINKFeedId,
        usdDataFeed: AggregatorV3Interface(mockLinkUsdFeed),
        dataStreamsFeedDecimals: 18,
        stalenessThreshold: 1 hours
      })
    });

    GPV2CompatibleAuction.ConstructorParams memory auctionParams = BaseAuction.ConstructorParams({
      adminRoleTransferDelay: DEFAULT_ADMIN_TRANSFER_DELAY,
      admin: owner,
      minPriceMultiplier: MIN_PRICE_MULTIPLIER,
      verifierProxy: address(mockStreamsVerifierProxy),
      minBidUsdValue: MIN_BID_USD_VALUE,
      linkToken: address(mockLINK),
      assetOut: address(mockLINK),
      assetOutReceiver: reserves,
      feeAggregator: address(feeAggregator),
      feedInfos: feedInfos
    });

    auction = new GPV2CompatibleAuction(auctionParams, gpV2VaultRelayer, address(mockGPV2Settlement));

    // ── Deploy AuctionBidder (IN SCOPE)
    // ──────────────────────────────────
    auctionBidder = new AuctionBidder(DEFAULT_ADMIN_TRANSFER_DELAY, owner, address(auction), reserves);

    // ── Deploy WorkflowRouter (IN SCOPE)
    // ────────────────────────────────
    workflowRouter = new WorkflowRouter(DEFAULT_ADMIN_TRANSFER_DELAY, owner);

    // ── Grant roles
    // ──────────────────────────────────────────────────────

    // FeeAggregator roles
    feeAggregator.grantRole(Roles.ASSET_ADMIN_ROLE, assetAdmin);
    feeAggregator.grantRole(Roles.SWAPPER_ROLE, address(auction));

    // Auction roles
    auction.grantRole(Roles.PAUSER_ROLE, pauser);
    auction.grantRole(Roles.UNPAUSER_ROLE, unpauser);
    auction.grantRole(Roles.ASSET_ADMIN_ROLE, assetAdmin);
    auction.grantRole(Roles.FORWARDER_ROLE, forwarder);
    auction.grantRole(Roles.AUCTION_WORKER_ROLE, auctionAdmin);
    auction.grantRole(Roles.AUCTION_WORKER_ROLE, address(workflowRouter));
    auction.grantRole(Roles.PRICE_ADMIN_ROLE, priceAdmin);
    auction.grantRole(Roles.PRICE_ADMIN_ROLE, address(workflowRouter));
    auction.grantRole(Roles.ORDER_MANAGER_ROLE, orderManager);
    auction.grantRole(Roles.ORDER_MANAGER_ROLE, address(workflowRouter));

    // AuctionBidder roles
    auctionBidder.grantRole(Roles.PAUSER_ROLE, pauser);
    auctionBidder.grantRole(Roles.AUCTION_BIDDER_ROLE, bidder);
    auctionBidder.grantRole(Roles.AUCTION_BIDDER_ROLE, address(workflowRouter));

    // WorkflowRouter roles
    workflowRouter.grantRole(Roles.PAUSER_ROLE, pauser);
    workflowRouter.grantRole(Roles.FORWARDER_ROLE, forwarder);

    // ── Configure workflow allowlists on the WorkflowRouter ──────────────
    {
      WorkflowRouter.AllowlistedWorkflow[] memory adds = new WorkflowRouter.AllowlistedWorkflow[](3);

      // PRICE_ADMIN workflow → auction.transmit
      adds[0].workflowId = PRICE_ADMIN_WORKFLOW_ID;
      adds[0].targetSelectors = new WorkflowRouter.TargetSelectors[](1);
      adds[0].targetSelectors[0].target = address(auction);
      adds[0].targetSelectors[0].selectors = new bytes4[](1);
      adds[0].targetSelectors[0].selectors[0] = auction.transmit.selector;

      // AUCTION_WORKER workflow → auction.performUpkeep, auction.invalidateOrders
      adds[1].workflowId = AUCTION_WORKER_WORKFLOW_ID;
      adds[1].targetSelectors = new WorkflowRouter.TargetSelectors[](1);
      adds[1].targetSelectors[0].target = address(auction);
      adds[1].targetSelectors[0].selectors = new bytes4[](2);
      adds[1].targetSelectors[0].selectors[0] = auction.performUpkeep.selector;
      adds[1].targetSelectors[0].selectors[1] = auction.invalidateOrders.selector;

      // AUCTION_BIDDER workflow → auctionBidder.bid
      adds[2].workflowId = AUCTION_BIDDER_WORKFLOW_ID;
      adds[2].targetSelectors = new WorkflowRouter.TargetSelectors[](1);
      adds[2].targetSelectors[0].target = address(auctionBidder);
      adds[2].targetSelectors[0].selectors = new bytes4[](1);
      adds[2].targetSelectors[0].selectors[0] = auctionBidder.bid.selector;

      workflowRouter.applyAllowlistedWorkflowsUpdates(new bytes32[](0), adds);
    }

    // ── Configure asset parameters on the auction
    // ────────────────────────
    _changePrank(assetAdmin);

    GPV2CompatibleAuction.ApplyAssetParamsUpdate[] memory assetParamsUpdates =
      new GPV2CompatibleAuction.ApplyAssetParamsUpdate[](3);

    // WETH: +10% starting premium -> -2% ending discount, 1 day duration
    assetParamsUpdates[0] = BaseAuction.ApplyAssetParamsUpdate({
      asset: address(mockWETH),
      params: BaseAuction.AssetParams({
        decimals: 18,
        auctionDuration: 1 days,
        startingPriceMultiplier: 1.1e18,
        endingPriceMultiplier: 0.98e18,
        minAuctionSizeUsd: MIN_AUCTION_SIZE_USD
      })
    });

    // USDC: +5% starting premium -> -1% ending discount, 1 day duration
    assetParamsUpdates[1] = BaseAuction.ApplyAssetParamsUpdate({
      asset: address(mockUSDC),
      params: BaseAuction.AssetParams({
        decimals: 6,
        auctionDuration: 1 days,
        startingPriceMultiplier: 1.05e18,
        endingPriceMultiplier: 0.99e18,
        minAuctionSizeUsd: MIN_AUCTION_SIZE_USD
      })
    });

    // LINK (assetOut params — needed for min auction size checks)
    assetParamsUpdates[2] = BaseAuction.ApplyAssetParamsUpdate({
      asset: address(mockLINK),
      params: BaseAuction.AssetParams({
        decimals: 18,
        auctionDuration: 1,
        startingPriceMultiplier: 1e18,
        endingPriceMultiplier: 1e18,
        minAuctionSizeUsd: MIN_AUCTION_SIZE_USD
      })
    });

    auction.applyAssetParamsUpdates(assetParamsUpdates, new address[](0));

    // ── Allowlist assets on fee aggregator
    // ───────────────────────────────
    address[] memory allowlistedAssets = new address[](3);
    allowlistedAssets[0] = address(mockWETH);
    allowlistedAssets[1] = address(mockUSDC);
    allowlistedAssets[2] = address(mockLINK);
    feeAggregator.applyAllowlistedAssetUpdates(new address[](0), allowlistedAssets);

    // ── Transmit initial Data Streams prices
    // ─────────────────────────────
    _changePrank(priceAdmin);
    _transmitPrices(4_000e18, 1e18, 20e18);

    // ── Labels for trace readability
    // ─────────────────────────────────────
    vm.label(address(feeAggregator), "FeeAggregator");
    vm.label(address(auction), "GPV2CompatibleAuction");
    vm.label(address(auctionBidder), "AuctionBidder");
    vm.label(address(workflowRouter), "WorkflowRouter");
    vm.label(address(mockLINK), "MockLINK");
    vm.label(address(mockWETH), "MockWETH");
    vm.label(address(mockUSDC), "MockUSDC");
    vm.label(address(mockWBTC), "MockWBTC");
    vm.label(address(mockGPV2Settlement), "MockGPV2Settlement");
    vm.label(address(mockStreamsVerifierProxy), "MockVerifierProxy");
    vm.label(address(mockUniswapRouter), "MockUniswapRouter");
    vm.label(owner, "Owner");
    vm.label(pauser, "Pauser");
    vm.label(unpauser, "Unpauser");
    vm.label(assetAdmin, "AssetAdmin");
    vm.label(priceAdmin, "PriceAdmin");
    vm.label(auctionAdmin, "AuctionAdmin");
    vm.label(bidder, "Bidder");
    vm.label(forwarder, "Forwarder");
    vm.label(attacker, "Attacker");
    vm.label(reserves, "Reserves");
    vm.label(orderManager, "OrderManager");
    vm.label(gpV2VaultRelayer, "GPV2VaultRelayer");

    vm.stopPrank();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //                    WARDEN SUBMISSION ENTRY POINT
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice **WARDENS: Place your Proof-of-Concept exploit code here.**
  ///
  /// @dev This function is the single entry point for your PoC submission.
  ///      The full system is already deployed and configured in `setUp()`.
  ///
  ///      Available state after setUp():
  ///        - All in-scope contracts deployed with proper roles & configurations
  ///        - Data Streams prices transmitted: WETH=$4,000, USDC=$1, LINK=$20
  ///        - Asset parameters configured for WETH, USDC, LINK
  ///        - Assets allowlisted on FeeAggregator
  ///        - No auctions are live yet (use helpers to start one)
  ///
  ///      Useful helpers (see full docs below):
  ///        - `_startAuction(asset, amount)`   : Fund feeAggregator, checkUpkeep, performUpkeep
  ///        - `_startAuctionAndSkip(asset, amount, bps)` : Start auction + skip time + refresh prices
  ///        - `_transmitPrices(weth, usdc, link)` : Transmit Data Streams prices
  ///        - `_refreshPrices()`               : Re-transmit default prices (call after any skip > 1h)
  ///        - `_fundBidder(linkAmount)`         : Give LINK to AuctionBidder
  ///        - `_bid(asset, amount)`             : Execute a bid via AuctionBidder (no solution)
  ///        - `_bidWithSolution(asset, amount, calls)` : Bid with arbitrary callback solution
  ///        - `_changePrank(addr)`              : Switch msg.sender
  ///
  ///      Run with:
  ///        forge test --match-test testSubmissionValidity -vvv
  ///
  function testSubmissionValidity() public {
    // ╔═══════════════════════════════════════════════════════════════════╗
    // ║                                                                 ║
    // ║   WARDENS: Write your Proof-of-Concept code below this line.    ║
    // ║                                                                 ║
    // ║   Demonstrate the vulnerability by showing the impact.          ║
    // ║   Use assert/revert checks to prove your finding.               ║
    // ║                                                                 ║
    // ╚═══════════════════════════════════════════════════════════════════╝

    // Example: Start a USDC auction and bid on it
    //
    // _startAuction(address(mockUSDC), 100_000e6);         // Start $100k USDC auction
    // skip(auction.getAssetParams(address(mockUSDC)).auctionDuration / 2); // Wait half the auction
    // _refreshPrices();                                     // Re-transmit prices (staleness = 1h, auction = 1d)
    // _fundBidder(10_000e18);                               // Fund bidder with enough LINK
    // _bid(address(mockUSDC), 100_000e6);                   // Bid on full amount
    //
    // NOTE: After any `skip()` exceeding 1 hour you MUST call `_refreshPrices()`
    //       (or `_transmitPrices(...)`) before bidding, otherwise the price feeds
    //       are stale and the bid will revert with `Errors.StaleFeedData()`.
    //       The `_startAuctionAndSkip()` helper does this automatically.
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //                          HELPER FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Transmit Data Streams prices for WETH, USDC, and LINK.
  /// @dev Automatically switches to priceAdmin and restores the previous caller.
  /// @param wethPrice WETH price in 18 decimals (e.g., 4_000e18 for $4,000).
  /// @param usdcPrice USDC price in 18 decimals (e.g., 1e18 for $1).
  /// @param linkPrice LINK price in 18 decimals (e.g., 20e18 for $20).
  function _transmitPrices(
    uint256 wethPrice,
    uint256 usdcPrice,
    uint256 linkPrice
  ) internal {
    (, address currentCaller,) = vm.readCallers();

    bytes[] memory unverifiedReports = new bytes[](3);

    bytes32[3] memory context = [bytes32(0), bytes32(0), bytes32(0)];
    bytes32[] memory rs = new bytes32[](2);
    bytes32[] memory ss = new bytes32[](2);
    bytes32 rawVs;

    // WETH report
    PriceManager.ReportV3 memory wethReport;
    wethReport.dataStreamsFeedId = i_mockWETHFeedId;
    wethReport.price = int192(uint192(wethPrice));
    wethReport.observationsTimestamp = uint32(block.timestamp);
    unverifiedReports[0] = abi.encode(context, abi.encode(wethReport), rs, ss, rawVs);

    // USDC report
    PriceManager.ReportV3 memory usdcReport;
    usdcReport.dataStreamsFeedId = i_mockUSDCFeedId;
    usdcReport.price = int192(uint192(usdcPrice));
    usdcReport.observationsTimestamp = uint32(block.timestamp);
    unverifiedReports[1] = abi.encode(context, abi.encode(usdcReport), rs, ss, rawVs);

    // LINK report
    PriceManager.ReportV3 memory linkReport;
    linkReport.dataStreamsFeedId = i_mockLINKFeedId;
    linkReport.price = int192(uint192(linkPrice));
    linkReport.observationsTimestamp = uint32(block.timestamp);
    unverifiedReports[2] = abi.encode(context, abi.encode(linkReport), rs, ss, rawVs);

    _changePrank(priceAdmin);
    auction.transmit(unverifiedReports);
    _changePrank(currentCaller);
  }

  /// @notice Start an auction for a given asset by funding the FeeAggregator, running
  ///         checkUpkeep and performUpkeep.
  /// @dev Automatically handles prank switching and price freshness.
  /// @param asset The token address to auction (e.g., address(mockUSDC)).
  /// @param amount The amount of `asset` to deposit into the FeeAggregator for auctioning.
  function _startAuction(
    address asset,
    uint256 amount
  ) internal {
    (, address currentCaller,) = vm.readCallers();

    // Fund the fee aggregator so there is something to auction
    deal(asset, address(feeAggregator), amount);

    // Run checkUpkeep/performUpkeep as the auction admin
    _changePrank(auctionAdmin);
    (, bytes memory performData) = auction.checkUpkeep("");
    auction.performUpkeep(performData);

    _changePrank(currentCaller);
  }

  /// @notice Fund the AuctionBidder contract with LINK tokens for bidding.
  /// @param linkAmount The amount of LINK (18 decimals) to give to the AuctionBidder.
  function _fundBidder(
    uint256 linkAmount
  ) internal {
    deal(address(mockLINK), address(auctionBidder), linkAmount);
  }

  /// @notice Execute a simple bid (no callback solution) via the AuctionBidder.
  /// @dev Switches to the `bidder` address, approves LINK, and calls bid.
  /// @param asset The auctioned asset to bid on.
  /// @param amount The amount of `asset` to bid for.
  function _bid(
    address asset,
    uint256 amount
  ) internal {
    (, address currentCaller,) = vm.readCallers();
    _changePrank(bidder);
    Caller.Call[] memory emptySolution = new Caller.Call[](0);
    auctionBidder.bid(asset, amount, emptySolution);
    _changePrank(currentCaller);
  }

  /// @notice Execute a bid with an arbitrary callback solution via the AuctionBidder.
  /// @dev The solution calls are executed inside `auctionCallback` after the auction
  ///      transfers the auctioned asset to the bidder.
  /// @param asset The auctioned asset to bid on.
  /// @param amount The amount of `asset` to bid for.
  /// @param solution Array of calls to execute in the callback.
  function _bidWithSolution(
    address asset,
    uint256 amount,
    Caller.Call[] memory solution
  ) internal {
    (, address currentCaller,) = vm.readCallers();
    _changePrank(bidder);
    auctionBidder.bid(asset, amount, solution);
    _changePrank(currentCaller);
  }

  /// @notice Convenience wrapper to start an auction and advance time by a fraction of the
  ///         auction duration, then automatically refresh prices to avoid staleness.
  /// @param asset The token to auction.
  /// @param amount The amount to auction.
  /// @param elapsedFractionBps Fraction of auction duration to skip, in basis points
  ///        (e.g., 5000 = 50% elapsed, 10000 = fully elapsed).
  function _startAuctionAndSkip(
    address asset,
    uint256 amount,
    uint256 elapsedFractionBps
  ) internal {
    _startAuction(asset, amount);
    uint24 duration = auction.getAssetParams(asset).auctionDuration;
    skip((uint256(duration) * elapsedFractionBps) / 10_000);
    // Re-transmit prices so they are fresh after the time skip.
    // Without this, any skip > 1 hour causes StaleFeedData reverts on bid().
    _refreshPrices();
  }

  /// @notice Get the current auction price for an asset at the current block.timestamp.
  /// @param asset The auctioned asset.
  /// @param amount The amount being bid.
  /// @return assetOutAmount The amount of assetOut (LINK) required to bid `amount` of `asset`.
  function _getAssetOutAmount(
    address asset,
    uint256 amount
  ) internal view returns (uint256) {
    return auction.getAssetOutAmount(asset, amount, block.timestamp);
  }

  /// @notice Deal sufficient asset balance to the FeeAggregator to meet minimum auction size.
  /// @param asset The asset to fund.
  function _dealMinAuctionSize(
    address asset
  ) internal {
    (uint256 assetPrice,,) = auction.getAssetPrice(asset);
    uint8 assetDecimals = IERC20Metadata(asset).decimals();
    uint256 minBalance = (MIN_AUCTION_SIZE_USD * 10 ** assetDecimals) / assetPrice;
    deal(asset, address(feeAggregator), minBalance);
  }

  /// @notice Re-transmit the default Data Streams prices at the current block.timestamp.
  /// @dev Call this after any `skip()` that exceeds the staleness threshold (1 hour) to
  ///      prevent `Errors.StaleFeedData()` reverts during bids or price queries.
  ///      Uses the standard default prices: WETH=$4,000, USDC=$1, LINK=$20.
  function _refreshPrices() internal {
    _transmitPrices(4_000e18, 1e18, 20e18);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //                          INTERNAL UTILITIES
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Switch the active prank to a new address.
  function _changePrank(
    address newCaller
  ) internal {
    vm.stopPrank();
    vm.startPrank(newCaller);
  }

  /// @notice Generate a Data Streams feed ID from a description string.
  function _generateDataStreamsFeedId(
    string memory description
  ) internal pure returns (bytes32) {
    return bytes32(bytes.concat(bytes2(0x0003), bytes30(keccak256(bytes(description)))));
  }
}
