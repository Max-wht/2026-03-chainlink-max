// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {IAuctionCallback} from "src/interfaces/IAuctionCallback.sol";
import {IBaseAuction} from "src/interfaces/IBaseAuction.sol";

import {Caller} from "src/Caller.sol";
import {PausableWithAccessControl} from "src/PausableWithAccessControl.sol";
import {Common} from "src/libraries/Common.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Roles} from "src/libraries/Roles.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

//@note: A Programable bidder instead of a EOA
/// @title Auction Bidder v1.0.0 Contract.
/// @notice This contract is responsible for bidding on auctions and executing arbitrary logic to solve the auction.
contract AuctionBidder is PausableWithAccessControl, Caller, IAuctionCallback, ITypeAndVersion {
  using SafeERC20 for IERC20;

  /// @notice This event is emitted when the auction contract is set.
  /// @param auction The address of the auction contract.
  event AuctionContractSet(address indexed auction);
  /// @notice This event is emitted when the receiver address is set.
  /// @param receiver The address of the receiver.
  event ReceiverSet(address indexed receiver);

  /// @notice This error is thrown when an invalid auction contract is provided.
  error InvalidAuctionContract(address auction);

  /// @inheritdoc ITypeAndVersion
  string public constant override typeAndVersion = "AuctionBidder 1.0.0-dev";

  /// @notice The auction contract.
  IBaseAuction private s_auction;

  /// @notice Optional receiver address. This address will receive any leftover funds after bidding.
  address private s_receiver;

  constructor(
    uint48 adminRoleTransferDelay,
    address admin,
    address auction,
    address receiver
  ) PausableWithAccessControl(adminRoleTransferDelay, admin) {
    _setAuction(auction);

    if (receiver != address(0)) {
      _setReceiver(receiver);
    }
  }

  // ================================================================================================
  // │                                    Auction Participation                                     │
  // ================================================================================================

  /// @notice Bids on the auction contract and optionally executes arbitrary pre-bid logic.
  /// @dev precondition - the contract must not be paused.
  /// @dev precondition - the caller must have the AUCTION_BIDDER_ROLE.
  /// @param assetIn The address of the asset to bid with.
  /// @param amount The amount of the asset to bid.
  /// @param solution The list of calls to execute to solve the bid.
  function bid(
    address assetIn,
    uint256 amount,
    Call[] calldata solution
  ) external whenNotPaused onlyRole(Roles.AUCTION_BIDDER_ROLE) {
    IBaseAuction auction = s_auction;
    address assetOut = auction.getAssetOut();

    bytes memory data;

    if (solution.length > 0) {
      data = abi.encode(solution);
    } else {
      IERC20(assetOut).forceApprove(address(auction), s_auction.getAssetOutAmount(assetIn, amount, block.timestamp));
    }

    auction.bid(assetIn, amount, data);

    uint256 assetOutBalance = IERC20(assetOut).balanceOf(address(this));

    if (assetOutBalance > 0) {
      address receiver = s_receiver;

      if (receiver != address(0)) {
        IERC20(assetOut).safeTransfer(receiver, assetOutBalance);
      }
    }
  }

  /// @inheritdoc IAuctionCallback
  /// @dev precondition - the contract must not be paused.
  /// @dev precondition - the caller must be the auction contract.
  function auctionCallback(
    address from,
    address assetOut,
    uint256 amountOut,
    bytes calldata data
  ) external whenNotPaused {
    if (msg.sender != address(s_auction) || from != address(this)) {
      revert Errors.AccessForbidden();
    }

    (Call[] memory calls) = abi.decode(data, (Call[]));

    _multiCall(calls);

    IERC20(assetOut).forceApprove(msg.sender, amountOut);
  }

  /// @notice Withdraws any tokens from the contract.
  /// @dev precondition - the caller must have the DEFAULT_ADMIN_ROLE.
  /// @dev precondition - the `to` address must not be the zero address.
  /// @param assetAmounts The asset and amounts to withdraw.
  /// @param to The address to send the withdrawn tokens to.
  function withdraw(
    Common.AssetAmount[] calldata assetAmounts,
    address to
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (to == address(0)) {
      revert Errors.InvalidZeroAddress();
    }

    for (uint256 i = 0; i < assetAmounts.length; ++i) {
      Common.AssetAmount memory assetAmount = assetAmounts[i];
      IERC20(assetAmount.asset).safeTransfer(to, assetAmount.amount);
    }
  }

  // ================================================================================================
  // │                                        Configuration                                         │
  // ================================================================================================

  /// @notice Sets the auction contract.
  /// @dev precondition - the caller must have the DEFAULT_ADMIN_ROLE.
  /// @param auction The address of the auction contract.
  function setAuction(
    address auction
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setAuction(auction);
  }

  /// @notice Internal function to set the auction contract.
  /// @dev precondition - the auction address must not be zero.
  /// @dev precondition - the auction contract must implement the IBaseAuction interface.
  /// @param auction The address of the auction contract.
  function _setAuction(
    address auction
  ) private {
    if (auction == address(0)) {
      revert Errors.InvalidZeroAddress();
    }
    if (!IERC165(auction).supportsInterface(type(IBaseAuction).interfaceId)) {
      revert InvalidAuctionContract(auction);
    }
    if (address(s_auction) == auction) {
      revert Errors.ValueNotUpdated();
    }

    s_auction = IBaseAuction(auction);

    emit AuctionContractSet(auction);
  }

  /// @notice Sets the receiver address.
  /// @dev precondition - the caller must have the DEFAULT_ADMIN_ROLE.
  /// @param receiver The address of the receiver.
  function setReceiver(
    address receiver
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setReceiver(receiver);
  }

  /// @notice Internal function to set the receiver address.
  /// @dev precondition - the receiver address must be different from the current one.
  /// @param receiver The address of the receiver.
  function _setReceiver(
    address receiver
  ) private {
    if (receiver == s_receiver) {
      revert Errors.ValueNotUpdated();
    }

    s_receiver = receiver;

    emit ReceiverSet(receiver);
  }

  // ================================================================================================
  // │                                           Getters                                            │
  // ================================================================================================

  /// @notice Getter function to retrieve the auction contract address.
  /// @return auction The address of the auction contract.
  function getAuction() external view returns (IBaseAuction auction) {
    return s_auction;
  }

  /// @notice Getter function to retrieve the receiver address.
  /// @return receiver The address of the receiver.
  function getReceiver() external view returns (address receiver) {
    return s_receiver;
  }

  /// @inheritdoc IERC165
  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override returns (bool) {
    return interfaceId == type(IAuctionCallback).interfaceId || super.supportsInterface(interfaceId);
  }
}
