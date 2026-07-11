// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title CherumAdmin
/// @notice Two-step ownership and pause control for the routers.
/// @dev    Privileged configuration changes are applied immediately by the
///         owner; there is no timelock by design. The trust boundary is the
///         owner itself (a 2/3 multisig with keys split across parties), and
///         what any single change can do is bounded at the execution layer
///         (target+selector allowlist, target != pulled token, approve-exact
///         then reset, per-leg balance invariants). Risk-reducing actions
///         (removing an allowlist entry, pausing) are also immediate.
abstract contract CherumAdmin is Ownable2Step, Pausable {
    error RenounceDisabled();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Halt user-facing entry points immediately.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume after a pause.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Renouncing ownership is permanently disabled. A null owner would
    ///         brick pause, rescue/withdraw and every setter, irreversibly
    ///         stranding any funds at rest. Ownership can still be transferred
    ///         (two-step via Ownable2Step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
