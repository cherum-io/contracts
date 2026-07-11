// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {CherumPermit2Base} from "./CherumPermit2Base.sol";
import {CherumOrder} from "./CherumOrder.sol";

/// @title CherumRouter
/// @notice Same-chain fan-out router: one Permit2 order splits a single input
///         token across many aggregator swaps, each delivered to its own
///         recipient. Mirrors the cross-chain router's order envelope and fee
///         model so a user sees identical economics on either path.
/// @dev    The fee is taken from the input token up front, then the remaining
///         principal is fanned out; each recipient receives the full swap
///         output of its slice, floored by a signed per-leg minimum. (The
///         legacy same-chain router skimmed the fee from each leg's output;
///         taking it from the single input token instead lets one absolute
///         signed fee cover a fan-out whose legs produce different tokens.)
///         Each leg is isolated by try/catch: a failed leg refunds its input
///         slice to the order's refund recipient without cascading.
contract CherumRouter is CherumPermit2Base, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CherumOrder for CherumOrder.Order;

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Immutable hard ceiling for `maxBatchLegs`. The owner may tune the
    ///         active limit below this without a redeploy, but never above it,
    ///         bounding worst-case gas/calldata permanently. ~30 real legs stay
    ///         well under a block.
    uint256 public constant MAX_BATCH_LEGS_CEILING = 30;
    /// @notice Active per-intent leg limit. Owner-settable (instant) within
    ///         [1, MAX_BATCH_LEGS_CEILING]; defaults to 12. A count ceiling
    ///         only: changing it cannot move or trap funds.
    uint256 public maxBatchLegs;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant MIN_SLICE_WEI = 1_000;
    uint256 internal constant MAX_PERMIT_WINDOW = 1 hours;
    uint256 internal constant BATCH_LEG_GAS_CAP = 1_000_000;
    uint256 internal constant MAX_RETURN_DATA = 4096;
    uint256 internal constant NATIVE_PAYOUT_GAS = 60_000;

    /// @notice One fan-out leg: swap a slice of principal into `toToken` and
    ///         deliver at least `minOutToRecipient` to `recipient` through a
    ///         whitelisted aggregator.
    struct LegSpec {
        uint16 splitBps;
        address toToken;
        uint256 minOutToRecipient;
        address recipient;
        address aggregator;
        bytes aggregatorCalldata;
    }

    /// @notice Genesis aggregator allowlist entry, applied without timelock at deploy.
    struct InitialAggregator {
        address aggregator;
        bytes4[] selectors;
    }

    uint256 private _batchNonce;

    event BatchLeg(
        bytes32 indexed intentId,
        uint256 indexed batchId,
        uint8 legIndex,
        address aggregator,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 amountOut,
        address recipient,
        bool success
    );
    event BatchCompleted(
        bytes32 indexed intentId,
        address indexed account,
        uint256 batchId,
        uint8 legsTotal,
        uint8 legsSucceeded,
        uint256 cherumFee,
        uint256 integratorFee,
        uint256 refundedInput
    );
    event FeeCollected(bytes32 indexed intentId, address token, address collector, uint256 amount);
    event IntegratorFeeCollected(bytes32 indexed intentId, address token, address recipient, uint256 amount);
    event GenesisAggregator(address indexed aggregator, bytes4 selector);
    event NativeRefundStranded(address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event MaxBatchLegsSet(uint256 newMax);

    error BatchEmpty();
    error BatchTooLarge(uint256 supplied, uint256 max);
    error InvalidMaxBatchLegs(uint256 supplied);
    error ZeroAmount();
    error ZeroAddress();
    error ZeroRefundRecipient();
    error AmountBelowMinSlice(uint256 supplied, uint256 minRequired);
    error ZeroSplitBps(uint8 legIndex);
    error BatchSplitMismatch(uint256 totalSplitBps, uint256 expected);
    error LegsHashMismatch();
    error NativeFeesHashMustBeZero();
    error NativeInputUnsupported();
    error PermitDeadlineTooFar(uint256 deadline, uint256 max);
    error FoTNotSupported();
    error AllLegsFailed();
    error OnlySelf();
    error InvalidRecipient();
    error SameToken();
    error InsufficientOutput(uint256 produced, uint256 minOut);
    error AggregatorCallFailed(bytes returnData);
    error NativeTransferFailed();
    error BalanceInvariant();

    constructor(address initialOwner, address initialFeeCollector, InitialAggregator[] memory initialAggregators)
        CherumPermit2Base(initialOwner, initialFeeCollector)
    {
        for (uint256 i; i < initialAggregators.length; ++i) {
            address agg = initialAggregators[i].aggregator;
            if (agg == address(0) || agg == address(this) || agg == PERMIT2 || agg == NATIVE) revert ZeroAddress();
            allowedTarget[agg] = true;
            bytes4[] memory sels = initialAggregators[i].selectors;
            for (uint256 j; j < sels.length; ++j) {
                if (_isForbiddenSelector(sels[j])) revert ForbiddenSelector(sels[j]);
                allowedSelector[agg][sels[j]] = true;
                emit GenesisAggregator(agg, sels[j]);
            }
        }
        maxBatchLegs = 12;
        emit MaxBatchLegsSet(12);
    }

    // -- Read helpers -------------------------------------------------------

    function hashLegs(LegSpec[] calldata legs) public pure returns (bytes32) {
        return keccak256(abi.encode(legs));
    }

    // -- Owner: rescue stray assets -----------------------------------------

    /// @notice Recover tokens or native held by this contract to an owner-chosen
    ///         address. The router is a pass-through and holds nothing between
    ///         batches (enforced by the post-batch sweep + invariants), so any
    ///         resting balance is a stray transfer or a donation; this lets it
    ///         be swept to e.g. the treasury. Owner-only, paused-only.
    function rescue(address token, address to, uint256 amount) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (token == NATIVE) {
            (bool sent,) = payable(to).call{value: amount}("");
            if (!sent) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    /// @notice Tune the active per-intent leg limit without a redeploy. Bounded
    ///         by the immutable ceiling; a count knob only (cannot move funds).
    function setMaxBatchLegs(uint256 newMax) external onlyOwner {
        if (newMax < 1 || newMax > MAX_BATCH_LEGS_CEILING) revert InvalidMaxBatchLegs(newMax);
        maxBatchLegs = newMax;
        emit MaxBatchLegsSet(newMax);
    }

    // -- Main entry ---------------------------------------------------------

    /// @notice Fan out one signed input across many same-chain swap legs.
    function batchSwap(
        LegSpec[] calldata legs,
        CherumOrder.Order calldata order,
        uint256 permit2Nonce,
        bytes calldata signature,
        address fromToken,
        uint256 amountIn
    ) external nonReentrant whenNotPaused returns (uint256 succeededLegs) {
        _authorizeCaller(order.account);

        _validateBatch(legs, amountIn);
        if (fromToken == address(0) || fromToken == NATIVE) revert NativeInputUnsupported();
        if (order.refundRecipient == address(0)) revert ZeroRefundRecipient();
        if (order.deadline > block.timestamp + MAX_PERMIT_WINDOW) {
            revert PermitDeadlineTooFar(order.deadline, block.timestamp + MAX_PERMIT_WINDOW);
        }
        if (hashLegs(legs) != order.legsHash) revert LegsHashMismatch();
        if (order.nativeFeesHash != bytes32(0)) revert NativeFeesHashMustBeZero();

        uint256 fromBalBefore = IERC20(fromToken).balanceOf(address(this));
        uint256 nativeBalBefore = address(this).balance;

        _pullInput(fromToken, amountIn, permit2Nonce, order, signature);
        if (IERC20(fromToken).balanceOf(address(this)) - fromBalBefore != amountIn) revert FoTNotSupported();

        // Skim fees from the input token, then fan out the remaining principal.
        (uint256 cherumFee, uint256 integratorFee) =
            _resolveFees(amountIn, order.signedFeeAmount, order.integratorRecipient, order.integratorBps);
        if (cherumFee != 0) {
            IERC20(fromToken).safeTransfer(feeCollector, cherumFee);
            emit FeeCollected(order.intentId, fromToken, feeCollector, cherumFee);
        }
        if (integratorFee != 0) {
            IERC20(fromToken).safeTransfer(order.integratorRecipient, integratorFee);
            emit IntegratorFeeCollected(order.intentId, fromToken, order.integratorRecipient, integratorFee);
        }
        uint256 principal = amountIn - cherumFee - integratorFee;

        uint256 batchId;
        uint256 refunded;
        (succeededLegs, batchId, refunded) =
            _runBatch(legs, order.intentId, order.refundRecipient, fromToken, principal, fromBalBefore, nativeBalBefore);

        emit BatchCompleted(
            order.intentId,
            order.account,
            batchId,
            uint8(legs.length),
            uint8(succeededLegs),
            cherumFee,
            integratorFee,
            refunded
        );
    }

    // -- Internal -----------------------------------------------------------

    function _validateBatch(LegSpec[] calldata legs, uint256 amountIn) private view {
        uint256 n = legs.length;
        if (n == 0) revert BatchEmpty();
        if (n > maxBatchLegs) revert BatchTooLarge(n, maxBatchLegs);
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn < n * MIN_SLICE_WEI) revert AmountBelowMinSlice(amountIn, n * MIN_SLICE_WEI);

        uint256 sumBps;
        for (uint256 i; i < n; ++i) {
            if (legs[i].splitBps == 0) revert ZeroSplitBps(uint8(i));
            sumBps += legs[i].splitBps;
        }
        if (sumBps != MAX_BPS) revert BatchSplitMismatch(sumBps, MAX_BPS);
    }

    function _runBatch(
        LegSpec[] calldata legs,
        bytes32 intentId,
        address refundRecipient,
        address fromToken,
        uint256 principal,
        uint256 fromBalBefore,
        uint256 nativeBalBefore
    ) private returns (uint256 succeededLegs, uint256 batchId, uint256 refunded) {
        batchId = ++_batchNonce;
        uint256 spent;

        for (uint256 i; i < legs.length; ++i) {
            LegSpec calldata leg = legs[i];
            uint256 sliceIn = (i == legs.length - 1) ? principal - spent : (principal * leg.splitBps) / MAX_BPS;
            if (i != legs.length - 1) spent += sliceIn;

            (bool ok, uint256 outAmount) = _executeLeg(fromToken, sliceIn, leg);
            emit BatchLeg(
                intentId, batchId, uint8(i), leg.aggregator, fromToken, leg.toToken, sliceIn, outAmount, leg.recipient, ok
            );

            if (ok) {
                ++succeededLegs;
            } else {
                refunded += sliceIn;
                IERC20(fromToken).safeTransfer(refundRecipient, sliceIn);
            }
        }

        if (succeededLegs == 0) revert AllLegsFailed();

        // Partial-fill sweep: aggregators may consume less than the approved
        // slice. Return any input above the pre-pull baseline to the refund
        // recipient, then enforce the directional invariant.
        uint256 fromBalAfter = IERC20(fromToken).balanceOf(address(this));
        if (fromBalAfter > fromBalBefore) {
            IERC20(fromToken).safeTransfer(refundRecipient, fromBalAfter - fromBalBefore);
        }
        if (IERC20(fromToken).balanceOf(address(this)) < fromBalBefore) revert BalanceInvariant();

        // Return any native an aggregator handed back (e.g. swaps to native).
        _sweepNative(refundRecipient, nativeBalBefore);
    }

    function _executeLeg(address fromToken, uint256 sliceIn, LegSpec calldata leg)
        private
        returns (bool ok, uint256 outAmount)
    {
        try this._legBody(fromToken, sliceIn, leg) returns (uint256 _out) {
            return (true, _out);
        } catch {
            return (false, 0);
        }
    }

    /// @notice External-but-self-only try/catch trampoline for a single leg.
    function _legBody(address fromToken, uint256 sliceIn, LegSpec calldata leg) external returns (uint256 outAmount) {
        if (msg.sender != address(this)) revert OnlySelf();
        if (leg.recipient == address(0) || leg.recipient == address(this)) revert InvalidRecipient();
        if (fromToken == leg.toToken) revert SameToken();
        if (sliceIn == 0) revert ZeroAmount();
        _guardCall(leg.aggregator, leg.aggregatorCalldata, fromToken);

        uint256 outBalBefore = _balanceOf(leg.toToken, address(this));
        _executeAggregator(fromToken, sliceIn, leg.aggregator, leg.aggregatorCalldata);
        outAmount = _balanceOf(leg.toToken, address(this)) - outBalBefore;
        if (outAmount < leg.minOutToRecipient) revert InsufficientOutput(outAmount, leg.minOutToRecipient);

        _payOut(leg.toToken, leg.recipient, outAmount);
        if (_balanceOf(leg.toToken, address(this)) < outBalBefore) revert BalanceInvariant();
    }

    function _executeAggregator(address token, uint256 amount, address aggregator, bytes calldata data) private {
        IERC20 t = IERC20(token);
        t.forceApprove(aggregator, amount);
        (bool ok, bytes memory ret) = _boundedCall(aggregator, 0, data);
        t.forceApprove(aggregator, 0);
        if (!ok) revert AggregatorCallFailed(ret);
    }

    function _boundedCall(address target, uint256 value, bytes calldata data)
        private
        returns (bool success, bytes memory ret)
    {
        assembly ("memory-safe") {
            let inPtr := mload(0x40)
            calldatacopy(inPtr, data.offset, data.length)
            success := call(BATCH_LEG_GAS_CAP, target, value, inPtr, data.length, 0, 0)
            let rds := returndatasize()
            if gt(rds, MAX_RETURN_DATA) { rds := MAX_RETURN_DATA }
            ret := mload(0x40)
            mstore(ret, rds)
            returndatacopy(add(ret, 0x20), 0, rds)
            mstore(0x40, add(add(ret, 0x20), and(add(rds, 0x1f), not(0x1f))))
        }
    }

    function _payOut(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == NATIVE) {
            (bool ok,) = payable(to).call{value: amount, gas: NATIVE_PAYOUT_GAS}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20 t = IERC20(token);
            uint256 pre = t.balanceOf(to);
            t.safeTransfer(to, amount);
            if (t.balanceOf(to) - pre != amount) revert FoTNotSupported();
        }
    }

    function _sweepNative(address to, uint256 baseline) private {
        uint256 current = address(this).balance;
        if (current > baseline) {
            uint256 amount = current - baseline;
            (bool ok,) = payable(to).call{value: amount, gas: NATIVE_PAYOUT_GAS}("");
            if (!ok) emit NativeRefundStranded(to, amount);
        }
    }

    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == NATIVE) return who.balance;
        return IERC20(token).balanceOf(who);
    }
}
