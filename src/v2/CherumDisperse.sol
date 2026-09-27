// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {CherumPermit2Base} from "./CherumPermit2Base.sol";
import {CherumOrder} from "./CherumOrder.sol";

/// @title CherumDisperse
/// @notice Same-chain batch distribution: one input asset to N recipients in a
///         single atomic transaction. Funds flow sender -> contract ->
///         recipients within one call; nothing rests in the contract between
///         transactions (the post-distribution balance invariant enforces it).
/// @dev    Deliberately minimal: no external calls other than transfers of the
///         dispersed asset itself, no routed calldata, no bridges. The
///         inherited call-target allowlist (CherumCallGuard) gates nothing
///         here because no guarded external call path exists; its setters are
///         inert on this contract. Fee-on-transfer, rebasing and hook-bearing
///         (ERC-777-style) tokens are unsupported and must stay off the
///         frontend token list. The exact-receipt pull check reverts tokens
///         that tax the transfer INTO this contract; the post-batch balance
///         check guarantees no user funds rest here, but a token that taxes the
///         transfer OUT would still under-pay recipients without reverting -
///         hence the off-chain blocklist rather than an on-chain guarantee.
///         Batches are all-or-nothing by design: one failing recipient reverts
///         the whole batch, keeping reconciliation trivial.
///
///         Recipients receive exactly the amounts listed (for standard tokens);
///         both fees are paid by the sender ON TOP of the listed total. The
///         Cherum fee is an
///         absolute signed amount following the off-chain fee schedule,
///         bounded on-chain by MAX_DISPERSE_FEE_BPS; the integrator fee is a
///         basis-point share bounded by the inherited integrator/total caps.
contract CherumDisperse is CherumPermit2Base, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Hard ceiling on the Cherum fee for a disperse, in basis points
    ///         of the batch total. Hardcoded so no admin action can exceed it.
    uint16 public constant MAX_DISPERSE_FEE_BPS = 500; // 5%

    /// @notice Immutable hard ceiling for `maxRecipients`. Set an order of
    ///         magnitude above current per-chain physics (tx gas caps and
    ///         mempool size limits bound a batch to ~650-2000 recipients today)
    ///         so future network upgrades never require a redeploy. An
    ///         over-large batch cannot trap funds - it simply reverts whole.
    uint256 public constant MAX_RECIPIENTS_CEILING = 10_000;

    /// @notice Gas forwarded to each native transfer. Enough for smart-wallet
    ///         recipients (Safe / account-abstraction receive hooks), small
    ///         enough that a hostile recipient cannot burn the batch's gas
    ///         budget. Plain EOAs use a fraction of it.
    uint256 internal constant NATIVE_SEND_GAS = 50_000;

    /// @notice Active per-batch recipient limit. Owner-settable within
    ///         [1, MAX_RECIPIENTS_CEILING]. A count ceiling only: changing it
    ///         cannot move or trap funds.
    uint256 public maxRecipients;

    /// @notice Fee terms for the direct (non-Permit2) entry points. On the
    ///         Permit2 path the same values come from the signed order instead.
    struct DisperseFee {
        // Absolute Cherum fee from the off-chain schedule; capped on-chain.
        uint256 feeAmount;
        // Integrator payout wallet; zero address means no integrator fee.
        address integratorRecipient;
        // Integrator share in basis points; capped by the inherited limit.
        uint16 integratorBps;
    }

    event Dispersed(
        bytes32 indexed intentId,
        address indexed account,
        address indexed token,
        uint256 total,
        uint256 cherumFee,
        uint256 integratorFee,
        uint256 count
    );
    event FeeCollected(bytes32 indexed intentId, address token, address collector, uint256 amount);
    event IntegratorFeeCollected(bytes32 indexed intentId, address token, address recipient, uint256 amount);
    event MaxRecipientsSet(uint256 newMax);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error BatchEmpty();
    error BatchTooLarge(uint256 supplied, uint256 max);
    error LengthMismatch(uint256 recipientsLen, uint256 amountsLen);
    error InvalidRecipient(uint256 index, address recipient);
    error ZeroAmount(uint256 index);
    error DisperseFeeTooHigh(uint256 supplied, uint256 max);
    error RecipientsHashMismatch();
    error NativeFeesHashNotZero();
    error NativeValueMismatch(uint256 expected, uint256 actual);
    error NativeTransferFailed();
    error FoTNotSupported();
    error BalanceInvariant();
    error InvalidMaxRecipients(uint256 supplied);
    error ZeroAddress();

    constructor(address initialOwner, address initialFeeCollector)
        CherumPermit2Base(initialOwner, initialFeeCollector)
    {
        maxRecipients = 500;
        emit MaxRecipientsSet(500);
    }

    // -- Read helpers --------------------------------------------------------

    /// @notice Canonical hash of a recipient batch, committed as `legsHash` in
    ///         the signed order on the Permit2 path.
    function hashRecipients(address[] calldata recipients, uint256[] calldata amounts)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(recipients, amounts));
    }

    // -- Entry: ERC-20, direct allowance path --------------------------------

    /// @notice Disperse an ERC-20 from the caller under a prior approval for
    ///         total + fees. Recipients receive exactly `amounts`.
    /// @param intentId Off-chain accounting reference, emitted verbatim. The first
    ///        byte tags the originating surface; uniqueness lives off-chain.
    function disperseToken(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts,
        DisperseFee calldata fee,
        bytes32 intentId
    ) external nonReentrant whenNotPaused {
        uint256 total = _validateBatch(recipients, amounts);
        (uint256 cherumFee, uint256 integratorFee) =
            _resolveDisperseFees(total, fee.feeAmount, fee.integratorRecipient, fee.integratorBps);

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), total + cherumFee + integratorFee);
        if (IERC20(token).balanceOf(address(this)) - balBefore != total + cherumFee + integratorFee) {
            revert FoTNotSupported();
        }

        _payTokenFees(token, intentId, cherumFee, integratorFee, fee.integratorRecipient);
        _sendTokenBatch(token, recipients, amounts);
        // The contract must not have dipped below its pre-existing balance:
        // that would mean it paid out more than it pulled this call. A surplus
        // (bal > balBefore) can only arise from an unsupported hook/FoT token
        // and is left as a sweepable stray rather than bricking the batch, so
        // a hostile hook-token recipient cannot grief by donating mid-batch.
        if (IERC20(token).balanceOf(address(this)) < balBefore) revert BalanceInvariant();

        emit Dispersed(intentId, msg.sender, token, total, cherumFee, integratorFee, recipients.length);
    }

    // -- Entry: ERC-20, single-signature Permit2 path -------------------------

    /// @notice Disperse an ERC-20 pulled from `order.account` under one Permit2
    ///         witness signature. The order commits the batch
    ///         (`legsHash = hashRecipients(...)`), the reference
    ///         (`intentId`), the fee terms and the deadline, so a relayer can
    ///         submit without being able to alter any of them.
    function disperseTokenPermit2(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts,
        CherumOrder.Order calldata order,
        uint256 permit2Nonce,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _authorizeCaller(order.account);
        if (hashRecipients(recipients, amounts) != order.legsHash) revert RecipientsHashMismatch();
        // Same-chain orders sign a zero native-fees hash (CherumOrder convention).
        if (order.nativeFeesHash != bytes32(0)) revert NativeFeesHashNotZero();

        uint256 total = _validateBatch(recipients, amounts);
        (uint256 cherumFee, uint256 integratorFee) =
            _resolveDisperseFees(total, order.signedFeeAmount, order.integratorRecipient, order.integratorBps);

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _pullInput(token, total + cherumFee + integratorFee, permit2Nonce, order, signature);
        if (IERC20(token).balanceOf(address(this)) - balBefore != total + cherumFee + integratorFee) {
            revert FoTNotSupported();
        }

        _payTokenFees(token, order.intentId, cherumFee, integratorFee, order.integratorRecipient);
        _sendTokenBatch(token, recipients, amounts);
        // See disperseToken: `< balBefore` (not `!=`) so a hook-token donation
        // cannot grief the batch; a surplus is a sweepable stray.
        if (IERC20(token).balanceOf(address(this)) < balBefore) revert BalanceInvariant();

        emit Dispersed(
            order.intentId, order.account, token, total, cherumFee, integratorFee, recipients.length
        );
    }

    // -- Entry: native coin ----------------------------------------------------

    /// @notice Disperse the native coin. `msg.value` must equal total + fees
    ///         exactly - no change is returned by design, so the contract
    ///         balance is provably untouched without a trailing check.
    function disperseNative(
        address[] calldata recipients,
        uint256[] calldata amounts,
        DisperseFee calldata fee,
        bytes32 intentId
    ) external payable nonReentrant whenNotPaused {
        uint256 total = _validateBatch(recipients, amounts);
        (uint256 cherumFee, uint256 integratorFee) =
            _resolveDisperseFees(total, fee.feeAmount, fee.integratorRecipient, fee.integratorBps);
        if (msg.value != total + cherumFee + integratorFee) {
            revert NativeValueMismatch(total + cherumFee + integratorFee, msg.value);
        }

        if (cherumFee != 0) {
            _sendNative(feeCollector, cherumFee);
            emit FeeCollected(intentId, NATIVE, feeCollector, cherumFee);
        }
        if (integratorFee != 0) {
            _sendNative(fee.integratorRecipient, integratorFee);
            emit IntegratorFeeCollected(intentId, NATIVE, fee.integratorRecipient, integratorFee);
        }
        uint256 len = recipients.length;
        for (uint256 i; i < len;) {
            _sendNative(recipients[i], amounts[i]);
            unchecked {
                ++i;
            }
        }

        emit Dispersed(intentId, msg.sender, NATIVE, total, cherumFee, integratorFee, len);
    }

    // -- Owner ------------------------------------------------------------------

    /// @notice Tune the active recipient limit within the immutable ceiling.
    function setMaxRecipients(uint256 newMax) external onlyOwner {
        if (newMax == 0 || newMax > MAX_RECIPIENTS_CEILING) revert InvalidMaxRecipients(newMax);
        maxRecipients = newMax;
        emit MaxRecipientsSet(newMax);
    }

    /// @notice Rescue of stray assets, owner-only and paused-only. The contract
    ///         holds no funds between transactions (balance invariant), so any
    ///         resting balance is a mistaken direct transfer.
    function withdraw(address token, address to, uint256 amount) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (token == NATIVE) {
            (bool sent,) = payable(to).call{value: amount}("");
            if (!sent) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }

    // -- Internal ----------------------------------------------------------------

    /// @dev Structural checks plus the batch total. Checked addition guards
    ///      overflow on the sum.
    function _validateBatch(address[] calldata recipients, uint256[] calldata amounts)
        private
        view
        returns (uint256 total)
    {
        uint256 len = recipients.length;
        if (len == 0) revert BatchEmpty();
        if (len != amounts.length) revert LengthMismatch(len, amounts.length);
        if (len > maxRecipients) revert BatchTooLarge(len, maxRecipients);
        for (uint256 i; i < len;) {
            address to = recipients[i];
            // address(this) is refused so the post-batch balance invariant
            // stays the honest "nothing rests here" statement.
            if (to == address(0) || to == address(this)) revert InvalidRecipient(i, to);
            if (amounts[i] == 0) revert ZeroAmount(i);
            total += amounts[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Disperse-specific Cherum-fee ceiling first, then the inherited
    ///      integrator/total caps. All measured against the batch total.
    function _resolveDisperseFees(
        uint256 total,
        uint256 signedFeeAmount,
        address integratorRecipient,
        uint16 integratorBps
    ) private pure returns (uint256 cherumFee, uint256 integratorFee) {
        uint256 maxCherum = (total * MAX_DISPERSE_FEE_BPS) / BPS_DENOMINATOR;
        if (signedFeeAmount > maxCherum) revert DisperseFeeTooHigh(signedFeeAmount, maxCherum);
        (cherumFee, integratorFee) = _resolveFees(total, signedFeeAmount, integratorRecipient, integratorBps);
    }

    function _payTokenFees(
        address token,
        bytes32 intentId,
        uint256 cherumFee,
        uint256 integratorFee,
        address integratorRecipient
    ) private {
        if (cherumFee != 0) {
            IERC20(token).safeTransfer(feeCollector, cherumFee);
            emit FeeCollected(intentId, token, feeCollector, cherumFee);
        }
        if (integratorFee != 0) {
            IERC20(token).safeTransfer(integratorRecipient, integratorFee);
            emit IntegratorFeeCollected(intentId, token, integratorRecipient, integratorFee);
        }
    }

    function _sendTokenBatch(address token, address[] calldata recipients, uint256[] calldata amounts) private {
        uint256 len = recipients.length;
        for (uint256 i; i < len;) {
            IERC20(token).safeTransfer(recipients[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Native send with a fixed gas allowance (see NATIVE_SEND_GAS). A
    ///      reverting recipient reverts the whole batch - all-or-nothing.
    function _sendNative(address to, uint256 amount) private {
        (bool sent,) = payable(to).call{value: amount, gas: NATIVE_SEND_GAS}("");
        if (!sent) revert NativeTransferFailed();
    }
}
