// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {CherumAdmin} from "./CherumAdmin.sol";

/// @title CherumCallGuard
/// @notice Allowlist for external call targets and their function selectors,
///         plus the validation applied before any user-funded external call.
/// @dev    Targets and selectors are set immediately by the owner. Validation
///         reads the selector from the first four bytes of the calldata (not
///         "selector appears somewhere"), refuses a target equal to the pulled
///         token, and refuses token-draining selectors outright. This closes
///         the arbitrary-call / approval-abuse class behind the SwapNet, LI.FI
///         and Socket incidents.
abstract contract CherumCallGuard is CherumAdmin {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Token-moving selectors that must never be invoked through a routed call.
    bytes4 private constant SEL_TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant SEL_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant SEL_APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant SEL_PERMIT = 0xd505accf; // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
    bytes4 private constant SEL_SET_APPROVAL_FOR_ALL = 0xa22cb465; // setApprovalForAll(address,bool)

    mapping(address => bool) public allowedTarget;
    mapping(address => mapping(bytes4 => bool)) public allowedSelector;

    event TargetSet(address indexed target, bool allowed);
    event SelectorSet(address indexed target, bytes4 indexed selector, bool allowed);

    error InvalidTarget(address target);
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(address target, bytes4 selector);
    error CalldataTooShort();
    error TargetIsToken(address target);
    error ForbiddenSelector(bytes4 selector);

    constructor(address initialOwner) CherumAdmin(initialOwner) {}

    /// @notice Enable or disable a call target. Enabling rejects the zero
    ///         address, this contract, and Permit2.
    function setTarget(address target, bool allowed) external onlyOwner {
        if (allowed && (target == address(0) || target == address(this) || target == PERMIT2)) {
            revert InvalidTarget(target);
        }
        allowedTarget[target] = allowed;
        emit TargetSet(target, allowed);
    }

    /// @notice Enable or disable a selector for a target. Token-draining
    ///         selectors can never be enabled.
    function setSelector(address target, bytes4 selector, bool allowed) external onlyOwner {
        if (allowed && _isForbiddenSelector(selector)) revert ForbiddenSelector(selector);
        allowedSelector[target][selector] = allowed;
        emit SelectorSet(target, selector, allowed);
    }

    /// @dev Enforce the allowlist before an external call funded by the user.
    ///      `pulledToken` is the token taken from the user for this intent.
    function _guardCall(address target, bytes calldata data, address pulledToken) internal view {
        if (data.length < 4) revert CalldataTooShort();
        if (!allowedTarget[target]) revert TargetNotAllowed(target);
        if (target == pulledToken) revert TargetIsToken(target);
        bytes4 selector = bytes4(data[:4]);
        if (_isForbiddenSelector(selector)) revert ForbiddenSelector(selector);
        if (!allowedSelector[target][selector]) revert SelectorNotAllowed(target, selector);
    }

    /// @dev Internal so derived contracts can apply the same filter to a
    ///      genesis (deploy-time) allowlist.
    function _isForbiddenSelector(bytes4 selector) internal pure returns (bool) {
        return selector == SEL_TRANSFER || selector == SEL_TRANSFER_FROM || selector == SEL_APPROVE
            || selector == SEL_PERMIT || selector == SEL_SET_APPROVAL_FOR_ALL;
    }
}
