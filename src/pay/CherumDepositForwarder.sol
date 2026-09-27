// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CherumDepositForwarder
/// @notice Implementation behind per-invoice minimal-proxy deposit addresses.
///         Anything that lands on a deposit address can be pushed to exactly
///         one destination — the treasury fixed at deployment. There is no
///         owner, no configuration, no other external call: the operator is
///         physically unable to redirect a deposit anywhere else.
/// @dev    Deposit addresses are counterfactual (CREATE2): payers send plain
///         transfers to an address that has NO code yet, so exchange
///         withdrawals and gas-stipend-limited native sends always succeed.
///         The proxy is deployed lazily by the factory only after funds
///         arrive, then flushed. Immutables live in this implementation's
///         bytecode, so proxies see the same treasury via delegatecall.
///         Refunds of mistaken deposits are made FROM the treasury (a Safe),
///         never from here — the only-to-treasury invariant is absolute.
contract CherumDepositForwarder {
    using SafeERC20 for IERC20;

    /// @notice Sole destination for every flush. A per-chain Cherum Safe.
    address public immutable treasury;

    event Flushed(address indexed token, uint256 amount);

    error ZeroTreasury();
    error NativeSendFailed();

    constructor(address treasury_) {
        if (treasury_ == address(0)) revert ZeroTreasury();
        treasury = treasury_;
    }

    /// @notice Accept native coin (both before and after deployment).
    receive() external payable {}

    /// @notice Push the full balance of `token` to the treasury.
    ///         Callable by anyone: the destination is fixed, so an arbitrary
    ///         caller can only do Cherum's own job for it.
    function flush(IERC20 token) external {
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) {
            token.safeTransfer(treasury, amount);
            emit Flushed(address(token), amount);
        }
    }

    /// @notice Push the full native balance to the treasury.
    function flushNative() external {
        uint256 amount = address(this).balance;
        if (amount != 0) {
            (bool ok, ) = treasury.call{value: amount}("");
            if (!ok) revert NativeSendFailed();
            emit Flushed(address(0), amount);
        }
    }
}
