// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {CherumFeeBase} from "./CherumFeeBase.sol";
import {CherumOrder} from "./CherumOrder.sol";

/// @dev Minimal Permit2 signature-transfer surface used by the routers.
interface IPermit2SignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}

/// @title CherumPermit2Base
/// @notice Shared Permit2 pull logic and the relayer (gasless) switch.
/// @dev    Both routers pull a single input token from the order's `account`
///         to themselves under one Permit2 witness, then distribute. Because
///         Permit2 binds the spender to this contract (its caller), the order
///         signature is valid only for this router, and whoever submits the
///         transaction cannot redirect funds or change fees. The relayer
///         switch only decides whether a third party may submit on the
///         account's behalf; it is set immediately by the owner.
abstract contract CherumPermit2Base is CherumFeeBase {
    using CherumOrder for CherumOrder.Order;

    IPermit2SignatureTransfer internal constant PERMIT2_SIG =
        IPermit2SignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @notice When false, only the order's `account` may submit. When true,
    ///         any caller may submit on the account's behalf (gasless).
    bool public relayerEnabled;

    event RelayerEnabledSet(bool enabled);

    error RelayingDisabled();
    error OrderExpired(uint256 deadline);

    constructor(address initialOwner, address initialFeeCollector)
        CherumFeeBase(initialOwner, initialFeeCollector)
    {}

    /// @notice Enable or disable third-party (gasless) submission.
    function setRelayerEnabled(bool enabled) external onlyOwner {
        relayerEnabled = enabled;
        emit RelayerEnabledSet(enabled);
    }

    /// @dev Submitter authorisation: the account itself always may submit; a
    ///      third party may only when relaying is enabled.
    function _authorizeCaller(address account) internal view {
        if (msg.sender != account && !relayerEnabled) revert RelayingDisabled();
    }

    /// @dev Pull the full signed input amount from `account` to this contract
    ///      under the order witness. The destination is always this contract,
    ///      so a front-runner cannot divert the transfer (Permit2 leaves the
    ///      `to` field unsigned).
    function _pullInput(
        address token,
        uint256 amount,
        uint256 nonce,
        CherumOrder.Order calldata order,
        bytes calldata signature
    ) internal {
        if (block.timestamp > order.deadline) revert OrderExpired(order.deadline);
        PERMIT2_SIG.permitWitnessTransferFrom(
            IPermit2SignatureTransfer.PermitTransferFrom({
                permitted: IPermit2SignatureTransfer.TokenPermissions({token: token, amount: amount}),
                nonce: nonce,
                deadline: order.deadline
            }),
            IPermit2SignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            order.account,
            order.hash(),
            CherumOrder.WITNESS_TYPE_STRING,
            signature
        );
    }
}
