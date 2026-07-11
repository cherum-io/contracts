// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {CherumCallGuard} from "./CherumCallGuard.sol";

/// @title CherumFeeBase
/// @notice Fee accounting shared by both routers: a dynamic Cherum fee, an
///         optional integrator fee, and the immutable ceilings that bound them.
/// @dev    The Cherum fee is an absolute amount signed per swap, so it can
///         follow a fee schedule off-chain while staying capped on-chain. The
///         integrator fee is a basis-point share. Both are measured against the
///         input amount in both routers, and the combined total can never exceed
///         the hard ceiling (which is below 100%, so principal never underflows),
///         regardless of what the backend signs.
abstract contract CherumFeeBase is CherumCallGuard {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceiling on the combined fee, in basis points. Hardcoded so
    ///         no deployment or admin action can ever exceed it.
    uint16 public constant MAX_TOTAL_FEE_BPS = 1_000; // 10%

    /// @notice Hard ceiling on the integrator share, in basis points.
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 500; // 5%

    /// @notice Recipient of the Cherum fee.
    address public feeCollector;

    event FeeCollectorSet(address indexed newCollector);

    error ZeroFeeCollector();
    error FeeCollectorMustBeEOA(); // feeCollector has code (contract or EIP-7702 delegate)
    error IntegratorFeeTooHigh(uint16 bps);
    error TotalFeeTooHigh(uint256 total, uint256 maxTotal);

    constructor(address initialOwner, address initialFeeCollector) CherumCallGuard(initialOwner) {
        if (initialFeeCollector == address(0)) revert ZeroFeeCollector();
        // feeCollector must be a pure EOA (code.length == 0): blocks pointing the
        // fee stream at a contract or an EIP-7702-delegated EOA (anti-phishing /
        // anti-redirect parity with V1). It also keeps the fee `safeTransfer`
        // free of any receiver-side callback. The owner is trusted to keep this
        // address code-free for the contract's lifetime.
        if (initialFeeCollector.code.length != 0) revert FeeCollectorMustBeEOA();
        feeCollector = initialFeeCollector;
    }

    /// @notice Set the fee recipient. Redirects only the future fee stream,
    ///         never user funds. Must be a code-free EOA (see constructor).
    function setFeeCollector(address newCollector) external onlyOwner {
        if (newCollector == address(0)) revert ZeroFeeCollector();
        if (newCollector.code.length != 0) revert FeeCollectorMustBeEOA();
        feeCollector = newCollector;
        emit FeeCollectorSet(newCollector);
    }

    /// @dev Resolve the two fee amounts for a swap and enforce every cap.
    ///      An integrator fee applies only when a recipient is set. The signed
    ///      Cherum amount plus the integrator amount must fit under the total
    ///      ceiling computed from `base`.
    function _resolveFees(uint256 base, uint256 signedFeeAmount, address integratorRecipient, uint16 integratorBps)
        internal
        pure
        returns (uint256 cherumFee, uint256 integratorFee)
    {
        if (integratorRecipient == address(0)) {
            integratorFee = 0;
        } else {
            if (integratorBps > MAX_INTEGRATOR_FEE_BPS) revert IntegratorFeeTooHigh(integratorBps);
            integratorFee = (base * integratorBps) / BPS_DENOMINATOR;
        }

        cherumFee = signedFeeAmount;

        uint256 maxTotal = (base * MAX_TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 total = cherumFee + integratorFee;
        if (total > maxTotal) revert TotalFeeTooHigh(total, maxTotal);
    }
}
