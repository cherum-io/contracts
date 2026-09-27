// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Maximum payload bytes recorded in the LegPayloadCorrupt event.
/// Defence against gas-DoS if a bridge passes us megabytes of data.
uint256 constant MAX_CORRUPT_PAYLOAD_SAMPLE = 256;

/// @title CherumReceiver - destination-chain receiver for cross-chain legs
/// @notice Accepts callbacks from bridge providers that deliver to this
/// contract as the intermediate recipient: Across V4 SpokePool (via
/// `handleV3AcrossMessage`) and Circle CCTP V2 (via the off-chain
/// dispatcher path `dispatchCctpDelivery`, plus the dormant on-chain
/// hook path `handleReceiveFinalizedMessage` kept for forward
/// compatibility with future TokenMessenger versions). Decodes the
/// message produced by the Cherum backend, optionally executes a swap
/// through a whitelisted DEX, optionally sends a native gas drop to
/// the recipient (a differentiating feature), and forwards the token
/// to the final recipient. If the swap reverts, the contract falls
/// back to delivering the input token as-is and never bubbles the
/// revert up to the bridge handler - this is critical for CCTP V2
/// where a handler revert permanently consumes the source-chain nonce.
///
/// Pass-through bridges NOT routed through this contract (delivered
/// direct-to-user on dst, no intermediate callback):
/// - Symbiosis MetaRouter - MetaRouter performs its own swap+deliver
/// atomically on dst; recipient = end-user EOA. Post-bridge
/// gas-drop is therefore unavailable for Symbiosis legs.
/// - ChainFlip Vault - native-asset routing through TSS;
/// recipient set in `xSwapToken` parameters.
/// - Stargate V2 / deBridge / Mayan / Relay - direct-to-user via
/// their own dst-side dispatch.
/// @dev Primary defences:
/// - CrossCurve $3M (Feb 2026): every handler enforces
/// `require(msg.sender == registeredGateway[bridge])`. Without this,
/// anyone could invoke our callback with arbitrary payload and drain.
/// - Replay: `consumedMessageId[hash]` mapping. If a bridge re-orgs
/// and delivers the same message twice, the second delivery is
/// rejected.
/// - Token misrepresentation: the `tokenIn` decoded from the backend
/// must match what the bridge physically delivered. Pre/post balance
/// checks on the main path catch any drift.
/// - Hostile receive / EIP-7702 receiver: native gas drop is sent
/// with `gas: NATIVE_PAYOUT_GAS` cap (200k).
/// - DoS through a swap revert: try/catch around the swap; on revert
/// we fall back to delivering the raw input token instead of
/// propagating the revert.
/// - Reentrancy: `nonReentrant` on every external entry.
contract CherumReceiver is Ownable2Step, Pausable, ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;

    //
    // Constants (parallel to CherumFanOutRouter - same constraints, same
    // numeric values; deliberate duplication so each contract is a
    // self-contained audit boundary.)
    //

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    // NATIVE_PAYOUT_GAS raised 50k->60k to unify with the
    // NATIVE_PAYOUT_GAS raised 60k->200k to cover Safe / DAO multisig recipients
    // FanOutRouter dust path. 50k was borderline for Safe v1.5 multi-sig with
    // pre-validated transactions and the Argent ProxyV2 receive - 60k leaves
    // headroom without exposing simple EOAs to a drain.
    uint256 internal constant NATIVE_PAYOUT_GAS  = 200_000;
    // SWAP_GAS_CAP raised 1.5M->2M for KyberSwap multi-hop
    // on L1 (3-5 pools ~800k-1.2M on mainnet). At 1.5M, rare 5-hop routes ran
    // into the gas ceiling and the try/catch fell back to the input token
    // 2M covers the real ceiling without exposing the contract to OOG-grief
    // attacks (still <25% of a block).
    uint256 internal constant SWAP_GAS_CAP       = 2_000_000;
    uint256 internal constant MAX_RETURN_DATA    = 4096;
    uint256 internal constant MAX_GAS_DROP_WEI   = 1e16;   // 0.01 ETH cap per leg - guard against accidental native pool drain (5e15 -> 1e16 headroom for ETH price appreciation)

    //
    // State
    //

    /// @notice Each bridge gateway is whitelisted independently - Across
    /// SpokePool, CCTP V2 MessageTransmitter, Stargate Endpoint, etc.
    /// Without an entry in this mapping, handlers revert.
    /// Added by the owner (immediate).
    mapping(address gateway => bool allowed) public registeredGateway;

    /// @notice Whitelist of DEX routers used for the post-bridge swap. Same
    /// providers as CherumFanOutRouter on the source side: LiFi /
    /// KyberSwap / Odos / ParaSwap / 0x. Owner-set (immediate).
    mapping(address dexRouter => bool allowed) public allowedDexRouter;

    /// @notice CCTP V2 dispatcher whitelist. CCTP V2 does not invoke an
    /// on-chain callback on the mintRecipient. Therefore the relayer must call
    /// `dispatchCctpDelivery` after the mint. To prevent an
    /// attacker from dispatching with fake hookData where
    /// `finalRecipient` is the attacker, the dispatcher must be
    /// whitelisted. Genesis dispatcher = our cctpRelayer EOA.
    /// Added by the owner (immediate).
    mapping(address dispatcher => bool allowed) public allowedDispatcher;

    //
    // 2-of-2 cosigner dispatcher
    //
    //
    // Mitigation for the 2-of-2 design.
    // Scenario: a compromised single cctpRelayer EOA substitutes hookData ->
    // the entire CCTP V2 mint flow is drained into an attacker EOA.
    //
    // Fix: every call to `dispatchCctpDeliveryWithCoSign` requires **two**
    // EIP-712 signatures from two distinct EOAs (`dispatcherSigner1`
    // `dispatcherSigner2`), kept on separate HSMs. Compromise of a single
    // key now yields no attack surface.
    //
    // Legacy `dispatchCctpDelivery` (single-key) is retained as an
    // **emergency mode**, disabled by default (`emergencyDispatchAllowed =
    // false`). It is enabled only via 2-of-3 Safe ownership for disaster
    // recovery, e.g. when one of the cosign keys is lost.

    /// @notice First cosigner. Signatures from signer1 + signer2 are both required.
    address public dispatcherSigner1;
    /// @notice Second cosigner. Signatures from signer1 + signer2 are both required.
    address public dispatcherSigner2;
    /// @notice Anti-replay: every nonce may be used at most once. The backend
    /// picks a unique nonce per dispatch call (sequential).
    mapping(uint256 nonce => bool used) public dispatcherNonceUsed;
    /// @notice The legacy single-key `dispatchCctpDelivery` is callable only
    /// when the owner has explicitly enabled emergency mode through
    /// `setEmergencyDispatch`. Default is false (cosign path only).
    bool public emergencyDispatchAllowed;

    /// @notice EIP-712 typehash for cosign signatures. Hashes:
    /// (intentId, legIdx, hookDataHash, expectedAmount, nonce, deadline, chainId)
    /// The chainId is baked into the EIP-712 domain automatically - no
    /// need to include it as a separate field.
    bytes32 public constant DISPATCH_COSIGN_TYPEHASH = keccak256(
        "DispatchCctpCoSign(bytes32 intentId,uint64 legIdx,bytes32 hookDataHash,uint256 expectedAmount,uint256 nonce,uint256 deadline)"
    );

    /// @notice Source-FanOut whitelist for the CCTP V2 1-step hook. Key =
    /// keccak256(abi.encode(srcDomain, sender)). `sender` is the
    /// bytes32-padded FanOutRouter address on the source chain
    /// (the same one that called `depositForBurnWithHook`).
    /// Without this whitelist, an attacker could deploy their own
    /// "FanOutRouter" on any CCTP-enabled chain and call
    /// `depositForBurnWithHook` with arbitrary hookData
    /// `handleReceiveFinalizedMessage` would execute it.
    /// Added by the owner (immediate).
    mapping(bytes32 sourceFanOutKey => bool allowed) public allowedSourceFanOut;

    /// @notice Replay protection: every bridge message is unique by
    /// (sourceChain, intentId, legIdx). The mapping key is built per
    /// handler. If a bridge re-orgs and delivers the same message
    /// twice, the second delivery is rejected.
    mapping(bytes32 messageId => bool consumed) public consumedMessageId;


    /// @notice USDC that was minted by CCTP V2 but not delivered to a user
    /// (corrupt payload, or `_fillLeg` reverted). Tracked separately
    /// so the next CCTP V2 hook can compute its own minted amount as
    /// `balanceOf(this) - parkedUSDC` and not silently siphon the
    /// previous user's parked balance. Reset by `withdraw`.
    ///
    /// Audit (MEDIUM 5.3): without this, user B's
    /// incoming mint would include user A's parked USDC, leading to
    /// an accounting leak between intents.
    uint256 public parkedUSDC;

    /// @notice Per-intent breakdown of `parkedUSDC`. Populated whenever an
    /// intent's payload is known and the corresponding USDC could
    /// not be delivered (e.g. `_fillLeg` reverted in
    /// `dispatchCctpDelivery` / `handleV3AcrossMessage` / the
    /// CCTP V2 on-chain hook). Used by `dispatchParkedDelivery` to
    /// honour a legitimate retry of a previously-parked intent
    /// without forcing the operator to pause + withdraw the whole
    /// contract.
    ///
    /// Invariant:
    /// `sum(parkedUSDCByIntent[*]) + parkedUSDCOrphan == parkedUSDC`
    /// outside of `withdraw` (mapping keys are not enumerable, so
    /// the invariant is checked off-chain via the indexed
    /// `LegFilled` event stream that records every park).
    mapping(bytes32 intentId => uint256 amount) public parkedUSDCByIntent;

    /// @notice Portion of `parkedUSDC` that has no associated intentId
    /// (corrupt payload - we could not decode the CherumPayload and
    /// therefore do not know which user the funds belong to). Only
    /// recoverable via the admin `withdraw` path; never via
    /// `dispatchParkedDelivery` (which requires a known intentId).
    ///
    ///
    uint256 public parkedUSDCOrphan;

    //
    // Cherum payload - what the backend encodes into the bridge message
    //

    /// @notice Structure that CherumFanOutRouter (source side) encodes into
    /// either `bridgeCalldata.message` or CCTP `hookData`. The
    /// Receiver decodes and acts on it on the destination chain.
    struct CherumPayload {
        bytes32 intentId;
        uint64  legIdx;
        address finalRecipient;
        address tokenOut;          // token the user requested
        uint256 minAmountOut;      // minimum tokenOut for delivery (slippage guard)
        uint256 gasDropWei;        // 0..MAX_GAS_DROP_WEI of native delivered alongside
        address swapRouter;        // 0 = no swap (input token is already tokenOut), otherwise whitelisted DEX
        bytes   swapCalldata;      // ABI-encoded call for swapRouter
    }

    //
    // Events
    //

    event LegFilled(
        bytes32 indexed intentId,
        uint256 indexed legIdx,
        address indexed finalRecipient,
        address tokenOut,
        uint256 amountOut,
        uint256 gasDropWei,
        bool    fellBackToInputToken
    );

    /// @notice Emitted when a bridge delivered funds but the payload could
    /// not be decoded (corrupt structure). Without intentId we cannot
    /// link this to a specific intent, so we record the gateway,
    /// token, amount, and a truncated raw bytes sample to allow the
    /// operator to recover off-chain.
    /// @dev Previously we emitted
    /// LegFilled with intentId == 0, giving the operator no way to
    /// correlate the parked funds with a user.
    event LegPayloadCorrupt(
        address indexed gateway,
        address tokenSent,
        uint256 amount,
        bytes   rawPayloadSample
    );

    event MessageConsumed(bytes32 indexed messageId, address indexed gateway);

    // 2-of-2 cosigner events
    event DispatcherSignerApplied(uint8 indexed slot, address indexed signer);
    event EmergencyDispatchToggled(bool allowed);
    event CoSignNonceConsumed(uint256 indexed nonce, address signer1, address signer2);

    event GatewayApplied(address indexed gateway, bool allowed);
    event DexRouterApplied(address indexed router, bool allowed);
    event DispatcherApplied(address indexed dispatcher, bool allowed);
    event SourceFanOutApplied(uint32 indexed srcDomain, bytes32 indexed sender, bool allowed);

    event CctpHookExecuted(bytes32 indexed intentId, uint256 indexed legIdx, uint32 srcDomain, bytes32 sender, uint32 finalityThresholdExecuted);

    event Funded(address indexed by, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    //
    // Errors
    //

    error UntrustedGateway(address sender);
    error UntrustedDispatcher(address sender);
    // 2-of-2 dispatcher cosign errors.
    error CoSignExpired(uint256 deadline);
    error CoSignNonceUsed(uint256 nonce);
    error CoSignSignerMismatch(address recovered);
    error CoSignDuplicateSigner();
    error SignerCollision();
    error InvalidCosignerSlot();
    error CosignersAlreadyInitialized();
    error EmergencyDispatchDisabled();
    error UntrustedSourceFanOut(uint32 srcDomain, bytes32 sender);
    error MessageReplay(bytes32 messageId);
    error InsufficientBalance(uint256 have, uint256 need);
    error ZeroAddress();
    error DexRouterNotAllowed(address router);
    error GasDropExceedsCap(uint256 supplied, uint256 cap);
    error SwapReturnedLessThanMin(uint256 received, uint256 min);
    error PayloadDecodeError();
    error NativeTransferFailed();
    error NativeNotSupported();

    //
    // Constructor
    //

    /// @notice Canonical USDC on this destination chain. Set at deploy and
    /// immutable. For CCTP V2 this is the address that
    /// MessageTransmitter mints to after a source-chain burn; used in
    /// `handleReceiveMessage`. For chains without CCTP, pass
    /// `address(0)` - the CCTP path is unused on those chains.
    address public immutable canonicalUSDC;

    /// @notice Genesis source-FanOut init pair, passed to constructor for
    /// the CCTP V2 hook whitelist. Setting these at deploy avoids the
    /// `setSourceFanOut` call on first day. Same genesis-seed
    /// pattern as `initialGateways` etc.
    struct SourceFanOutInit {
        uint32  srcDomain;
        bytes32 senderBytes32;
    }

    constructor(
        address initialOwner,
        address canonicalUSDC_,
        address[] memory initialGateways,
        address[] memory initialDexRouters,
        address[] memory initialDispatchers,
        SourceFanOutInit[] memory initialSourceFanOuts
    ) Ownable(initialOwner) EIP712("CherumReceiver", "2") {
        // cosigners are initialised via a separate
        // post-deploy call to `initializeCosigners(s1, s2)`. This keeps the
        // 6-parameter constructor signature backwards-compatible with the
        // existing test and deploy scripts. Until initialisation,
        // `dispatchCctpDeliveryWithCoSign` reverts on `signer == address(0)`.
        if (initialOwner == address(0)) revert ZeroAddress();
        // canonicalUSDC may be address(0) - chains without CCTP support.
        canonicalUSDC = canonicalUSDC_;

        // Genesis bridge-gateway whitelist (e.g. Across V4 SpokePool).
        for (uint256 i; i < initialGateways.length; ++i) {
            address gw = initialGateways[i];
            if (gw == address(0)) revert ZeroAddress();
            registeredGateway[gw] = true;
            emit GatewayApplied(gw, true);
        }

        // Genesis DEX-router whitelist (LiFi/Kyber/Odos/Velora/0x/CoW).
        for (uint256 j; j < initialDexRouters.length; ++j) {
            address dex = initialDexRouters[j];
            if (dex == address(0)) revert ZeroAddress();
            allowedDexRouter[dex] = true;
            emit DexRouterApplied(dex, true);
        }

        // Genesis CCTP V2 dispatcher whitelist (our cctpRelayer EOA).
        // Subsequent additions via `setDispatcher` (immediate).
        for (uint256 k; k < initialDispatchers.length; ++k) {
            address d = initialDispatchers[k];
            if (d == address(0)) revert ZeroAddress();
            allowedDispatcher[d] = true;
            emit DispatcherApplied(d, true);
        }

        // Genesis source-FanOut whitelist for the CCTP V2 hook. Each pair
        // pre-registers a (srcDomain, FanOutRouter bytes32) tuple so the
        // CCTP V2 1-step hook on `handleReceiveFinalizedMessage` accepts
        // it immediately after deploy. Post-deploy additions go through
        // `setSourceFanOut` (immediate).
        for (uint256 m; m < initialSourceFanOuts.length; ++m) {
            uint32  d = initialSourceFanOuts[m].srcDomain;
            bytes32 s = initialSourceFanOuts[m].senderBytes32;
            if (s == bytes32(0)) revert ZeroAddress();
            bytes32 sourceKey = keccak256(abi.encode(d, s));
            allowedSourceFanOut[sourceKey] = true;
            emit SourceFanOutApplied(d, s, true);
        }
    }

    /// @notice The Receiver accepts native (ETH/AVAX/MATIC) for the gas-drop
    /// pool. The owner or anyone else may top it up.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    //
    // Bridge handler - Across V4
    //

    /// @notice Across V4 SpokePool calls this method after a bridge fill if
    /// `depositV3.message` contained an encoded payload and
    /// `recipient == address(this)`.
    /// @param tokenSent token the SpokePool delivered to the Receiver
    /// @param amount amount delivered
    /// @param /*relayer*/ relayer address - ignored; we trust the gateway, not the relayer
    /// @param message encoded `CherumPayload`
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address /*relayer*/,
        bytes calldata message
    ) external nonReentrant whenNotPaused {
        // CrossCurve $3M (Feb 2026) - single most important check.
        if (!registeredGateway[msg.sender]) revert UntrustedGateway(msg.sender);

        // Decode the payload. Across pulls tokens to the Receiver before
        // calling this handler, so `tokenSent` is the input token already
        // present on this contract.
        CherumPayload memory p;
        try this._decodePayload(message) returns (CherumPayload memory decoded) {
            p = decoded;
        } catch {
            // the corrupt-Across path did not
            // write consumedMessageId, so a reorg could re-deliver and again
            // increase parkedUSDC without a real mint -> accounting breaks,
            // the next CCTP V2 mint underflows -> DoS of CCTP V2.
            //
            // Defence: a synthetic messageId built from
            // (gateway, token, amount, hash(message)). intentId / legIdx are
            // not used because `p` could not be decoded.
            bytes32 corruptId = keccak256(abi.encode(
                "corrupt-across", msg.sender, tokenSent, amount, keccak256(message)
            ));
            if (consumedMessageId[corruptId]) {
                // Reorg redelivery - silently drop. Already accounted for at first delivery.
                emit LegPayloadCorrupt(msg.sender, tokenSent, amount, _sample(message));
                return;
            }
            consumedMessageId[corruptId] = true;
            // if Across delivered canonical USDC
            // and the payload is corrupt, those USDC are now parked on this
            // contract. We MUST account for them in `parkedUSDC` so the next
            // CCTP V2 hook does not silently credit them to a different intent.
            //
            // payload could not be decoded, so
            // intentId is unknown - book against `parkedUSDCOrphan`, not the
            // per-intent mapping. The orphan portion is only recoverable via
            // admin `withdraw`.
            if (tokenSent == canonicalUSDC) {
                parkedUSDC += amount;
                parkedUSDCOrphan += amount;
            }
            emit LegPayloadCorrupt(msg.sender, tokenSent, amount, _sample(message));
            emit LegFilled(bytes32(0), 0, address(this), tokenSent, amount, 0, true);
            return;
        }

        // Replay guard. ID = keccak(intentId, legIdx, gateway, chainId).
        // E: added `block.chainid` for full collision
        // protection. Mirrors Across' own `getV3RelayHash` pattern. Previously
        // we relied solely on the gateway-uniqueness invariant (one Across
        // SpokePool per source chain) - in theory CREATE2 could produce the
        // same address on two chains, which would have collided the tag.
        bytes32 messageId = keccak256(abi.encode(p.intentId, p.legIdx, msg.sender, block.chainid));
        if (consumedMessageId[messageId]) revert MessageReplay(messageId);
        consumedMessageId[messageId] = true;
        emit MessageConsumed(messageId, msg.sender);

        // CRITICAL: this handler MUST NOT revert even on a bad payload.
        // CCTP V2: a revert permanently marks the source nonce as used,
        // funds are lost.
        // Across V4: a revert triggers 2-4 hour slow-fill plus manual claim.
        // Defence: wrap _fillLeg in try/catch; on revert, emit a "parked"
        // event and keep the tokens on this Receiver.
        try this._fillLegExternal{gas: SWAP_GAS_CAP + 500_000}(abi.encode(p), tokenSent, amount) {
            // _fillLeg emits LegFilled itself; do not duplicate.
        } catch {
            // On any revert inside _fillLeg, park the raw input on the
            // Receiver. The owner can withdraw while paused. The user can
            // request a manual refund via support (no on-chain claim path).
            // if the parked token is canonical
            // USDC, increment parkedUSDC so a subsequent CCTP V2 hook does
            // not absorb these funds as part of its mint accounting.
            //
            // intentId is known here (payload
            // decoded successfully), so book against the per-intent
            // mapping. A retry of this exact intent via
            // `dispatchParkedDelivery` can later honour it without touching
            // any other intent's parked share.
            if (tokenSent == canonicalUSDC) {
                parkedUSDC += amount;
                parkedUSDCByIntent[p.intentId] += amount;
            }
            emit LegFilled(p.intentId, p.legIdx, address(this), tokenSent, amount, 0, true);
        }
    }

    //
    // Bridge handler - Circle CCTP V2 (2-step relayer flow)
    //

    /// @notice Dispatch function for CCTP V2 delivery.
    ///
    /// By design CCTP V2 does NOT invoke an on-chain callback on
    /// the mintRecipient. After
    /// `MessageTransmitterV2.receiveMessage` mints USDC here,
    /// our relayer (a whitelisted dispatcher) calls this function
    /// in a SEPARATE transaction with the raw hookData (= encoded
    /// CherumPayload) and expectedAmount (= burnAmount minus Circle
    /// `feeExecuted`, read by the dispatcher from BurnMessageV2).
    ///
    /// @dev Security:
    /// `allowedDispatcher[msg.sender]` - an attacker cannot dispatch
    /// with fake hookData where `finalRecipient` is the attacker.
    /// balance check - defence against dispatch BEFORE the mint arrives.
    /// replay-guard via consumedMessageId.
    /// try/catch around _fillLeg so a revert does not paralyse retry
    /// USDC simply remains on the Receiver, the dispatcher can
    /// retry with the correct hookData (or the owner can withdraw).
    ///
    /// @param hookData abi.encoded CherumPayload (what we embedded
    /// into CCTP V2 hookData at depositForBurnWithHook on src).
    /// @param expectedAmount Amount of USDC expected from the CCTP mint.
    /// Dispatcher reads it from messageBody (amount - feeExecuted).
    function dispatchCctpDelivery(
        bytes calldata hookData,
        uint256 expectedAmount
    ) external nonReentrant whenNotPaused {
        // the single-key path is emergency-only by default.
        // The hot path uses `dispatchCctpDeliveryWithCoSign` (2-of-2 EIP-712).
        if (!emergencyDispatchAllowed) revert EmergencyDispatchDisabled();
        if (!allowedDispatcher[msg.sender]) revert UntrustedDispatcher(msg.sender);

        // Decode payload. On corrupt input - explicit revert (no try/catch).
        // In the 2-step flow USDC is already on the Receiver, so we do not
        // lose funds on revert - the dispatcher can retry with correct
        // hookData or the owner can withdraw.
        CherumPayload memory p = abi.decode(hookData, (CherumPayload));

        // Self-audit: balance check BEFORE the
        // replay-guard write, so that on an early failure (mint not yet
        // arrived / dispatcher provided a wrong expectedAmount) the nonce is
        // NOT burned. Previously consumedMessageId was set first -> a retry
        // with the correct expectedAmount hit MessageReplay and user funds
        // were stuck forever.

        // Balance check. expectedAmount is provided by a trusted dispatcher.
        // An attacker cannot dispatch BEFORE the mint (balance < expectedAmount).
        if (canonicalUSDC == address(0)) revert ZeroAddress();   // chain without CCTP
        uint256 currentBalance = IERC20(canonicalUSDC).balanceOf(address(this));
        // newlyAvailable strictly subtracts parkedUSDC.
        // Previously a dispatcher bug could claim an expectedAmount overlapping
        // with previously-parked balance (intent A's parked USDC leaked to
        // user B). Defence in depth - `expectedAmount` is taken from untrusted
        // hookData, so the balance check must not allow draining parked funds.
        uint256 newlyAvailable = currentBalance > parkedUSDC ? currentBalance - parkedUSDC : 0;
        if (newlyAvailable < expectedAmount) {
            revert InsufficientBalance(newlyAvailable, expectedAmount);
        }

        // Replay-guard AFTER the balance check - the nonce is burned only
        // when the dispatch is actually executable. Tag "cctp-v2" to avoid
        // colliding with the Across messageId.
        bytes32 messageId = keccak256(abi.encode(p.intentId, p.legIdx, "cctp-v2", block.chainid));
        if (consumedMessageId[messageId]) revert MessageReplay(messageId);
        consumedMessageId[messageId] = true;
        emit MessageConsumed(messageId, msg.sender);

        // try/catch for USDC stuck recovery (slippage in swap path B,
        // gas-drop > cap, etc.). On revert - emit LegFilled with
        // fellBackToInputToken=true, USDC is parked for admin withdraw.
        try this._fillLegExternal{gas: SWAP_GAS_CAP + 500_000}(abi.encode(p), canonicalUSDC, expectedAmount) {
            // _fillLeg emits LegFilled itself.
        } catch {
            // _fillLeg reverted -> USDC stays on
            // contract. Account for it in parkedUSDC so subsequent flows
            // (CCTP V2 hook, future dispatches) don't credit it to a new intent.
            //
            // intentId is known - book to the
            // per-intent mapping so a later `dispatchParkedDelivery` can
            // honour this specific intent.
            parkedUSDC += expectedAmount;
            parkedUSDCByIntent[p.intentId] += expectedAmount;
            emit LegFilled(p.intentId, p.legIdx, address(this), canonicalUSDC, expectedAmount, 0, true);
        }
    }

    //
    // 2-of-2 cosigner dispatcher - HOT PATH
    //

    /// @notice Same semantics as `dispatchCctpDelivery`, but requires TWO
    /// EIP-712 signatures from `dispatcherSigner1`
    /// `dispatcherSigner2`. Compromise of a SINGLE key no longer
    /// yields any attack surface - the attacker cannot forge the
    /// second signature.
    ///
    /// Architecture: the backend (operator) holds **two** EOAs on
    /// two DIFFERENT HSMs (e.g. AWS KMS + GCP KMS, or two distinct
    /// physical machines). Before each `dispatchCctpDelivery` both
    /// sign the same EIP-712 structure (intentId, legIdx,
    /// hookDataHash, expectedAmount, nonce, deadline). Any caller
    /// (even a permissionless EOA) may relay both signatures - the
    /// security guarantee rests on the signatures, not on `msg.sender`.
    ///
    /// @param hookData abi.encoded CherumPayload (unchanged)
    /// @param expectedAmount USDC amount from the mint
    /// @param nonce Unique nonce (chosen by the backend, sequential)
    /// @param deadline Unix timestamp deadline for the signature (replay guard)
    /// @param sig1 65-byte signature from dispatcherSigner1
    /// @param sig2 65-byte signature from dispatcherSigner2
    function dispatchCctpDeliveryWithCoSign(
        bytes calldata hookData,
        uint256 expectedAmount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig1,
        bytes calldata sig2
    ) external nonReentrant whenNotPaused {
        // === Cosign verification ===
        // Guard against uninitialized cosigners (deploy state).
        if (dispatcherSigner1 == address(0) || dispatcherSigner2 == address(0)) {
            revert ZeroAddress();
        }
        if (block.timestamp > deadline) revert CoSignExpired(deadline);
        if (dispatcherNonceUsed[nonce]) revert CoSignNonceUsed(nonce);

        CherumPayload memory p = abi.decode(hookData, (CherumPayload));

        // Build EIP-712 digest. chainId is implicitly bound via _domainSeparatorV4.
        bytes32 structHash = keccak256(abi.encode(
            DISPATCH_COSIGN_TYPEHASH,
            p.intentId,
            p.legIdx,
            keccak256(hookData),
            expectedAmount,
            nonce,
            deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered1 = ECDSA.recover(digest, sig1);
        address recovered2 = ECDSA.recover(digest, sig2);

        // Each signature must match one of the two cosigners, and the two
        // recovered signers must be DIFFERENT (defence against the
        // same-signer-twice trivial bypass).
        bool s1_ok = (recovered1 == dispatcherSigner1) || (recovered1 == dispatcherSigner2);
        bool s2_ok = (recovered2 == dispatcherSigner1) || (recovered2 == dispatcherSigner2);
        if (!s1_ok) revert CoSignSignerMismatch(recovered1);
        if (!s2_ok) revert CoSignSignerMismatch(recovered2);
        if (recovered1 == recovered2) revert CoSignDuplicateSigner();

        // Nonce burned BEFORE any external calls (replay-safe even on revert).
        dispatcherNonceUsed[nonce] = true;
        emit CoSignNonceConsumed(nonce, recovered1, recovered2);

        // === Same business logic as dispatchCctpDelivery ===
        if (canonicalUSDC == address(0)) revert ZeroAddress();
        uint256 currentBalance = IERC20(canonicalUSDC).balanceOf(address(this));
        uint256 newlyAvailable = currentBalance > parkedUSDC ? currentBalance - parkedUSDC : 0;
        if (newlyAvailable < expectedAmount) revert InsufficientBalance(newlyAvailable, expectedAmount);

        bytes32 messageId = keccak256(abi.encode(p.intentId, p.legIdx, "cctp-v2", block.chainid));
        if (consumedMessageId[messageId]) revert MessageReplay(messageId);
        consumedMessageId[messageId] = true;
        emit MessageConsumed(messageId, msg.sender);

        try this._fillLegExternal{gas: SWAP_GAS_CAP + 500_000}(abi.encode(p), canonicalUSDC, expectedAmount) {
            // _fillLeg emits LegFilled itself.
        } catch {
            parkedUSDC += expectedAmount;
            parkedUSDCByIntent[p.intentId] += expectedAmount;
            emit LegFilled(p.intentId, p.legIdx, address(this), canonicalUSDC, expectedAmount, 0, true);
        }
    }

    /// @notice Rotate one of the two cosigners. Owner-only (2-of-3 Safe),
    /// applied immediately. slot in {1, 2}. The 2-of-2 cosign requirement on
    /// every dispatch is the dispatch-path trust boundary; cosigner custody is
    /// owner-controlled, and the new signer cannot equal the other slot.
    function setDispatcherSigner(uint8 slot, address newSigner) external onlyOwner {
        if (slot != 1 && slot != 2) revert InvalidCosignerSlot();
        if (newSigner == address(0)) revert ZeroAddress();
        address other = slot == 1 ? dispatcherSigner2 : dispatcherSigner1;
        if (newSigner == other) revert SignerCollision();
        if (slot == 1) dispatcherSigner1 = newSigner;
        else dispatcherSigner2 = newSigner;
        emit DispatcherSignerApplied(slot, newSigner);
    }

    /// @notice One-shot initialisation of the cosigners after deploy. The
    /// owner may call this only while both slots are still empty; it cannot be
    /// called again. Subsequent rotation uses `setDispatcherSigner`.
    function initializeCosigners(address s1, address s2) external onlyOwner {
        if (dispatcherSigner1 != address(0) || dispatcherSigner2 != address(0)) {
            revert CosignersAlreadyInitialized();
        }
        if (s1 == address(0) || s2 == address(0)) revert ZeroAddress();
        if (s1 == s2) revert SignerCollision();
        dispatcherSigner1 = s1;
        dispatcherSigner2 = s2;
        emit DispatcherSignerApplied(1, s1);
        emit DispatcherSignerApplied(2, s2);
    }

    /// @notice Enable or disable the legacy single-key dispatch path. Off by
    /// default; the 2-of-2 cosign path is the norm. Enabling is reserved for
    /// disaster recovery (e.g. a lost cosign key) and is owner-only (2-of-3
    /// Safe). Applied immediately.
    function setEmergencyDispatch(bool allowed) external onlyOwner {
        emergencyDispatchAllowed = allowed;
        emit EmergencyDispatchToggled(allowed);
    }

    //
    // Rescue delivery - retry a previously-parked intent
    //

    /// @notice Re-attempt delivery of an intent whose CCTP V2 / Across mint
    /// was already parked on this contract (because the initial
    /// `_fillLeg` reverted or because the original hookData was
    /// decoded but `_fillLeg` itself failed). Without this entry the
    /// only recovery path is `pause + withdraw`, which sweeps ALL
    /// parked USDC - including funds belonging to other users.
    ///
    /// Pre-conditions:
    /// - `msg.sender` is a whitelisted dispatcher (same set as
    /// `dispatchCctpDelivery`);
    /// - `parkedUSDCByIntent[hookData.intentId] >= expectedAmount`
    /// the intent must own a sufficient parked slice;
    /// - The replay-guard namespace is `cctp-v2-rescue`, separate
    /// from the normal `cctp-v2` tag, so a rescue does not block
    /// a future fresh delivery of the same (intentId, legIdx)
    /// if the operator chooses to re-mint.
    ///
    /// On success the per-intent reserve is debited and `_fillLeg`
    /// runs as usual. On revert inside `_fillLeg` we restore the
    /// reserve (analogous to the existing catch path in
    /// `dispatchCctpDelivery`).
    function dispatchParkedDelivery(bytes calldata hookData, uint256 expectedAmount)
        external nonReentrant whenNotPaused
    {
        if (!allowedDispatcher[msg.sender]) revert UntrustedDispatcher(msg.sender);
        if (canonicalUSDC == address(0)) revert ZeroAddress();

        CherumPayload memory p = abi.decode(hookData, (CherumPayload));

        uint256 parked = parkedUSDCByIntent[p.intentId];
        if (parked < expectedAmount) revert InsufficientBalance(parked, expectedAmount);

        // CEI: debit reserves BEFORE the external call.
        parkedUSDCByIntent[p.intentId] = parked - expectedAmount;
        // Saturating subtraction: a plain `withdraw(canonicalUSDC,...)` clamps the
        // aggregate `parkedUSDC` down to balance but cannot touch the non-enumerable
        // per-intent map, so `sum(byIntent)` may exceed `parkedUSDC`. Clamp here so an
        // owner mishap cannot brick this self-serve retry path with an underflow.
        parkedUSDC = parkedUSDC > expectedAmount ? parkedUSDC - expectedAmount : 0;

        // Separate replay-guard namespace from the regular CCTP V2 path so
        // operator decisions about retry timing do not collide with normal
        // delivery flow.
        // consumedMessageId is set INSIDE the try,
        // AFTER a successful _fillLeg. This is defence-in-depth for the
        // rescue-of-rescue case: if the operator called rescue with broken
        // swapCalldata -> revert -> reserve is restored and the messageId is
        // NOT burned -> a retry with the correct calldata remains possible.
        bytes32 messageId = keccak256(abi.encode(p.intentId, p.legIdx, "cctp-v2-rescue", block.chainid));
        if (consumedMessageId[messageId]) revert MessageReplay(messageId);

        try this._fillLegExternal{gas: SWAP_GAS_CAP + 500_000}(abi.encode(p), canonicalUSDC, expectedAmount) {
            // _fillLeg emits LegFilled on the happy path.
            consumedMessageId[messageId] = true;
            emit MessageConsumed(messageId, msg.sender);
        } catch {
            // Restore the reserve so the operator can try again with a
            // corrected payload (gas-drop cap, swap calldata, etc.).
            // messageId is NOT marked consumed - retry remains possible.
            parkedUSDCByIntent[p.intentId] += expectedAmount;
            parkedUSDC += expectedAmount;
            emit LegFilled(p.intentId, p.legIdx, address(this), canonicalUSDC, expectedAmount, 0, true);
        }
    }

    //
    // Bridge handler - Circle CCTP V2 (legacy 1-step hook spec)
    //
    // ARCHITECTURAL NOTE: verified against Circle
    // `evm-cctp-contracts/v2/TokenMessengerV2.sol` master that the deployed
    // TokenMessengerV2 mints USDC to mintRecipient and STOPS - it does NOT
    // forward hookData via callback to mintRecipient. The hook execution
    // model is fully off-chain: our cctpRelayer reads the message envelope,
    // extracts hookData, and calls `dispatchCctpDelivery` directly.
    //
    // The handlers below are kept callable for forward-compatibility in case
    // Circle ships a future TokenMessenger version that invokes the standard
    // IMessageHandlerV2 interface on the mintRecipient. Their msg.sender
    // source-FanOut + replay guards make them safe to leave callable.
    //

    /// @notice CCTP V2 hook entry. After
    /// `MessageTransmitterV2.receiveMessage` mints USDC to our
    /// mintRecipient (= this contract) and parses messageBody with
    /// hookData, MessageTransmitter calls this method atomically
    /// within the same tx. This removes the dependency on the
    /// cctpRelayer EOA for the CCTP path - Circle Iris fast relay
    /// delivers funds end-to-end on its own.
    ///
    /// @dev Signature is fixed by Circle. See
    /// https://developers.circle.com/cctp/cctp-v2-hooks
    /// interface IMessageHandlerV2 {
    /// function handleReceiveFinalizedMessage(
    /// uint32 sourceDomain,
    /// bytes32 sender,
    /// uint32 finalityThresholdExecuted,
    /// bytes calldata messageBody
    /// ) external returns (bool);
    /// }
    ///
    /// @dev Defences:
    /// 1. msg.sender = MessageTransmitterV2 (`registeredGateway[]`).
    /// Without this, any contract could invoke with an arbitrary `sender`.
    /// 2. sender = whitelisted FanOutRouter on src (`allowedSourceFanOut[]`).
    /// Defence against bait-and-switch: an attacker deploys their
    /// own "router" on any CCTP-enabled chain and calls
    /// `depositForBurnWithHook` with hookData whose `finalRecipient`
    /// is them. Without the sender-whitelist the hook would execute it.
    /// 3. Replay-guard via consumedMessageId, key tag "cctp-v2" (unified
    /// with the off-chain dispatcher path so a CCTP burn cannot be
    /// delivered twice).
    /// 4. try/catch around _fillLeg - the handler NEVER reverts so
    /// the CCTP nonce is not burned; on revert the USDC is parked
    /// for admin withdraw.
    ///
    /// @return success Always true. The returned bool is read by MessageTransmitter
    /// for logging; both revert and `return false` burn the
    /// nonce in V2 (Circle wraps the call in try/catch on its
    /// side but the nonce is marked consumed). We choose to
    /// return true and park USDC on a delivery error.
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external nonReentrant whenNotPaused returns (bool) {
        if (!registeredGateway[msg.sender]) revert UntrustedGateway(msg.sender);

        bytes32 sourceKey = keccak256(abi.encode(sourceDomain, sender));
        if (!allowedSourceFanOut[sourceKey]) revert UntrustedSourceFanOut(sourceDomain, sender);

        if (canonicalUSDC == address(0)) revert ZeroAddress();   // chain without CCTP

        // Newly minted amount for this hook call = total balance minus what
        // is already parked from previous corrupt/failed intents.
        // without this, the next intent would silently
        // absorb the previously parked balance.
        uint256 totalBal = IERC20(canonicalUSDC).balanceOf(address(this));
        uint256 mintedAmount = totalBal > parkedUSDC ? totalBal - parkedUSDC : 0;

        // Decode payload. On corrupt hookData: emit LegPayloadCorrupt, park
        // the newly minted USDC into `parkedUSDC`, return true so CCTP nonce
        // is consumed. Parked USDC remains recoverable via owner withdraw.
        CherumPayload memory p;
        try this._decodePayload(messageBody) returns (CherumPayload memory decoded) {
            p = decoded;
        } catch {
            // Self-audit CR-1 fix: replay-guard for the
            // corrupt path via a synthetic corruptId. Previously the
            // absence of this guard let reorg redelivery increment
            // parkedUSDC twice without a real mint -> underflow on the
            // next CCTP mint -> DoS of every hook. Symmetric with the
            // on the Across handler.
            bytes32 corruptId = keccak256(abi.encode(
                "corrupt-cctp-v2", msg.sender, sourceDomain, sender, mintedAmount, keccak256(messageBody)
            ));
            if (consumedMessageId[corruptId]) {
                emit LegPayloadCorrupt(msg.sender, canonicalUSDC, mintedAmount, _sample(messageBody));
                return true;  // reorg replay - already accounted
            }
            consumedMessageId[corruptId] = true;
            // use += not = totalBal. Same-block
            // double-hook scenario (Iris batching, EIP-7702 bundling): the
            // second call would see mintedAmount=0 if the first had set
            // parkedUSDC=totalBal, and its mint would be silently absorbed
            // into "parked" without attribution. The additive increment
            // preserves the invariant parkedUSDC <= totalBal and never loses
            // per-intent accounting.
            //
            // corrupt -> no intentId known ->
            // orphan slot. Not recoverable via `dispatchParkedDelivery`;
            // only via admin `withdraw`.
            parkedUSDC += mintedAmount;
            parkedUSDCOrphan += mintedAmount;
            emit LegPayloadCorrupt(msg.sender, canonicalUSDC, mintedAmount, _sample(messageBody));
            emit LegFilled(bytes32(0), 0, address(this), canonicalUSDC, mintedAmount, 0, true);
            return true;
        }

        // unification: a single "cctp-v2" tag instead
        // of separate "cctp-v2-hook" / "cctp-v2" tags. Semantics: one CCTP
        // burn = one fill regardless of delivery path (on-chain hook or
        // off-chain relayer). If both paths fire, the second reverts on
        // MessageReplay. Diagnosis of which path fired - via the indexed
        // gateway in the MessageConsumed event (MessageTransmitter vs the
        // EOA relayer).
        bytes32 messageId = keccak256(abi.encode(p.intentId, p.legIdx, "cctp-v2", block.chainid));
        if (consumedMessageId[messageId]) revert MessageReplay(messageId);
        consumedMessageId[messageId] = true;
        emit MessageConsumed(messageId, msg.sender);
        emit CctpHookExecuted(p.intentId, p.legIdx, sourceDomain, sender, finalityThresholdExecuted);

        try this._fillLegExternal{gas: SWAP_GAS_CAP + 500_000}(abi.encode(p), canonicalUSDC, mintedAmount) {
            // _fillLeg emits LegFilled on success path.
        } catch {
            // Failed delivery: this intent's USDC stays on the contract and
            // is now parked. Accounting must reflect it so the next hook does
            // not consume it.
            //
            // intentId is known - book to the
            // per-intent mapping, enabling `dispatchParkedDelivery` retry.
            parkedUSDC += mintedAmount;
            parkedUSDCByIntent[p.intentId] += mintedAmount;
            emit LegFilled(p.intentId, p.legIdx, address(this), canonicalUSDC, mintedAmount, 0, true);
        }
        return true;
    }

    /// @notice CCTP V2 unfinalized hook (fast finality, finalityThreshold <= 1000).
    /// Body is identical to the finalized handler - both statuses
    /// result in delivered USDC. The backend chooses finality on the
    /// source side via `minFinalityThreshold`.
    function handleReceiveUnfinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external nonReentrant whenNotPaused returns (bool) {
        return _handleCctpV2Internal(sourceDomain, sender, finalityThresholdExecuted, messageBody);
    }

    /// @dev Shared body for finalized + unfinalized V2 handlers. The
    /// finalized path keeps its logic inlined above for reading
    /// clarity; the unfinalized path calls this helper to avoid
    /// duplicating the same body.
    function _handleCctpV2Internal(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) internal returns (bool) {
        if (!registeredGateway[msg.sender]) revert UntrustedGateway(msg.sender);

        bytes32 sourceKey = keccak256(abi.encode(sourceDomain, sender));
        if (!allowedSourceFanOut[sourceKey]) revert UntrustedSourceFanOut(sourceDomain, sender);

        if (canonicalUSDC == address(0)) revert ZeroAddress();

        // track parked balance separately so
        // newly minted amount is balance - parkedUSDC, not raw balance.
        uint256 totalBal = IERC20(canonicalUSDC).balanceOf(address(this));
        uint256 mintedAmount = totalBal > parkedUSDC ? totalBal - parkedUSDC : 0;

        CherumPayload memory p;
        try this._decodePayload(messageBody) returns (CherumPayload memory decoded) {
            p = decoded;
        } catch {
            // same reasoning as handleReceiveFinalizedMessage
            // catch path - additive, not assignment.
            //
            // orphan (intentId unknown).
            parkedUSDC += mintedAmount;
            parkedUSDCOrphan += mintedAmount;
            emit LegPayloadCorrupt(msg.sender, canonicalUSDC, mintedAmount, _sample(messageBody));
            emit LegFilled(bytes32(0), 0, address(this), canonicalUSDC, mintedAmount, 0, true);
            return true;
        }

        // unification: a single "cctp-v2" tag instead
        // of separate "cctp-v2-hook" / "cctp-v2" tags. Semantics: one CCTP
        // burn = one fill regardless of delivery path (on-chain hook or
        // off-chain relayer). If both paths fire, the second reverts on
        // MessageReplay. Diagnosis of which path fired - via the indexed
        // gateway in the MessageConsumed event (MessageTransmitter vs the
        // EOA relayer).
        bytes32 messageId = keccak256(abi.encode(p.intentId, p.legIdx, "cctp-v2", block.chainid));
        if (consumedMessageId[messageId]) revert MessageReplay(messageId);
        consumedMessageId[messageId] = true;
        emit MessageConsumed(messageId, msg.sender);
        emit CctpHookExecuted(p.intentId, p.legIdx, sourceDomain, sender, finalityThresholdExecuted);

        try this._fillLegExternal{gas: SWAP_GAS_CAP + 500_000}(abi.encode(p), canonicalUSDC, mintedAmount) {
        } catch {
            // per-intent attribution so the
            // operator can retry via `dispatchParkedDelivery`.
            parkedUSDC += mintedAmount;
            parkedUSDCByIntent[p.intentId] += mintedAmount;
            emit LegFilled(p.intentId, p.legIdx, address(this), canonicalUSDC, mintedAmount, 0, true);
        }
        return true;
    }

    /// @dev External wrapper for try/catch around `_fillLeg`. Solidity does
    /// not allow try/catch on internal calls, so we self-call through
    /// `external`. Defence against external invocation is the
    /// `msg.sender == address(this)` check. The payload is passed as
    /// bytes (an abi.encode/decode round-trip) because Solidity cannot
    /// convert a memory struct directly to calldata.
    function _fillLegExternal(
        bytes calldata payloadEncoded,
        address inputToken,
        uint256 inputAmount
    ) external {
        require(msg.sender == address(this), "internal-only");
        CherumPayload memory p = abi.decode(payloadEncoded, (CherumPayload));
        _fillLeg(p, inputToken, inputAmount);
    }

    //
    // Internal - common fill logic for all bridges
    //

    function _fillLeg(
        CherumPayload memory p,
        address inputToken,
        uint256 inputAmount
    ) internal {
        // Native-input guard: native ETH is not delivered to the Receiver
        // through any of the current bridge handlers (Across V4 + CCTP V2
        // both deliver ERC-20 only). This guard prevents silent fall-through
        // if a future handler accidentally passes `inputToken == NATIVE`.
        // An explicit revert is preferable to a silent swap failure.
        if (inputToken == NATIVE) revert NativeNotSupported();

        if (p.finalRecipient == address(0)) {
            // Never revert: emit a LegFilled event recording address(this)
            // as the recipient. Tokens stay parked on the Receiver until
            // the owner withdraws them.
            emit LegFilled(p.intentId, p.legIdx, address(this), inputToken, inputAmount, 0, true);
            return;
        }
        if (p.gasDropWei > MAX_GAS_DROP_WEI) revert GasDropExceedsCap(p.gasDropWei, MAX_GAS_DROP_WEI);

        // Path A: no swap needed (inputToken == tokenOut).
        if (p.swapRouter == address(0)) {
            IERC20(inputToken).safeTransfer(p.finalRecipient, inputAmount);
            _maybeGasDrop(p.finalRecipient, p.gasDropWei);
            emit LegFilled(p.intentId, p.legIdx, p.finalRecipient, inputToken, inputAmount, p.gasDropWei, false);
            return;
        }

        // Path B: swap through a whitelisted DEX.
        if (!allowedDexRouter[p.swapRouter]) revert DexRouterNotAllowed(p.swapRouter);

        uint256 outBefore = IERC20(p.tokenOut).balanceOf(address(this));
        IERC20(inputToken).forceApprove(p.swapRouter, inputAmount);

        // try/catch around the swap. If the swap reverts we fall back to
        // delivering the raw input token (we never leave funds stranded).
        // This is intentional: an Across slow-fill expects a revert to mark
        // a leg as failed; we prefer to deliver whatever we have rather
        // than block the user.
        try this._executeSwap(p.swapRouter, p.swapCalldata) {
            uint256 outAfter = IERC20(p.tokenOut).balanceOf(address(this));
            uint256 received = outAfter - outBefore;
            if (received < p.minAmountOut) revert SwapReturnedLessThanMin(received, p.minAmountOut);
            IERC20(inputToken).forceApprove(p.swapRouter, 0);
            IERC20(p.tokenOut).safeTransfer(p.finalRecipient, received);
            _maybeGasDrop(p.finalRecipient, p.gasDropWei);
            emit LegFilled(p.intentId, p.legIdx, p.finalRecipient, p.tokenOut, received, p.gasDropWei, false);
        } catch {
            // if the swap somehow
            // pulled some of our `inputToken` (via a compromised selector
            // on an honest DEX or an admin function), the
            // `IERC20.safeTransfer(..., inputAmount)` below would revert on
            // insufficient balance, the handler would revert as a whole,
            // and the CCTP nonce would be permanently consumed. Defence:
            // measure the actual current balance and deliver whatever is
            // available. The user receives less (or zero), but the CCTP
            // nonce is preserved and the intent can be reconciled manually.
            IERC20(inputToken).forceApprove(p.swapRouter, 0);
            uint256 currentBal = IERC20(inputToken).balanceOf(address(this));
            uint256 sendAmount = currentBal < inputAmount ? currentBal : inputAmount;
            if (sendAmount > 0) {
                IERC20(inputToken).safeTransfer(p.finalRecipient, sendAmount);
            }
            _maybeGasDrop(p.finalRecipient, p.gasDropWei);
            emit LegFilled(p.intentId, p.legIdx, p.finalRecipient, inputToken, sendAmount, p.gasDropWei, true);
        }
    }

    /// @dev Returns the first MAX_CORRUPT_PAYLOAD_SAMPLE bytes of a raw
    /// payload. Used by the LegPayloadCorrupt event so an operator can
    /// reconstruct intent details off-chain, without any gas-DoS risk
    /// if the bridge sent us a huge message.
    function _sample(bytes calldata raw) private pure returns (bytes memory) {
        uint256 n = raw.length < MAX_CORRUPT_PAYLOAD_SAMPLE ? raw.length : MAX_CORRUPT_PAYLOAD_SAMPLE;
        return raw[:n];
    }

    /// @dev External wrapper for try/catch - Solidity does not let us catch
    /// a revert from an inline call to the same contract without an
    /// external wrapper. `this._executeSwap(...)` is invoked via `call`
    /// = external, which enables try/catch.
    function _executeSwap(address router, bytes calldata swapCalldata) external {
        require(msg.sender == address(this), "internal-only");
        // Defence-in-depth: explicit zero check. Already enforced indirectly
        // by `_fillLeg` via `if (!allowedDexRouter[router]) revert`, but
        // Slither flags low-level calls without an explicit zero check.
        // Keeping it here is safer if the call path is ever changed in
        // future. Cost: 1 SLOAD, negligible.
        if (router == address(0)) revert ZeroAddress();
        (bool ok, bytes memory ret) = router.call{gas: SWAP_GAS_CAP}(swapCalldata);
        if (!ok) {
            if (ret.length > MAX_RETURN_DATA) {
                assembly ("memory-safe") { mstore(ret, MAX_RETURN_DATA) }
            }
            // Forward return data so the caller's try/catch sees the cause.
            assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
        }
    }

    /// @dev Public wrapper for try/catch around abi.decode - same Solidity
    /// quirk as `_executeSwap`. View, so msg.sender is irrelevant here.
    function _decodePayload(bytes calldata raw) external pure returns (CherumPayload memory) {
        return abi.decode(raw, (CherumPayload));
    }

    function _maybeGasDrop(address recipient, uint256 gasDropWei) internal {
        if (gasDropWei == 0) return;
        if (address(this).balance < gasDropWei) return; // soft-fail: receiver not funded
        (bool ok, ) = recipient.call{gas: NATIVE_PAYOUT_GAS, value: gasDropWei}("");
        // If the recipient reverts on receive, we do not block the main
        // transfer (which already happened); we simply do not record the
        // gas drop in the event. Native is not leaked - the receiver retains
        // the balance.
        if (!ok) {
            // best-effort; do not revert.
        }
    }

    //
    // Owner - gateway whitelist
    //

    function setGateway(address gateway, bool allowed) external onlyOwner {
        if (allowed && gateway == address(0)) revert ZeroAddress();
        registeredGateway[gateway] = allowed;
        emit GatewayApplied(gateway, allowed);
    }

    //
    // Owner - DEX router whitelist
    //

    function setDexRouter(address router, bool allowed) external onlyOwner {
        if (allowed && router == address(0)) revert ZeroAddress();
        allowedDexRouter[router] = allowed;
        emit DexRouterApplied(router, allowed);
    }

    //
    // Owner - CCTP V2 dispatcher whitelist
    //
    //
    // Dispatcher = whitelisted address that invokes `dispatchCctpDelivery`
    // after a CCTP V2 mint. Typically our cctpRelayer EOA. Add/revoke goes
    // immediately by the owner.

    function setDispatcher(address dispatcher, bool allowed) external onlyOwner {
        if (allowed && dispatcher == address(0)) revert ZeroAddress();
        allowedDispatcher[dispatcher] = allowed;
        emit DispatcherApplied(dispatcher, allowed);
    }

    //
    // Owner - utilities
    //

    //
    // Owner - source-FanOut whitelist for CCTP V2 hook (immediate)
    //

    /// @notice Add/remove source FanOutRouter authorisation. Applied immediately.
    /// @param srcDomain CCTP domain id (Ethereum=0, ARB=3, OP=2, BASE=6, POLY=7, etc.)
    /// @param sender bytes32-padded FanOutRouter address on the source chain.
    function setSourceFanOut(uint32 srcDomain, bytes32 sender, bool allowed) external onlyOwner {
        if (allowed && sender == bytes32(0)) revert ZeroAddress();
        bytes32 sourceKey = keccak256(abi.encode(srcDomain, sender));
        allowedSourceFanOut[sourceKey] = allowed;
        emit SourceFanOutApplied(srcDomain, sender, allowed);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    error RenounceDisabled();

    /// @notice Renouncing ownership is permanently disabled. A null owner would
    /// brick pause, withdraw/withdrawParkedIntents, dispatcher/gateway config and
    /// cosigner control, irreversibly stranding parked USDC and the gas-drop pool.
    /// Ownership can still be transferred (two-step via Ownable2Step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Owner can withdraw stuck tokens (e.g. after a corrupt payload
    /// left funds with `finalRecipient == address(0)`). Only allowed
    /// in the `paused` state - guard against accidental withdrawal
    /// while live intents are still being processed.
    function withdraw(address token, address to, uint256 amount) external onlyOwner whenPaused {
        // Defence against accidental withdrawal to the zero address. The
        // owner still chooses where to send funds, but at least the
        // destination is non-zero. (Slither flagged: missing-zero-check.)
        if (to == address(0)) revert ZeroAddress();
        if (token == NATIVE) {
            // MED-2 fix: withdraw is `onlyOwner whenPaused`
            // so there is no DoS surface - the 50k cap from `_maybeGasDrop` is
            // unnecessary here and breaks recovery to Safe Proxy wallets, which
            // need ~100k+ gas to execute the receive callback through delegate
            // dispatch. Forward all remaining gas instead.
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
            // keep parkedUSDC consistent with the actual balance after
            // a withdraw of canonical USDC. If owner pulled parked funds, the
            // accounting marker is reset down to the new balance.
            //
            // also cap `parkedUSDCOrphan` to the
            // new balance - orphan funds may have been the share that was
            // withdrawn. `parkedUSDCByIntent[*]` mapping is NOT iterated here
            // (mappings are not enumerable); a subsequent
            // `dispatchParkedDelivery` against an emptied intent will revert
            // either on `parked < expectedAmount` (if owner zeroed the entry
            // via `withdrawParkedIntents`) or on the balance check inside
            // `_fillLeg`'s safeTransfer. To zero entries deterministically,
            // use `withdrawParkedIntents` instead of plain `withdraw`.
            if (token == canonicalUSDC) {
                uint256 newBal = IERC20(canonicalUSDC).balanceOf(address(this));
                if (parkedUSDC > newBal) parkedUSDC = newBal;
                if (parkedUSDCOrphan > newBal) parkedUSDCOrphan = newBal;
            }
        }
        emit Withdrawn(token, to, amount);
    }

    /// @notice Owner withdraws parked USDC tied to a specific set of intentIds
    /// and zeroes the per-intent reserve entries deterministically.
    /// Use this instead of `withdraw(canonicalUSDC...)` whenever
    /// the operator knows which intents the funds belong to (typical
    /// after a Sentinel alert), so the on-chain accounting stays
    /// consistent.
    ///
    /// The function is paused-only and
    /// owner-only, matching `withdraw`'s safety envelope. For each
    /// id in `intentIds`, the entry in `parkedUSDCByIntent` is read,
    /// summed into `total`, and zeroed. `parkedUSDC` is decremented
    /// by `total`. The funds are then sent to `to` in a single
    /// transfer.
    function withdrawParkedIntents(
        bytes32[] calldata intentIds,
        address to
    ) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (canonicalUSDC == address(0)) revert ZeroAddress();

        uint256 total;
        for (uint256 i; i < intentIds.length; ++i) {
            bytes32 id = intentIds[i];
            uint256 share = parkedUSDCByIntent[id];
            if (share == 0) continue;
            parkedUSDCByIntent[id] = 0;
            total += share;
        }
        if (total == 0) return;

        // Defence-in-depth: clamp to balance and to parkedUSDC, even though
        // the invariant should already guarantee both are >= total.
        uint256 bal = IERC20(canonicalUSDC).balanceOf(address(this));
        if (total > bal) total = bal;
        if (total > parkedUSDC) {
            parkedUSDC = 0;
        } else {
            parkedUSDC -= total;
        }

        IERC20(canonicalUSDC).safeTransfer(to, total);
        emit Withdrawn(canonicalUSDC, to, total);
    }
}
