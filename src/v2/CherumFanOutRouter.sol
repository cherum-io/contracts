// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {CherumPermit2Base} from "./CherumPermit2Base.sol";
import {CherumOrder} from "./CherumOrder.sol";

/// @title CherumFanOutRouter
/// @notice Cross-chain fan-out router: pulls one input token under a single
///         Permit2 order and dispatches it across many bridge legs to
///         destinations on other chains. The destination side is handled by
///         CherumReceiver per chain.
/// @dev    Funds never rest in this contract between intents. Each leg writes
///         its state before the external bridge call (checks-effects-
///         interactions), reserves its slice in a per-token refund pool, and
///         approves the spender for exactly the leg amount, resetting to zero
///         immediately after. The call target and selector are allowlisted and
///         validated by position; the approval spender is owner-configured,
///         never caller-supplied.
contract CherumFanOutRouter is CherumPermit2Base, ReentrancyGuardTransient {
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
    ///         only: changing it cannot move or trap funds (an over-large intent
    ///         simply fails atomically when it cannot fit a block).
    uint256 public maxBatchLegs;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant MIN_SLICE_WEI = 1_000;
    uint256 internal constant MIN_INTENT_DEADLINE = 1 hours;
    uint256 internal constant MAX_INTENT_DEADLINE = 24 hours;
    uint256 internal constant BRIDGE_GAS_CAP = 2_000_000;
    uint256 internal constant MAX_RETURN_DATA = 4096;
    uint8 internal constant CAP_DECIMALS = 6;
    uint256 internal constant NATIVE_DUST_LIMIT = 5e14;
    uint256 internal constant DUST_REFUND_GAS = 60_000;

    enum LegStatus {
        NONE,
        BRIDGED,
        REFUNDED
    }

    struct LegState {
        address refundRecipient;
        address tokenIn;
        uint128 amountIn;
        uint64 deadline;
        LegStatus status;
    }

    /// @notice One fan-out leg. The bridge `provider` and the first four bytes
    ///         of `bridgeCalldata` must both be allowlisted. The approval
    ///         spender is resolved from `approveTargetFor` (owner-set), never
    ///         from this struct.
    struct BridgeLeg {
        address provider;
        uint16 splitBps;
        bytes bridgeCalldata;
    }

    /// @notice Genesis allowlist entry, applied without timelock at deploy.
    struct InitialBridge {
        address provider;
        address approveTarget;
        bytes4[] selectors;
    }

    /// @notice Parameters for the settler-driven (ERC-7683) execution path.
    struct ExternalFanOut {
        bytes32 intentId;
        uint256 deadline;
        address tokenIn;
        uint256 totalAmountIn;
        address refundRecipient;
        address integratorRecipient;
        uint16 integratorBps;
        uint256 signedFeeAmount;
    }

    /// @notice Owner-configured approval spender per bridge. When zero, the
    ///         provider itself is approved. Set by the owner; covers the
    ///         separated approve/call pattern (e.g. Symbiosis Gateway).
    mapping(address => address) public approveTargetFor;

    /// @notice Instant kill switch per bridge. A killed bridge stays in the
    ///         allowlist but cannot be selected by new intents; in-flight legs
    ///         are unaffected.
    mapping(address => bool) public bridgeKilled;

    /// @notice Allowlisted ERC-7683 settlers permitted to drive the external
    ///         execution path. Set by the owner.
    mapping(address => bool) public allowedSettler;

    /// @notice Master switch for the settler-driven path. Off by default.
    bool public settlerExecutionEnabled;

    mapping(bytes32 => LegState) public legState;
    mapping(address => uint256) public refundReserved;

    uint256 public maxNotionalUsdPerIntent;
    uint256 public globalDailyUsdCap;
    uint256 private _currentDayUsd;
    uint256 private _currentDayBucket;

    event BatchOpened(
        bytes32 indexed intentId,
        address indexed account,
        address indexed tokenIn,
        uint256 principal,
        uint256 cherumFee,
        uint256 integratorFee,
        uint8 legsCount
    );
    event BridgeInitiated(
        bytes32 indexed intentId, uint256 legIdx, address provider, bytes4 selector, uint256 amount, uint256 deadline
    );
    event FeeCollected(bytes32 indexed intentId, address token, address collector, uint256 amount);
    event IntegratorFeeCollected(bytes32 indexed intentId, address token, address recipient, uint256 amount);
    event LegRefunded(bytes32 indexed intentId, uint256 legIdx, address to, uint256 amount, bool adminReleased);
    event ApproveTargetSet(address indexed provider, address indexed approveTarget);
    event BridgeKilled(address indexed provider);
    event BridgeUnkilled(address indexed provider);
    event SettlerSet(address indexed settler, bool allowed);
    event SettlerExecutionSet(bool enabled);
    event GenesisBridge(address indexed provider, address approveTarget);
    event GenesisSelector(address indexed provider, bytes4 selector);
    event TvlCapsSet(uint256 maxPerIntent, uint256 dailyCap);
    event MaxBatchLegsSet(uint256 newMax);
    event NativeDustStranded(address indexed to, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error BatchEmpty();
    error BatchTooLarge(uint256 supplied, uint256 max);
    error InvalidMaxBatchLegs(uint256 supplied);
    error NativeFeesLengthMismatch(uint256 legsLen, uint256 nativeFeesLen);
    error NativeFeesSumMismatch(uint256 expected, uint256 actual);
    error ZeroAmount();
    error AmountOverflowsUint128();
    error ZeroAddress();
    error ZeroRefundRecipient();
    error InvalidApproveTarget(address target);
    error InvalidIntentDeadline(uint256 deadline, uint256 minDeadline, uint256 maxDeadline);
    error LegsHashMismatch();
    error NativeFeesHashMismatch();
    error ZeroSplitBps(uint8 legIndex);
    error BatchSplitMismatch(uint256 totalSplitBps, uint256 expected);
    error BridgeKilledError(address provider);
    error AmountBelowMinSlice(uint256 supplied, uint256 minRequired);
    error LegAlreadyProcessed(bytes32 intentId, uint256 legIdx);
    error FoTNotSupported();
    error BridgeCallFailed(bytes returnData);
    error BalanceInvariant();
    error NativeDustRemaining(uint256 amount);
    error LegNotBridged(bytes32 intentId, uint256 legIdx);
    error NotRefundRecipientOrOwner(address sender, address refundRecipient);
    error RefundNotReady(uint256 deadline, uint256 nowTs);
    error RouterLacksRefundBalance(uint256 needed, uint256 available);
    error IntentExceedsCap(uint256 amountUsd, uint256 cap);
    error GlobalDailyCapExceeded(uint256 totalUsd, uint256 cap);
    error TokenDecimalsUnavailable(address token);
    error NativeTransferFailed();
    error InsufficientWithdrawable(uint256 requested, uint256 free);
    error SettlerExecutionDisabled();
    error SettlerNotAllowed(address settler);

    constructor(
        address initialOwner,
        address initialFeeCollector,
        uint256 initialMaxPerIntent,
        uint256 initialDailyCap,
        InitialBridge[] memory initialBridges
    ) CherumPermit2Base(initialOwner, initialFeeCollector) {
        maxNotionalUsdPerIntent = initialMaxPerIntent;
        globalDailyUsdCap = initialDailyCap;
        emit TvlCapsSet(initialMaxPerIntent, initialDailyCap);
        maxBatchLegs = 12;
        emit MaxBatchLegsSet(12);

        for (uint256 i; i < initialBridges.length; ++i) {
            address provider = initialBridges[i].provider;
            if (provider == address(0) || provider == address(this) || provider == PERMIT2) {
                revert ZeroAddress();
            }
            allowedTarget[provider] = true;
            address apprTarget = initialBridges[i].approveTarget;
            _validateApproveTarget(apprTarget);
            if (apprTarget != address(0)) approveTargetFor[provider] = apprTarget;
            emit GenesisBridge(provider, apprTarget);
            bytes4[] memory sels = initialBridges[i].selectors;
            for (uint256 j; j < sels.length; ++j) {
                if (_isForbiddenSelector(sels[j])) revert ForbiddenSelector(sels[j]);
                allowedSelector[provider][sels[j]] = true;
                emit GenesisSelector(provider, sels[j]);
            }
        }
    }

    // -- Read helpers -------------------------------------------------------

    function legKey(bytes32 intentId, uint256 legIdx) public pure returns (bytes32) {
        return keccak256(abi.encode(intentId, legIdx));
    }

    function getLegState(bytes32 intentId, uint256 legIdx) external view returns (LegState memory) {
        return legState[legKey(intentId, legIdx)];
    }

    function hashLegs(BridgeLeg[] calldata legs) public pure returns (bytes32) {
        return keccak256(abi.encode(legs));
    }

    function hashNativeFees(uint256[] calldata nativeFees) public pure returns (bytes32) {
        return keccak256(abi.encode(nativeFees));
    }

    function currentDayUsage() external view returns (uint256 bucketDay, uint256 usdSoFar) {
        return (_currentDayBucket, _currentDayUsd);
    }

    // -- Main entry (user-signed Permit2 path) ------------------------------

    /// @notice Open a cross-chain fan-out intent under a signed order.
    function bridgeAndCallBatch(
        BridgeLeg[] calldata legs,
        uint256[] calldata nativeFees,
        CherumOrder.Order calldata order,
        uint256 permit2Nonce,
        bytes calldata signature,
        address tokenIn,
        uint256 totalAmountIn
    ) external payable nonReentrant whenNotPaused {
        _authorizeCaller(order.account);

        _commonChecks(legs.length, nativeFees.length, totalAmountIn, tokenIn, order.refundRecipient, order.deadline);
        if (hashLegs(legs) != order.legsHash) revert LegsHashMismatch();
        if (hashNativeFees(nativeFees) != order.nativeFeesHash) revert NativeFeesHashMismatch();

        uint256 nativeSum = _validateLegs(legs, nativeFees, tokenIn);
        if (nativeSum != msg.value) revert NativeFeesSumMismatch(msg.value, nativeSum);

        _checkAndAccountCaps(tokenIn, totalAmountIn);

        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        _pullInput(tokenIn, totalAmountIn, permit2Nonce, order, signature);
        if (IERC20(tokenIn).balanceOf(address(this)) - balBefore != totalAmountIn) revert FoTNotSupported();

        uint256 principal = _skimFees(
            order.intentId, order.account, tokenIn, totalAmountIn, order.integratorRecipient, order.integratorBps, order.signedFeeAmount, uint8(legs.length)
        );

        _dispatchLegs(legs, nativeFees, order.intentId, order.deadline, order.refundRecipient, tokenIn, principal);
    }

    // -- Settler-driven entry (ERC-7683 execution, flag-gated) --------------

    /// @notice Dispatch a fan-out using funds supplied by a whitelisted ERC-7683
    ///         settler. The settler must have approved this contract for
    ///         `p.totalAmountIn`. Disabled until the owner enables it and
    ///         allowlists the settler under the timelock.
    function bridgeAndCallBatchExternal(BridgeLeg[] calldata legs, uint256[] calldata nativeFees, ExternalFanOut calldata p)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (!settlerExecutionEnabled) revert SettlerExecutionDisabled();
        if (!allowedSettler[msg.sender]) revert SettlerNotAllowed(msg.sender);

        _commonChecks(legs.length, nativeFees.length, p.totalAmountIn, p.tokenIn, p.refundRecipient, p.deadline);

        uint256 nativeSum = _validateLegs(legs, nativeFees, p.tokenIn);
        if (nativeSum != msg.value) revert NativeFeesSumMismatch(msg.value, nativeSum);

        _checkAndAccountCaps(p.tokenIn, p.totalAmountIn);

        uint256 balBefore = IERC20(p.tokenIn).balanceOf(address(this));
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.totalAmountIn);
        if (IERC20(p.tokenIn).balanceOf(address(this)) - balBefore != p.totalAmountIn) revert FoTNotSupported();

        uint256 principal = _skimFees(
            p.intentId, msg.sender, p.tokenIn, p.totalAmountIn, p.integratorRecipient, p.integratorBps, p.signedFeeAmount, uint8(legs.length)
        );

        _dispatchLegs(legs, nativeFees, p.intentId, p.deadline, p.refundRecipient, p.tokenIn, principal);
    }

    // -- Shared internals ---------------------------------------------------

    function _commonChecks(
        uint256 legsCount,
        uint256 nativeFeesLen,
        uint256 totalAmountIn,
        address tokenIn,
        address refundRecipient,
        uint256 deadline
    ) private view {
        if (legsCount == 0) revert BatchEmpty();
        if (legsCount > maxBatchLegs) revert BatchTooLarge(legsCount, maxBatchLegs);
        if (nativeFeesLen != legsCount) revert NativeFeesLengthMismatch(legsCount, nativeFeesLen);
        if (totalAmountIn == 0) revert ZeroAmount();
        if (totalAmountIn > type(uint128).max) revert AmountOverflowsUint128();
        if (tokenIn == address(0) || tokenIn == NATIVE) revert ZeroAddress();
        if (refundRecipient == address(0)) revert ZeroRefundRecipient();
        uint256 minD = block.timestamp + MIN_INTENT_DEADLINE;
        uint256 maxD = block.timestamp + MAX_INTENT_DEADLINE;
        if (deadline < minD || deadline > maxD) revert InvalidIntentDeadline(deadline, minD, maxD);
    }

    function _validateLegs(BridgeLeg[] calldata legs, uint256[] calldata nativeFees, address tokenIn)
        private
        view
        returns (uint256 nativeSum)
    {
        uint256 legsCount = legs.length;
        uint256 totalSplitBps;
        for (uint256 i; i < legsCount; ++i) {
            BridgeLeg calldata leg = legs[i];
            if (leg.splitBps == 0) revert ZeroSplitBps(uint8(i));
            totalSplitBps += leg.splitBps;
            if (bridgeKilled[leg.provider]) revert BridgeKilledError(leg.provider);
            _guardCall(leg.provider, leg.bridgeCalldata, tokenIn);
            nativeSum += nativeFees[i];
        }
        if (totalSplitBps != MAX_BPS) revert BatchSplitMismatch(totalSplitBps, MAX_BPS);
    }

    function _skimFees(
        bytes32 intentId,
        address account,
        address tokenIn,
        uint256 totalAmountIn,
        address integratorRecipient,
        uint16 integratorBps,
        uint256 signedFeeAmount,
        uint8 legsCount
    ) private returns (uint256 principal) {
        (uint256 cherumFee, uint256 integratorFee) =
            _resolveFees(totalAmountIn, signedFeeAmount, integratorRecipient, integratorBps);
        if (cherumFee != 0) {
            IERC20(tokenIn).safeTransfer(feeCollector, cherumFee);
            emit FeeCollected(intentId, tokenIn, feeCollector, cherumFee);
        }
        if (integratorFee != 0) {
            IERC20(tokenIn).safeTransfer(integratorRecipient, integratorFee);
            emit IntegratorFeeCollected(intentId, tokenIn, integratorRecipient, integratorFee);
        }
        principal = totalAmountIn - cherumFee - integratorFee;
        emit BatchOpened(intentId, account, tokenIn, principal, cherumFee, integratorFee, legsCount);
    }

    function _dispatchLegs(
        BridgeLeg[] calldata legs,
        uint256[] calldata nativeFees,
        bytes32 intentId,
        uint256 deadline,
        address refundRecipient,
        address tokenIn,
        uint256 principal
    ) private {
        uint256 legsCount = legs.length;
        uint256 nativeBalBefore = address(this).balance - msg.value;
        uint256 spent;

        for (uint256 i; i < legsCount; ++i) {
            BridgeLeg calldata leg = legs[i];
            uint256 legAmount = (i == legsCount - 1) ? principal - spent : (principal * leg.splitBps) / MAX_BPS;
            if (legAmount < MIN_SLICE_WEI) revert AmountBelowMinSlice(legAmount, MIN_SLICE_WEI);
            spent += legAmount;

            bytes32 key = legKey(intentId, i);
            if (legState[key].status != LegStatus.NONE) revert LegAlreadyProcessed(intentId, i);

            legState[key] = LegState({
                refundRecipient: refundRecipient,
                tokenIn: tokenIn,
                amountIn: uint128(legAmount),
                deadline: uint64(deadline),
                status: LegStatus.BRIDGED
            });
            refundReserved[tokenIn] += legAmount;

            address approveTo = _resolveApproveTo(leg.provider);
            if (approveTo == tokenIn) revert InvalidApproveTarget(approveTo);
            uint256 preBridgeBal = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).forceApprove(approveTo, legAmount);

            (bool ok, bytes memory ret) =
                leg.provider.call{gas: BRIDGE_GAS_CAP, value: nativeFees[i]}(leg.bridgeCalldata);
            if (!ok) {
                if (ret.length > MAX_RETURN_DATA) {
                    assembly ("memory-safe") {
                        mstore(ret, MAX_RETURN_DATA)
                    }
                }
                revert BridgeCallFailed(ret);
            }

            IERC20(tokenIn).forceApprove(approveTo, 0);

            uint256 postBridgeBal = IERC20(tokenIn).balanceOf(address(this));
            if (preBridgeBal - postBridgeBal != legAmount) revert BalanceInvariant();

            emit BridgeInitiated(intentId, i, leg.provider, bytes4(leg.bridgeCalldata[:4]), legAmount, deadline);
        }

        uint256 nativeBalAfter = address(this).balance;
        if (nativeBalAfter > nativeBalBefore) {
            uint256 dust = nativeBalAfter - nativeBalBefore;
            if (dust > NATIVE_DUST_LIMIT) revert NativeDustRemaining(dust);
            (bool sent,) = payable(msg.sender).call{value: dust, gas: DUST_REFUND_GAS}("");
            if (!sent) emit NativeDustStranded(msg.sender, dust);
        }
    }

    // -- Refunds ------------------------------------------------------------

    function claimStuckFunds(bytes32 intentId, uint256 legIdx) external nonReentrant {
        bytes32 key = legKey(intentId, legIdx);
        LegState memory st = legState[key];
        if (st.status != LegStatus.BRIDGED) revert LegNotBridged(intentId, legIdx);
        if (block.timestamp <= uint256(st.deadline)) revert RefundNotReady(uint256(st.deadline), block.timestamp);
        if (msg.sender != st.refundRecipient && msg.sender != owner()) {
            revert NotRefundRecipientOrOwner(msg.sender, st.refundRecipient);
        }
        _settleRefund(key, st, false, legIdx, intentId);
    }

    function _settleRefund(bytes32 key, LegState memory st, bool adminReleased, uint256 legIdx, bytes32 intentId)
        private
    {
        uint256 bal = IERC20(st.tokenIn).balanceOf(address(this));
        if (bal < uint256(st.amountIn)) revert RouterLacksRefundBalance(uint256(st.amountIn), bal);
        uint256 reserved = refundReserved[st.tokenIn];
        if (reserved < uint256(st.amountIn)) revert RouterLacksRefundBalance(uint256(st.amountIn), reserved);

        legState[key].status = LegStatus.REFUNDED;
        refundReserved[st.tokenIn] = reserved - uint256(st.amountIn);

        IERC20(st.tokenIn).safeTransfer(st.refundRecipient, uint256(st.amountIn));
        emit LegRefunded(intentId, legIdx, st.refundRecipient, uint256(st.amountIn), adminReleased);
    }

    // -- Owner: configuration (immediate) ----------------------------------

    function setApproveTarget(address provider, address approveTarget) external onlyOwner {
        _validateApproveTarget(approveTarget);
        approveTargetFor[provider] = approveTarget;
        emit ApproveTargetSet(provider, approveTarget);
    }

    /// @notice Tune the active per-intent leg limit without a redeploy. Bounded
    ///         by the immutable ceiling; a count knob only (cannot move funds).
    function setMaxBatchLegs(uint256 newMax) external onlyOwner {
        if (newMax < 1 || newMax > MAX_BATCH_LEGS_CEILING) revert InvalidMaxBatchLegs(newMax);
        maxBatchLegs = newMax;
        emit MaxBatchLegsSet(newMax);
    }

    function killBridge(address provider) external onlyOwner {
        bridgeKilled[provider] = true;
        emit BridgeKilled(provider);
    }

    function unkillBridge(address provider) external onlyOwner {
        bridgeKilled[provider] = false;
        emit BridgeUnkilled(provider);
    }

    function setSettler(address settler, bool allowed) external onlyOwner {
        allowedSettler[settler] = allowed;
        emit SettlerSet(settler, allowed);
    }

    function setSettlerExecution(bool enabled) external onlyOwner {
        settlerExecutionEnabled = enabled;
        emit SettlerExecutionSet(enabled);
    }

    function setTvlCaps(uint256 maxPerIntent, uint256 dailyCap) external onlyOwner {
        maxNotionalUsdPerIntent = maxPerIntent;
        globalDailyUsdCap = dailyCap;
        emit TvlCapsSet(maxPerIntent, dailyCap);
    }

    // -- Owner: withdraw dust / stranded ------------------------------------

    /// @dev Best-effort rescue of stray assets, owner-only and paused-only. For
    ///      ERC-20s the withdrawable amount is the balance minus the refund
    ///      liability for that token, clamped to zero; while legs are bridged
    ///      this is conservative (often zero), which is the safe direction. The
    ///      native branch needs no such guard: native can never be an intent
    ///      input (`tokenIn != NATIVE` is enforced at entry) and per-leg refunds
    ///      only ever hold the ERC-20 `tokenIn`, so no native is reserved.
    function withdraw(address token, address to, uint256 amount) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (token == NATIVE) {
            (bool sent,) = payable(to).call{value: amount}("");
            if (!sent) revert NativeTransferFailed();
        } else {
            // `refundReserved` is a refund-liability counter that stays elevated
            // while legs are bridged, so it can exceed the current balance.
            // Clamp to avoid a permanent underflow revert while still never
            // releasing balance earmarked for a pending refund.
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 reserved = refundReserved[token];
            uint256 free = bal > reserved ? bal - reserved : 0;
            if (amount > free) revert InsufficientWithdrawable(amount, free);
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }

    // -- Internal -----------------------------------------------------------

    function _resolveApproveTo(address provider) internal view returns (address) {
        address stored = approveTargetFor[provider];
        return stored != address(0) ? stored : provider;
    }

    /// @dev Defence-in-depth on the owner-set spender of an ERC-20 approval.
    /// `address(0)` is the sentinel that means "approve the provider itself"
    /// (see `_resolveApproveTo`) and is allowed. The router must never be made
    /// to approve itself or the Permit2 contract as a spender; the per-call
    /// `approveTo != tokenIn` check additionally blocks pointing the approval
    /// at the very token being moved.
    function _validateApproveTarget(address target) internal view {
        if (target == address(this) || target == PERMIT2) revert InvalidApproveTarget(target);
    }

    function _checkAndAccountCaps(address tokenIn, uint256 amountIn) internal {
        if (maxNotionalUsdPerIntent == 0 && globalDailyUsdCap == 0) return;

        uint256 amountUsd = _normaliseUsd(tokenIn, amountIn);
        if (maxNotionalUsdPerIntent != 0 && amountUsd > maxNotionalUsdPerIntent) {
            revert IntentExceedsCap(amountUsd, maxNotionalUsdPerIntent);
        }
        if (globalDailyUsdCap != 0) {
            uint256 today = block.timestamp / 86400;
            if (today != _currentDayBucket) {
                _currentDayBucket = today;
                _currentDayUsd = 0;
            }
            uint256 newTotal = _currentDayUsd + amountUsd;
            if (newTotal > globalDailyUsdCap) revert GlobalDailyCapExceeded(newTotal, globalDailyUsdCap);
            _currentDayUsd = newTotal;
        }
    }

    /// @dev TVL caps are a defence-in-depth throttle, not a hard security
    ///      boundary. This normaliser assumes a USD-pegged input and trusts the
    ///      token's reported `decimals()`; a token with unusual decimals could
    ///      under-report notional and slip under the cap. The real boundary is
    ///      the bridge/selector allowlist (only curated tokens a whitelisted
    ///      bridge accepts can flow) plus backend input validation; the cap
    ///      bounds the blast radius for the expected curated stable inputs.
    function _normaliseUsd(address tokenIn, uint256 amount) internal view returns (uint256) {
        (bool ok, bytes memory ret) = tokenIn.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || ret.length < 32) revert TokenDecimalsUnavailable(tokenIn);
        uint8 dec = abi.decode(ret, (uint8));
        if (dec > 24) revert TokenDecimalsUnavailable(tokenIn);
        if (dec == CAP_DECIMALS) return amount;
        if (dec > CAP_DECIMALS) {
            unchecked {
                return amount / (10 ** (dec - CAP_DECIMALS));
            }
        }
        unchecked {
            return amount * (10 ** (CAP_DECIMALS - dec));
        }
    }

}
