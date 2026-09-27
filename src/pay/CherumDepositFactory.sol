// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CherumDepositForwarder} from "./CherumDepositForwarder.sol";

/// @title CherumDepositFactory
/// @notice Mints deterministic per-invoice deposit addresses (CREATE2 minimal
///         proxies over CherumDepositForwarder) and sweeps them. The address
///         for an invoice is computable off-chain before any deployment, so
///         the payer page can show it instantly; the proxy is deployed lazily
///         — only after a deposit is detected — and flushed in the same
///         transaction.
/// @dev    The forwarder's treasury is immutable and shared by every proxy on
///         this chain (immutables are part of the implementation bytecode).
///         Deploying a proxy for a salt is permissionless-safe for the same
///         reason flushing is: the outcome is fixed by construction.
contract CherumDepositFactory {
    using Clones for address;

    /// @notice Shared forwarder implementation (treasury baked in).
    address public immutable implementation;

    event DepositAddressDeployed(bytes32 indexed salt, address addr);

    constructor(address treasury) {
        implementation = address(new CherumDepositForwarder(treasury));
    }

    /// @notice Deterministic deposit address for `salt` (salt = invoice id
    ///         hash). Valid before deployment — safe to receive plain
    ///         transfers as a code-less address.
    function predict(bytes32 salt) public view returns (address) {
        return implementation.predictDeterministicAddress(salt, address(this));
    }

    /// @notice Deploy the proxy for `salt` (idempotent: returns the existing
    ///         address if already deployed) and flush the listed assets to
    ///         the treasury. `tokens` may be empty; native is flushed when
    ///         `flushNativeToo` is set. One relayer transaction does deploy +
    ///         sweep for a fresh deposit.
    function deployAndFlush(bytes32 salt, IERC20[] calldata tokens, bool flushNativeToo)
        external
        returns (address addr)
    {
        addr = predict(salt);
        if (addr.code.length == 0) {
            implementation.cloneDeterministic(salt);
            emit DepositAddressDeployed(salt, addr);
        }
        CherumDepositForwarder f = CherumDepositForwarder(payable(addr));
        for (uint256 i = 0; i < tokens.length; i++) {
            f.flush(tokens[i]);
        }
        if (flushNativeToo) {
            f.flushNative();
        }
    }
}
