// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {CherumAdmin} from "./CherumAdmin.sol";

/// @title CherumClaim
/// @notice Escrowed distribution: the sender funds a campaign against a Merkle
///         root once, and each listed recipient withdraws their own amount and
///         pays their own gas. Whatever is never withdrawn returns to the sender
///         after the campaign expires.
///
/// @dev    This is the second delivery mode, not a replacement for the first.
///         Pushing (CherumDisperse) costs ~25.5k gas per ERC-20 recipient
///         against ~80k to claim from a tree here, so pull is three to four
///         times more expensive in total gas. It exists for the two cases a push
///         cannot serve: the recipient has no address yet, or the list is large
///         enough that funding everyone up front is pointless. Break-even is
///         around a 30% claim rate; the observed average is 19.1%.
///
///         Deliberately narrow. No upgrade proxy: whoever can swap the logic
///         effectively controls the money. Campaigns are independent, so a
///         second version deploys alongside and takes new campaigns - there is
///         nothing to migrate. No privileged function can reach campaign funds
///         at all: the sole recovery path, `sweepStrayNative`, is bounded by the
///         provable excess over `held` AND confined to the native coin. That is
///         the exact hole behind the ZKsync `sweepUnclaimed()` loss, shut twice
///         over. The price is that an ERC-20 sent here by mistake is gone for
///         good - see `sweepStrayNative` for why no honest token sweep exists.
///
///         Fee-on-transfer, rebasing and hook-bearing (ERC-777-style) tokens are
///         unsupported and must stay off the frontend token list. Every ERC-20
///         movement in this contract - funding, both fee legs, claims, refunds -
///         asserts the exact balance delta on OUR side, which is what keeps
///         `held` truthful. That rejects a token taxing the transfer IN, and a
///         token that bills the tax on top of the amount when we send. What it
///         cannot see is a token that debits us exactly `amount` and hands the
///         recipient less: our books stay right and the claimant is short. That
///         one only the off-chain blocklist catches, and so does a token that
///         turns a fee on later behind an upgradeable proxy.
contract CherumClaim is CherumAdmin, EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Sentinel for the native coin, shared with the rest of the V2
    ///         family. `address(0)` is refused outright so "native" has exactly
    ///         one spelling and an uninitialised campaign can never look funded.
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceilings on fees. These mirror `CherumFeeBase`
    ///         (MAX_TOTAL_FEE_BPS / MAX_INTEGRATOR_FEE_BPS) and
    ///         `CherumDisperse.MAX_DISPERSE_FEE_BPS` by value, and a test
    ///         asserts they stay equal. They are re-declared rather than
    ///         inherited because `CherumFeeBase` sits on top of
    ///         `CherumCallGuard`, whose target/selector allowlist has no meaning
    ///         here - this contract makes no routed external calls - and an
    ///         inert privileged surface is worse than a duplicated constant.
    uint16 public constant MAX_CLAIM_FEE_BPS = 500; // 5%
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 500; // 5%
    uint16 public constant MAX_TOTAL_FEE_BPS = 1_000; // 10%

    /// @notice Gas forwarded to each native claim payout. Enough for smart-wallet
    ///         recipients (Safe / account-abstraction receive hooks), small
    ///         enough that a hostile recipient cannot drain a batch's gas budget
    ///         in `claimMany`. A recipient can still revert and take the whole
    ///         batch down with them - claims are all-or-nothing within one call,
    ///         same as `CherumDisperse` - but the leaf stays unspent, so nothing
    ///         is lost and it can be claimed on its own afterwards.
    ///         Measured budget inside the recipient's hook: 52,231 gas (this
    ///         stipend plus the 2,300 the EVM adds for a value transfer), which
    ///         covers about two cold storage writes.
    ///         NOT applied to refunds - see `refund`.
    uint256 internal constant NATIVE_SEND_GAS = 50_000;

    /// @notice Campaign lifetime bounds. Zero is forbidden: Sablier leaves the
    ///         expiry optional, and a campaign created without one becomes
    ///         permanently unrefundable seven days after its first claim - the
    ///         money stays in the contract forever.
    uint64 public constant MIN_DURATION = 7 days;
    uint64 public constant MAX_DURATION = 365 days;

    /// @notice Hard ceiling on `claimMany`. An unbounded loop counts as a DoS
    ///         surface even when the caller creates the state themselves.
    /// @dev    Every number here is a transaction receipt from a real node -
    ///         `script/v2/MeasureClaimGas.s.sol` reproduces all of them. Not a
    ///         `gasleft()` reading inside a test: that measurement charges the
    ///         caller's ABI-encoding of 150 nested proof arrays to the callee,
    ///         and this comment previously carried the inflated figure
    ///         (11,796,948 against a true 10,388,306, 13.6% too high) with a test
    ///         asserting the inflated one back.
    ///
    ///         A full batch of 150 on the NATIVE path, every recipient a
    ///         brand-new account, which is the worst case the ceiling is set
    ///         from: **10,388,306** all-in (9,667,650 execution + 720,656
    ///         intrinsic and calldata), 69,255 per leaf. Token path is cheaper -
    ///         9,253,083 for the same 150, 61,687 per leaf - because a cold token
    ///         balance is a 20,000 slot write against the native path's 25,000
    ///         account creation. Recipients that already exist cost 25,000 less
    ///         each, and that surcharge is the whole spread between the two.
    ///
    ///         The per-transaction ceiling is 2^24 = 16,777,216 on Ethereum,
    ///         Base, Optimism and BSC. A full batch uses 61.9% of it and leaves
    ///         38.1% free. Marginal cost measured over 50 -> 150 leaves is 69,551
    ///         each, so the true ceiling sits near 241 leaves; the extrapolation
    ///         holds because proof depth stays at 8 all the way to 256.
    ///
    ///         So 150 is NOT the largest batch that fits, and the honest reason
    ///         to stop here is not arithmetic: it is that a claimant's wallet
    ///         estimates gas before it signs, and 38% of margin is what keeps an
    ///         ordinary batch from dying of out-of-gas and looking like a
    ///         contract bug when a recipient turns out to be a smart wallet with
    ///         a heavier receive hook than the ones measured.
    ///
    ///         On HyperEVM the small block is 3,000,000. 50 leaves cost 3,433,173
    ///         there, so roughly 43 fit - the interface picks the real batch size
    ///         per chain; this is only the backstop.
    uint256 public constant MAX_CLAIM_BATCH = 150;

    /// @notice Hard ceiling on proof length. 32 levels is 2^32 leaves; a real
    ///         100,000-row list needs 17.
    /// @dev    Be precise about what this does, because on a modern chain the
    ///         answer is nothing. A bogus 4,000-element proof was sent to a real
    ///         node: the call reverted at this check having executed almost
    ///         nothing, and the transaction was still billed **5,130,810**. That
    ///         is EIP-7623's calldata floor, 21,000 + 10 x (zero + 4 x non-zero)
    ///         bytes, which a transaction pays whenever its execution is small
    ///         relative to the data it carries. Verifying all 4,000 levels would
    ///         have cost around 1.2M of execution - still far under the 3,065,886
    ///         of headroom before the floor stops binding - so the bill would
    ///         have been the same 5,130,810 to the gas unit.
    ///
    ///         Kept anyway, for two honest reasons: chains that have not adopted
    ///         Prague have no floor, and there the early exit does save the
    ///         execution; and a bounded loop is worth having on its own terms.
    ///         But it buys nothing on Ethereum, Base or Optimism today, and the
    ///         previous version of this comment claimed it cut 1.2M out of 3.3M,
    ///         which was never true after Prague.
    ///
    ///         The real defence for a sponsoring relayer is elsewhere: simulate
    ///         first and cap gas at the transaction level. `claimViaSig` used to
    ///         hand an ERC-1271 wallet every unit of remaining gas before it knew
    ///         the leaf was real; it now verifies the proof first, so an invented
    ///         `account` never reaches the signature check at all.
    uint256 public constant MAX_PROOF_LENGTH = 32;

    /// @dev EIP-712 type for redirecting a claim to a different address. Signed
    ///      by the listed recipient and nobody else. No nonce: a claim is
    ///      single-use by construction (`claimedOf`), so a replay cannot pay
    ///      twice. `validFrom`/`deadline` are chosen by the SIGNER, not bounded
    ///      by the contract: `deadline = type(uint256).max` is accepted and then
    ///      the signature lives as long as the campaign does (at most 365 days,
    ///      because claiming stops at expiry). The interface should offer a short
    ///      window by default; the contract only enforces the one it is given.
    ///      Only a 65-byte (r,s,v) signature is accepted - OpenZeppelin 5.x
    ///      dropped ERC-2098 compact signatures. A wallet needing ERC-7739
    ///      nested signatures will fail this path closed and can use `claim`.
    bytes32 private constant CLAIM_TO_TYPEHASH = keccak256(
        "ClaimTo(bytes32 campaignId,uint256 index,address account,address to,uint256 amount,uint256 validFrom,uint256 deadline)"
    );

    struct Campaign {
        address funder; // who paid in, and the only address that can refund
        uint64 expiry; // claims close here; refund opens here
        bool refunded;
        // When set, the plain `claim` is refused and only `claimViaSig` works.
        // For the "recipient has no address yet" case a leaf has to name an
        // interim address whose key comes from the link, and the real
        // destination arrives later in the recipient's signature. With an open
        // `claim` anyone watching the published list could force the payout to
        // that interim address first and strip the redirect - so the campaign
        // says up front which mode it is in. Chosen at creation, immutable
        // after: the leaf format cannot be changed later, and neither can this.
        bool sigOnly;
        address token; // NATIVE sentinel for the native coin
        bytes32 root; // immutable for the campaign's whole life
        // The funded principal. Exact receipt is enforced at creation, so this
        // is the money actually in escrow and any claimant can read it. It does
        // NOT prove the tree sums to the same number: the contract holds 32
        // bytes of root and cannot see the leaves. Checking "sum of leaves ==
        // total" belongs to the interface, which must say so plainly.
        uint256 total;
        uint256 paidOut;
    }

    /// @notice Campaigns by id. The id is chosen by the funder, not by a
    ///         counter - see `campaignIdFor`.
    mapping(bytes32 => Campaign) public campaigns;

    /// @notice Pointer to the full list (a content id, typically). The contract
    ///         holds 32 bytes of root; a proof needs the whole list, and a lost
    ///         list makes claiming impossible in principle - preimages cannot be
    ///         guessed. Kept on-chain next to the root rather than on a status
    ///         page of ours, which would be a single point of failure.
    ///         The contract does NOT and cannot verify that the content behind
    ///         this pointer matches the root: it is a convenience, not a
    ///         guarantee, and the interface says so.
    mapping(bytes32 => string) public listURI;

    /// @notice Amount already withdrawn per (campaign, leaf index). Cumulative
    ///         rather than a bitmap on purpose: a bitmap saves 17,100 gas only
    ///         from the second claim within the same 256-bit word, and at the
    ///         20-40% claim rates we expect a word holds one or two claimants,
    ///         so the saving disappears - on an untouched word it is ~100 gas
    ///         worse. Every live distributor of 2024-2026 (Merkl, Morpho,
    ///         EigenLayer) uses cumulative accounting.
    mapping(bytes32 => mapping(uint256 => uint256)) public claimedOf;

    /// @notice Principal owed to campaigns, per asset. Kept for every asset, but
    ///         only the NATIVE entry bounds anything: `sweepStrayNative` may
    ///         touch the balance above it and nothing else, which is what makes
    ///         it impossible for any privileged call to reach escrowed money.
    ///         For ERC-20s this is bookkeeping a claimant can read, not a
    ///         permission gate - there is no token sweep to gate.
    mapping(address => uint256) public held;

    /// @notice How many campaigns have been created. Statistics only: no code
    ///         path in this contract reads it, and it is not an identifier. The
    ///         deploy script and a test do read it, to assert a fresh contract
    ///         starts at zero.
    uint256 public campaignCount;

    /// @notice Recipient of the Cherum fee. Must be a code-free EOA when set, so
    ///         the fee stream cannot be pointed at a contract and the fee
    ///         transfer carries no receiver-side callback. It can still acquire
    ///         code afterwards (an EIP-7702 delegation, or a CREATE2 deploy to
    ///         that address); a fee transfer would then start reverting and
    ///         block campaign creation until the owner points it elsewhere. The
    ///         owner is trusted to keep it code-free.
    address public feeCollector;

    event CampaignCreated(
        bytes32 indexed campaignId,
        address indexed funder,
        address indexed token,
        bytes32 root,
        uint256 total,
        uint64 expiry,
        bool sigOnly,
        string listURI
    );
    event Claimed(
        bytes32 indexed campaignId, uint256 indexed index, address indexed account, address to, uint256 amount
    );
    event Refunded(bytes32 indexed campaignId, address indexed funder, address to, uint256 amount);
    event ListURISet(bytes32 indexed campaignId, string listURI);
    event FeeCollected(bytes32 indexed campaignId, address token, address collector, uint256 amount);
    event IntegratorFeeCollected(bytes32 indexed campaignId, address token, address recipient, uint256 amount);
    event StraySwept(address indexed token, address indexed to, uint256 amount);
    event FeeCollectorSet(address indexed newCollector);

    error ZeroAddress();
    /// @dev A non-zero address that still may not be used: this contract itself.
    error SelfNotAllowed();
    error FeeCollectorMustBeEOA();
    error ZeroRoot();
    error ZeroTotal();
    error NativeMustUseSentinel();
    error CampaignExists(bytes32 campaignId);
    error BadDuration(uint64 supplied, uint64 min, uint64 max);
    error ClaimFeeTooHigh(uint256 supplied, uint256 max);
    error IntegratorFeeTooHigh(uint16 bps);
    error TotalFeeTooHigh(uint256 total, uint256 maxTotal);
    error NativeValueMismatch(uint256 expected, uint256 actual);
    error NativeValueNotZero();
    error FoTNotSupported();
    error UnknownCampaign(bytes32 campaignId);
    error CampaignExpired(bytes32 campaignId, uint64 expiry);
    error CampaignLive(bytes32 campaignId, uint64 expiry);
    error CampaignRefunded(bytes32 campaignId);
    error ClaimNeedsSignature(bytes32 campaignId);
    error BadProof(bytes32 campaignId, uint256 index);
    error ProofTooLong(uint256 supplied, uint256 max);
    error AlreadyClaimed(bytes32 campaignId, uint256 index);
    error ZeroLeafAmount(bytes32 campaignId, uint256 index);
    error InvalidLeafAccount(address account);
    error Underfunded(bytes32 campaignId, uint256 need, uint256 have);
    error NotFunder(address caller, address funder);
    error NativeTransferFailed();
    error BadSignature();
    error SignatureNotYetValid(uint256 validFrom);
    error SignatureExpired(uint256 deadline);
    error BatchEmpty();
    error BatchTooLarge(uint256 supplied, uint256 max);
    error LengthMismatch();
    error ZeroSweepAmount();
    error NothingToSweep(uint256 requested, uint256 stray);

    constructor(address initialOwner, address initialFeeCollector)
        CherumAdmin(initialOwner)
        EIP712("CherumClaim", "1")
    {
        if (initialFeeCollector == address(0)) revert ZeroAddress();
        if (initialFeeCollector.code.length != 0) revert FeeCollectorMustBeEOA();
        feeCollector = initialFeeCollector;
    }

    // -- Read helpers ---------------------------------------------------------

    /// @notice The id a campaign will have. The funder picks `salt`; nothing
    ///         about the id depends on when the transaction lands.
    /// @dev    A sequential counter looked simpler and was a real defect. The
    ///         id goes inside every leaf, so the tree has to be built before the
    ///         transaction is sent - and with `++campaignCount` the funder
    ///         cannot know their own id. Anybody creating a campaign in the same
    ///         block shifted it, and then every proof failed while the money sat
    ///         in escrow until expiry (up to 365 days) with no early way out.
    ///         That happens by accident whenever two funders overlap, not just
    ///         under attack. Deriving the id from the funder plus their own salt
    ///         removes the race entirely: it is knowable in advance and nobody
    ///         else can take it.
    ///
    ///         `block.chainid` and `address(this)` are in the preimage too, so
    ///         the same list produces different ids - and therefore different
    ///         leaves and a different root - on every chain and on every
    ///         deployment. A tree built for one network is worthless on another
    ///         even though we deploy the same bytecode to seven of them.
    function campaignIdFor(address funder, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), funder, salt));
    }

    /// @notice The canonical leaf. Double-hashed without exception.
    /// @dev    What actually rules out a second-preimage attack here is that a
    ///         leaf can only ever be built BY THIS FUNCTION out of a 128-byte
    ///         `abi.encode` of four static fields: there is no entry point that
    ///         accepts a raw leaf, so passing an internal node in place of one
    ///         means finding a preimage of keccak256. The second hash is the
    ///         margin on top and the reason our trees interoperate with
    ///         StandardMerkleTree from the OpenZeppelin merkle-tree package
    ///         (never SimpleMerkleTree, whose double hashing is off by
    ///         definition). `MerkleProof.sol` carries an explicit WARNING about
    ///         64-byte leaves and does not defend against them itself - hence
    ///         both the encoding width and the double hash are stated here as
    ///         invariants a future edit must not break.
    function leafOf(bytes32 campaignId, uint256 index, address account, uint256 amount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(campaignId, index, account, amount))));
    }

    /// @notice Principal still in escrow for a campaign.
    function remainingOf(bytes32 campaignId) external view returns (uint256) {
        Campaign storage c = campaigns[campaignId];
        if (c.funder == address(0)) revert UnknownCampaign(campaignId);
        return c.refunded ? 0 : c.total - c.paidOut;
    }

    /// @notice EIP-712 digest a recipient signs to redirect their claim.
    function claimToDigest(
        bytes32 campaignId,
        uint256 index,
        address account,
        address to,
        uint256 amount,
        uint256 validFrom,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_TO_TYPEHASH, campaignId, index, account, to, amount, validFrom, deadline))
        );
    }

    // -- Create ---------------------------------------------------------------

    /// @notice Fund a campaign. The full principal must arrive now: a claimant
    ///         must be able to see on-chain that the money is there, and a
    ///         partially funded campaign gives them no way to tell.
    /// @param salt The funder's own handle for this campaign; the id is
    ///        `campaignIdFor(msg.sender, salt)` and must be unused.
    /// @param token ERC-20 address, or the NATIVE sentinel for the native coin.
    /// @param sigOnly Refuse the plain `claim` for this campaign; see the struct.
    /// @param feeAmount Absolute Cherum fee, charged once at creation on the
    ///        whole principal - not per claim, so a claimant's gas stays as low
    ///        as it can be, and NOT reduced when part of the principal comes back
    ///        unclaimed. The rate for a campaign expected to go largely
    ///        unclaimed is a matter for the off-chain tariff matrix, which
    ///        changes without a redeploy. On-chain there is only the ceiling
    ///        `MAX_CLAIM_FEE_BPS`; the amount itself is supplied by the caller,
    ///        exactly as on `CherumDisperse`'s direct path, so a caller who goes
    ///        straight to the contract can pay nothing. That is a business fact,
    ///        not a safety property, and it is deliberate.
    /// @param duration Campaign lifetime from now, within [MIN, MAX] DURATION.
    function createCampaign(
        bytes32 salt,
        address token,
        bytes32 root,
        uint256 total,
        uint64 duration,
        bool sigOnly,
        string calldata listUri,
        uint256 feeAmount,
        address integratorRecipient,
        uint16 integratorBps
    ) external payable nonReentrant whenNotPaused returns (bytes32 campaignId) {
        if (token == address(0)) revert NativeMustUseSentinel();
        if (root == bytes32(0)) revert ZeroRoot();
        if (total == 0) revert ZeroTotal();
        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert BadDuration(duration, MIN_DURATION, MAX_DURATION);
        }

        campaignId = campaignIdFor(msg.sender, salt);
        if (campaigns[campaignId].funder != address(0)) revert CampaignExists(campaignId);

        (uint256 cherumFee, uint256 integratorFee) = _resolveFees(total, feeAmount, integratorRecipient, integratorBps);
        uint256 due = total + cherumFee + integratorFee;

        campaigns[campaignId] = Campaign({
            funder: msg.sender,
            expiry: uint64(block.timestamp) + duration,
            refunded: false,
            sigOnly: sigOnly,
            token: token,
            root: root,
            total: total,
            paidOut: 0
        });
        listURI[campaignId] = listUri;
        campaignCount++;

        if (token == NATIVE) {
            if (msg.value != due) revert NativeValueMismatch(due, msg.value);
            held[NATIVE] += total;
            if (cherumFee != 0) {
                _sendNativeCapped(feeCollector, cherumFee);
                emit FeeCollected(campaignId, NATIVE, feeCollector, cherumFee);
            }
            if (integratorFee != 0) {
                _sendNativeCapped(integratorRecipient, integratorFee);
                emit IntegratorFeeCollected(campaignId, NATIVE, integratorRecipient, integratorFee);
            }
        } else {
            if (msg.value != 0) revert NativeValueNotZero();
            uint256 balBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), due);
            if (IERC20(token).balanceOf(address(this)) - balBefore != due) revert FoTNotSupported();
            // Credited only after the money is provably here, so `held` never
            // over-states the escrow even for an instant.
            held[token] += total;
            // Both fee legs go out through `_payOut`, which asserts the exact
            // balance delta. Plain `safeTransfer` here was a real hole: `held`
            // is credited the moment funding lands, so a token that bills a tax
            // to the SENDER on top of the amount passes the exact-receipt check
            // at funding and then quietly takes the surcharge out of escrowed
            // principal on the very next line. Funding and every payout already
            // measured the delta; these two did not, and they sit between them.
            if (cherumFee != 0) {
                _payOut(token, feeCollector, cherumFee, false);
                emit FeeCollected(campaignId, token, feeCollector, cherumFee);
            }
            if (integratorFee != 0) {
                _payOut(token, integratorRecipient, integratorFee, false);
                emit IntegratorFeeCollected(campaignId, token, integratorRecipient, integratorFee);
            }
        }

        emit CampaignCreated(
            campaignId, msg.sender, token, root, total, campaigns[campaignId].expiry, sigOnly, listUri
        );
    }

    // -- Claim ----------------------------------------------------------------

    /// @notice Withdraw one leaf. Callable by ANYONE unless the campaign is
    ///         `sigOnly`; the money can only go to the `account` written into
    ///         the leaf.
    /// @dev    Open calling is the industry norm (Uniswap, Morpho URD, Scroll,
    ///         Sablier) and there is no theft in it by construction: a valid
    ///         proof authorises a transfer to the address the funder committed
    ///         to. It is also the one line today that lets us switch on
    ///         gas-free claiming later - our own relayer, somebody else's
    ///         sponsor, or nobody - without touching this contract.
    ///
    ///         This breaks in exactly one place: when the caller gets to name
    ///         the destination. Zora lost $128k in April 2025 to `_claimTo(user,
    ///         to)` with no `msg.sender == user` check, and Wayfinder ~119 ETH
    ///         to the same shape. Hence `to` exists only inside a signature by
    ///         the recipient (`claimViaSig`).
    ///
    ///         One exception to `sigOnly`: the listed recipient may always take
    ///         their own leaf to their own address. It hands nobody a power they
    ///         lacked - whoever holds that key can sign a redirect anywhere, so
    ///         `msg.sender == account` proves strictly more than a signature
    ///         does - and it is the only way to CANCEL a signature already
    ///         given. There are no nonces here, `deadline` is the signer's own
    ///         choice, and a wallet that signed `deadline = type(uint256).max`
    ///         to an address it later loses would otherwise have no recourse for
    ///         up to a year. Taking the leaf yourself spends it.
    function claim(bytes32 campaignId, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (campaigns[campaignId].sigOnly && msg.sender != account) revert ClaimNeedsSignature(campaignId);
        _claim(campaignId, index, account, account, amount, proof);
    }

    /// @notice Withdraw one leaf to a different address, authorised by the
    ///         listed recipient's own EIP-712 signature.
    /// @dev    `SignatureChecker` rather than a bare `ecrecover`, so smart
    ///         wallets (ERC-1271) work. The domain separator is recomputed when
    ///         `block.chainid` changes, so a chain split cannot make old
    ///         signatures valid on the new fork.
    ///
    ///         Order matters here and it is not the obvious one. The proof is
    ///         checked BEFORE the signature, because `account` is whatever the
    ///         caller typed and `SignatureChecker` will hand an ERC-1271 wallet
    ///         every unit of gas left in the transaction. Verify the leaf first
    ///         and an invented `account` never reaches that call at all.
    function claimViaSig(
        bytes32 campaignId,
        uint256 index,
        address account,
        address to,
        uint256 amount,
        uint256 validFrom,
        uint256 deadline,
        bytes32[] calldata proof,
        bytes calldata signature
    ) external nonReentrant {
        if (block.timestamp < validFrom) revert SignatureNotYetValid(validFrom);
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        _checkClaimable(campaignId, index, account, to, amount, proof);
        bytes32 digest = claimToDigest(campaignId, index, account, to, amount, validFrom, deadline);
        if (!SignatureChecker.isValidSignatureNowCalldata(account, digest, signature)) revert BadSignature();
        _settleClaim(campaignId, index, account, to, amount);
    }

    /// @notice Withdraw several leaves of ONE campaign in a single transaction.
    ///         One campaign only, so every payout is the same asset.
    function claimMany(
        bytes32 campaignId,
        uint256[] calldata indexes,
        address[] calldata accounts,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        if (campaigns[campaignId].sigOnly) revert ClaimNeedsSignature(campaignId);
        uint256 len = indexes.length;
        if (len == 0) revert BatchEmpty();
        if (len > MAX_CLAIM_BATCH) revert BatchTooLarge(len, MAX_CLAIM_BATCH);
        if (accounts.length != len || amounts.length != len || proofs.length != len) revert LengthMismatch();
        for (uint256 i; i < len;) {
            _claim(campaignId, indexes[i], accounts[i], accounts[i], amounts[i], proofs[i]);
            unchecked {
                ++i;
            }
        }
    }

    // -- Refund ---------------------------------------------------------------

    /// @notice Return the unclaimed remainder to whoever funded the campaign.
    function refund(bytes32 campaignId) external nonReentrant {
        _refund(campaignId, msg.sender);
    }

    /// @notice Return the unclaimed remainder to an address the funder names.
    /// @dev    A refund with no alternative destination is a trap, and the
    ///         contract has no administrative path to this money by design (that
    ///         is the ZKsync lesson - ~$5M through `sweepUnclaimed()` behind a
    ///         1-of-1 key). So the funder must have one: a contract wallet whose
    ///         receive hook grew heavier than the stipend, or an address a token
    ///         has since blacklisted (USDC and USDT both do this), would
    ///         otherwise strand the remainder forever with nobody able to move
    ///         it. Only the funder may call this, and only they choose where.
    function refundTo(bytes32 campaignId, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert SelfNotAllowed();
        _refund(campaignId, to);
    }

    // -- Owner ----------------------------------------------------------------

    /// @notice Set the fee recipient. Redirects only the future fee stream,
    ///         never escrowed funds. Must be a code-free EOA.
    function setFeeCollector(address newCollector) external onlyOwner {
        if (newCollector == address(0)) revert ZeroAddress();
        if (newCollector.code.length != 0) revert FeeCollectorMustBeEOA();
        feeCollector = newCollector;
        emit FeeCollectorSet(newCollector);
    }

    /// @notice Recover native coin forced in here by mistake. Bounded by the
    ///         provable excess over `held`, so it can never reach a single unit
    ///         of escrowed principal even if the owner key is lost.
    /// @dev    Native ONLY, and that restriction is the point. The general
    ///         version took a token address and compared `balanceOf(token)`
    ///         against `held[token]` - two reads keyed by the address the OWNER
    ///         passes. Tokens with two entry points onto one ledger break that
    ///         outright: TrueUSD and Synthetix-family assets answer
    ///         `balanceOf` from the proxy and from the implementation alike, and
    ///         `held` was only ever credited under the address campaigns were
    ///         funded through. Sweeping via the other address reads a full
    ///         balance against a zero debt and the whole escrow is "stray". No
    ///         accounting keyed by address can survive an asset with more than
    ///         one address, and an owner allowlist of known-single-entry tokens
    ///         would put back exactly the privileged surface this contract is
    ///         built without. The native coin has one address by construction,
    ///         so here the comparison is sound.
    ///
    ///         What this costs: an ERC-20 sent to this contract by mistake is
    ///         unrecoverable, by us or by anyone. That is the same bargain
    ///         Uniswap's MerkleDistributor and Morpho's URD make, and it is the
    ///         cheap side of the trade - a stranded stranger's transfer against
    ///         a path to every claimant's principal.
    ///
    ///         Native coin can still arrive despite there being no `receive` or
    ///         `fallback`: `selfdestruct` from another contract and block
    ///         rewards both push it in unasked. Hence the function exists at all.
    function sweepStrayNative(address to, uint256 amount) external onlyOwner whenPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert SelfNotAllowed();
        if (amount == 0) revert ZeroSweepAmount();
        uint256 bal = address(this).balance;
        uint256 owed = held[NATIVE];
        uint256 stray = bal > owed ? bal - owed : 0;
        if (amount > stray) revert NothingToSweep(amount, stray);
        // Uncapped, for the same reason a refund is: one transfer, the owner
        // chooses the destination, and there is no batch to grief. Capping it
        // here would only make a contract destination fail for no benefit.
        _payOut(NATIVE, to, amount, false);
        emit StraySwept(NATIVE, to, amount);
    }

    // -- Funder ---------------------------------------------------------------

    /// @notice Repoint the campaign's list. Money-neutral: the root governs what
    ///         can be claimed and never changes, and the pointer was never a
    ///         guarantee. It exists so a funder whose hosting died can publish
    ///         the list again instead of watching claimable money go unclaimed.
    /// @dev    No pause gate on purpose: this is the funder's own recovery, and
    ///         a claimant who cannot obtain the list cannot claim at all - the
    ///         same reasoning that keeps `claim` and `refund` open while paused.
    ///         Guarded against reentrancy only so it cannot be called from
    ///         inside a refund's receive hook, which is reachable but pointless.
    ///
    ///         Consequence the interface must carry: the pointer is no longer
    ///         fixed at creation, so it is the funder's current data rather than
    ///         a property of the campaign. Read the live value, and watch
    ///         `ListURISet`.
    function setListURI(bytes32 campaignId, string calldata uri) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        if (c.funder == address(0)) revert UnknownCampaign(campaignId);
        if (msg.sender != c.funder) revert NotFunder(msg.sender, c.funder);
        listURI[campaignId] = uri;
        emit ListURISet(campaignId, uri);
    }

    // -- Internal -------------------------------------------------------------

    function _refund(bytes32 campaignId, address to) private {
        Campaign storage c = campaigns[campaignId];
        if (c.funder == address(0)) revert UnknownCampaign(campaignId);
        if (msg.sender != c.funder) revert NotFunder(msg.sender, c.funder);
        if (block.timestamp < c.expiry) revert CampaignLive(campaignId, c.expiry);
        if (c.refunded) revert CampaignRefunded(campaignId);

        uint256 amount = c.total - c.paidOut;
        c.refunded = true;
        c.paidOut = c.total;
        address token = c.token;
        held[token] -= amount;

        // Uncapped native send here, unlike a claim: this is one transfer to the
        // person who put the money in, the state is already written, and the
        // contract-wide transient guard is held - so there is no batch to grief
        // and nothing to re-enter. A capped send would let a funder's own wallet
        // grow past the stipend and strand the remainder permanently.
        if (amount != 0) _payOut(token, to, amount, false);
        emit Refunded(campaignId, c.funder, to, amount);
    }

    function _claim(
        bytes32 campaignId,
        uint256 index,
        address account,
        address to,
        uint256 amount,
        bytes32[] calldata proof
    ) private {
        _checkClaimable(campaignId, index, account, to, amount, proof);
        _settleClaim(campaignId, index, account, to, amount);
    }

    /// @dev Every reason a claim can be refused, and not one state write.
    ///      Separated from the settlement so `claimViaSig` can run it before it
    ///      spends anything on the signature - see the note there.
    function _checkClaimable(
        bytes32 campaignId,
        uint256 index,
        address account,
        address to,
        uint256 amount,
        bytes32[] calldata proof
    ) private view {
        Campaign storage c = campaigns[campaignId];
        if (c.funder == address(0)) revert UnknownCampaign(campaignId);
        if (c.refunded) revert CampaignRefunded(campaignId);
        // The claim window closes at expiry, so a claim and a refund can never
        // race for the same coins.
        if (block.timestamp >= c.expiry) revert CampaignExpired(campaignId, c.expiry);
        if (amount == 0) revert ZeroLeafAmount(campaignId, index);
        // The funder writes the leaves, but a payout to this contract would
        // silently break the `held` accounting - and on the native side that is
        // what bounds `sweepStrayNative`.
        if (account == address(0) || account == address(this)) revert InvalidLeafAccount(account);
        if (to == address(0) || to == address(this)) revert InvalidLeafAccount(to);

        if (proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(proof.length, MAX_PROOF_LENGTH);
        bytes32 leaf = leafOf(campaignId, index, account, amount);
        if (!MerkleProof.verifyCalldata(proof, c.root, leaf)) revert BadProof(campaignId, index);

        // A leaf is taken once and in full. The storage stays a uint256 so a
        // future partial-claim leaf format needs no migration, but paying a
        // DELTA here was a trap: with a malformed list that repeats an index, a
        // recipient signs "250 to X" and 150 arrives, because the rest went to
        // the earlier leaf. Requiring an untouched slot makes the signed amount
        // and the delivered amount the same number, always.
        if (claimedOf[campaignId][index] != 0) revert AlreadyClaimed(campaignId, index);
        // Written as a subtraction from the remainder, not `paidOut + amount >
        // total`: the funder authors the leaves, and one carrying an absurd
        // amount made that addition overflow and revert with a bare arithmetic
        // panic instead of naming the problem. `total >= paidOut` always holds,
        // so this side cannot underflow.
        uint256 remaining = c.total - c.paidOut;
        if (amount > remaining) revert Underfunded(campaignId, amount, remaining);
    }

    /// @dev State first, transfer after (checks-effects-interactions). GemPad
    ///      (~$2M, 17.12.2024) and Bizness Locker ($15.7k, 27.12.2024) both lost
    ///      native coin to the other order; ReentrancyGuardTransient is the belt
    ///      on top of the braces. Private and only ever reached through
    ///      `_checkClaimable`; the checked arithmetic below is the backstop if a
    ///      future edit forgets that.
    function _settleClaim(bytes32 campaignId, uint256 index, address account, address to, uint256 amount) private {
        Campaign storage c = campaigns[campaignId];
        claimedOf[campaignId][index] = amount;
        c.paidOut += amount;
        held[c.token] -= amount;

        _payOut(c.token, to, amount, true);
        emit Claimed(campaignId, index, account, to, amount);
    }

    /// @dev The one place value leaves this contract. `capGas` applies the
    ///      per-recipient stipend; refunds pass false (see `_refund`).
    function _payOut(address token, address to, uint256 amount, bool capGas) private {
        if (token == NATIVE) {
            // A failed send reverts the whole call, so a swallowed transfer can
            // never leave the leaf marked as taken with nothing delivered
            // (Cantina on Sablier v3.0, Low 3.2.1). No balance-drop assertion
            // here: a `call` carrying value that returns true has moved the
            // value, and this contract has neither `receive` nor `fallback`, so
            // the recipient cannot push it back in the same call.
            if (capGas) {
                _sendNativeCapped(to, amount);
            } else {
                (bool sent,) = payable(to).call{value: amount}("");
                if (!sent) revert NativeTransferFailed();
            }
        } else {
            uint256 balBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, amount);
            uint256 balAfter = IERC20(token).balanceOf(address(this));
            // A token that reports success without moving anything would
            // otherwise consume the leaf for nothing. Compared this way round so
            // a token whose callback GREW our balance reverts with the honest
            // error instead of an arithmetic panic.
            if (balAfter > balBefore || balBefore - balAfter != amount) revert FoTNotSupported();
        }
    }

    function _sendNativeCapped(address to, uint256 amount) private {
        (bool sent,) = payable(to).call{value: amount, gas: NATIVE_SEND_GAS}("");
        if (!sent) revert NativeTransferFailed();
    }

    /// @dev Same shape as `CherumFeeBase._resolveFees` plus the claim-specific
    ///      ceiling. All three caps are measured against the principal.
    function _resolveFees(uint256 total, uint256 feeAmount, address integratorRecipient, uint16 integratorBps)
        private
        view
        returns (uint256 cherumFee, uint256 integratorFee)
    {
        uint256 maxCherum = (total * MAX_CLAIM_FEE_BPS) / BPS_DENOMINATOR;
        if (feeAmount > maxCherum) revert ClaimFeeTooHigh(feeAmount, maxCherum);

        if (integratorRecipient == address(0)) {
            integratorFee = 0;
        } else {
            // Paying the integrator fee to this contract would leave native
            // coin above `held` and hand it to `sweepStrayNative` - the only way
            // found to manufacture an excess deliberately. On the token path it
            // would strand the fee forever instead. Both are wrong; refuse.
            if (integratorRecipient == address(this)) revert SelfNotAllowed();
            if (integratorBps > MAX_INTEGRATOR_FEE_BPS) revert IntegratorFeeTooHigh(integratorBps);
            integratorFee = (total * integratorBps) / BPS_DENOMINATOR;
        }

        cherumFee = feeAmount;
        // Both ceilings are 5%, so this can only bind if one of them is ever
        // raised. Kept so the invariant is stated where it is enforced.
        uint256 maxTotal = (total * MAX_TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        if (cherumFee + integratorFee > maxTotal) revert TotalFeeTooHigh(cherumFee + integratorFee, maxTotal);
    }
}
