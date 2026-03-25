// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IGPV2CompatibleAuction} from "src/interfaces/IGPV2CompatibleAuction.sol";
import {IGPV2Settlement} from "src/interfaces/IGPV2Settlement.sol";

import {BaseAuction} from "src/BaseAuction.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Roles} from "src/libraries/Roles.sol";

import {GPv2Order} from "@cowprotocol/libraries/GPv2Order.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GPV2 Compatible Auction v1.0.0 Contract.
/// @notice This contract extends the BaseAuction contract to provide compatibility with CowProtocol settlement contract
/// via EIP-1271 signed orders.
contract GPV2CompatibleAuction is BaseAuction, IERC1271, IGPV2CompatibleAuction {
  using SafeERC20 for IERC20;

  /// @notice This event is emitted when the CowSwap vault relayer address is set.
  /// @param cowSwapVaultRelayer The address of the CowSwap vault relayer.
  event GPV2VaultRelayerSet(address indexed cowSwapVaultRelayer);
  /// @notice This event is emitted when the GPv2Settlement contract address is set.
  /// @param gpV2Settlement The address of the GPv2Settlement contract.
  event GPV2SettlementSet(address indexed gpV2Settlement);

  /// @notice This error is thrown when the CowProtocol order ID does not match the order details.
  /// @param orderId The CowProtocol order ID.
  error InvalidOrderId(bytes32 orderId);
  /// @notice This error is thrown when the verified CowProtocol order's buy token is not the configured asset out.
  /// @param buyToken The CowProtocol order's buy token.
  /// @param assetOut The address of the configured asset out.
  error InvalidBuyToken(address buyToken, address assetOut);
  /// @notice This error is thrown when the verified CowProtocol order's receiver is not the configured asset out
  /// receiver.
  /// @param receiver The CowProtocol order's receiver.
  /// @param assetOutReceiver The address of the configured asset out receiver.
  error InvalidReceiver(address receiver, address assetOutReceiver);
  /// @notice This error is thrown when there are insufficient assets in balance to settle the CowProtocol order.
  /// @param assetIn The CowProtocol order's sell token.
  /// @param amountIn The requested amount (sell token).
  /// @param assetInBalance The available balance of the asset.
  error InsufficientAssetInBalance(address assetIn, uint256 amountIn, uint256 assetInBalance);
  /// @notice This error is thrown when the CowProtocol order's buy amount is lower than the current auction price.
  /// @param amountOut The requested amount of asset out (buy amount).
  /// @param minAmountOut The minimum required amount of asset out.
  error InsufficientBuyAmount(uint256 amountOut, uint256 minAmountOut);
  /// @notice This error is thrown when the CowProtocol order is expired.
  /// @param validTo The order's valid to timestamp.
  /// @param currentTime The current block timestamp.
  error ExpiredOrder(uint32 validTo, uint256 currentTime);
  /// @notice This error is thrown when the CowProtocol order fee amount is non-zero.
  error InvalidFeeAmount();
  /// @notice This error is thrown when the CowProtocol order kind is not a sell order.
  /// @param orderKind The order kind.
  error InvalidOrderKind(bytes32 orderKind);
  /// @notice This error is thrown when the CowProtocol order is not partially fillable.
  error OrderNotPartiallyFillable();
  /// @notice This error is thrown when the CowProtocol order does not use direct ERC20 balances.
  error InvalidTokenBalanceMarker();

  //?partial fill
  /// @notice The CowSwap vault relayer address.
  address private immutable i_gpV2VaultRelayer;
  /// @notice The GPv2Settlement contract address.
  IGPV2Settlement private immutable i_gpV2Settlement;

  constructor(
    BaseAuction.ConstructorParams memory params,
    address gpV2VaultRelayer,
    address gpV2Settlement
  ) BaseAuction(params) {
    if (gpV2VaultRelayer == address(0) || gpV2Settlement == address(0)) {
      revert Errors.InvalidZeroAddress();
    }

    i_gpV2VaultRelayer = gpV2VaultRelayer;
    i_gpV2Settlement = IGPV2Settlement(gpV2Settlement);

    emit GPV2VaultRelayerSet(gpV2VaultRelayer);
    emit GPV2SettlementSet(gpV2Settlement);
  }

  /// @inheritdoc BaseAuction
  function _onAuctionStart(
    address asset
  ) internal override {
    super._onAuctionStart(asset);

    // Approve the CowSwap vault relayer to transfer the auctioned asset.
    IERC20(asset).forceApprove(i_gpV2VaultRelayer, IERC20(asset).balanceOf(address(this)));
  }

  /// @inheritdoc BaseAuction
  function _onAuctionEnd(
    address asset,
    bool hasFeeAggregator
  ) internal override {
    super._onAuctionEnd(asset, hasFeeAggregator);

    /// Revoke the CowSwap vault relayer's allowance to transfer the auctioned asset.
    IERC20(asset).forceApprove(i_gpV2VaultRelayer, 0);
  }

  /// @inheritdoc IERC1271
  /// @dev precondition - The function must not be reentered from the bid() function.
  /// @dev precondition - The order ID must match the provided hash.
  /// @dev precondition - The signature must decode to a valid GPv2Order.Data struct.
  /// @dev precondition - The order's sell token must be a valid auction.
  /// @dev precondition - The order's buy token must be the configured asset out.
  /// @dev precondition - The order's receiver must be the auction contract.
  /// @dev precondition - The contract must have sufficient approved balance of the order's sell token to cover the sell
  /// amount.
  /// @dev precondition - The order's buy amount must be greater than or equal to the current auction price.
  /// @dev precondition - The order must not be expired.
  /// @dev precondition - The order kind must be a sell order.
  /// @dev precondition - The order must be partially fillable.
  function isValidSignature(
    bytes32 hash,
    bytes memory signature
  ) external view whenNotPaused returns (bytes4 magicValue) {
    GPv2Order.Data memory order = abi.decode(signature, (GPv2Order.Data));

    //@audit[#2] this function dosen't require minBidUsdValue
    if (s_entered) {
      revert Errors.ReentrantCall();
    }
    if (hash != GPv2Order.hash(order, i_gpV2Settlement.domainSeparator())) {
      revert InvalidOrderId(hash);
    }
    uint256 auctionStart = s_auctionStarts[address(order.sellToken)];
    if (auctionStart == 0) {
      revert InvalidAuction(address(order.sellToken));
    }
    if (address(order.buyToken) != s_assetOut) {
      revert InvalidBuyToken(address(order.buyToken), s_assetOut);
    }
    if (order.receiver != address(this)) {
      revert InvalidReceiver(order.receiver, address(this));
    }
    if (order.sellAmount == 0) {
      revert Errors.InvalidZeroAmount();
    }
    uint256 assetInBalance = order.sellToken.balanceOf(address(this));
    if (order.sellAmount > assetInBalance) {
      revert InsufficientAssetInBalance(address(order.sellToken), order.sellAmount, assetInBalance);
    }
    uint256 elapsedTime = block.timestamp - auctionStart;
    AssetParams memory assetParams = s_assetParams[address(order.sellToken)];
    if (elapsedTime > assetParams.auctionDuration) {
      revert InvalidAuction(address(order.sellToken));
    }

    //@follow
    (uint256 sellTokenUsdPrice,,) = _getAssetPrice(address(order.sellToken), true);
    uint256 minBuyAmount = _getAssetOutAmount(assetParams, sellTokenUsdPrice, order.sellAmount, elapsedTime, true);
    if (order.buyAmount < minBuyAmount) {
      revert InsufficientBuyAmount(order.buyAmount, minBuyAmount);
    }

    if (order.validTo < block.timestamp) {
      revert ExpiredOrder(order.validTo, block.timestamp);
    }
    // Non zero fee amounts are not supported in this auction implementation.
    if (order.feeAmount > 0) {
      revert InvalidFeeAmount();
    }
    if (order.kind != GPv2Order.KIND_SELL) {
      revert InvalidOrderKind(order.kind);
    }
    if (!order.partiallyFillable) {
      revert OrderNotPartiallyFillable();
    }
    if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20) {
      revert InvalidTokenBalanceMarker();
    }

    return IERC1271.isValidSignature.selector;
  }

  /// @inheritdoc IGPV2CompatibleAuction
  /// @dev precondition - the caller must have the ORDER_MANAGER_ROLE.
  function invalidateOrders(
    bytes[] calldata orderUids
  ) external onlyRole(Roles.ORDER_MANAGER_ROLE) {
    for (uint256 i = 0; i < orderUids.length; i++) {
      i_gpV2Settlement.invalidateOrder(orderUids[i]);
    }
  }

  /// @notice Getter function to retrieve the CowSwap vault relayer address.
  function getGPV2VaultRelayer() external view returns (address) {
    return i_gpV2VaultRelayer;
  }

  /// @notice Getter function to retrieve the GPv2Settlement contract address.
  function getGPV2Settlement() external view returns (IGPV2Settlement) {
    return i_gpV2Settlement;
  }
}
