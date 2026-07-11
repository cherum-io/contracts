// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

/// @title CherumOrder
/// @notice Canonical fan-out order signed by the user as a Permit2 witness.
///         The same envelope is shared by the cross-chain and same-chain
///         routers; the leg array itself is hashed by each router into
///         `legsHash`, keeping this struct stable across both paths.
/// @dev    Every value the user must commit to lives here. Money-bearing fields
///         (fee, recipients) are explicit and strongly typed so the contract
///         can enforce caps against them. `extraHash` is a forward-compatibility
///         escape-hatch: a single bytes32 the contract never reads, committed in
///         the signature so future NON-MONETARY signed data (e.g. a route or
///         policy commitment, a referral id, an attestation) can be bound to the
///         order without a new envelope and a redeploy. Money can never hide
///         behind it - any value that moves funds must be its own typed field.
library CherumOrder {
    struct Order {
        // Intent identity and the hash of the router-specific leg array.
        bytes32 intentId;
        bytes32 legsHash;
        // Hash of the per-leg native bridge fees. Same-chain routers, which
        // never pay a bridge, sign bytes32(0).
        bytes32 nativeFeesHash;
        uint256 deadline;
        // Funds owner. Equal to the Permit2 signer on the direct path; on the
        // relayed path it is the account on whose behalf a relayer submits.
        // Refunds are always paid to `refundRecipient`, never to the caller.
        address account;
        address refundRecipient;
        // Integrator payout wallet and its fee in basis points. Zero recipient
        // means no integrator fee. Bounded on-chain by the integrator cap.
        address integratorRecipient;
        uint16 integratorBps;
        // Cherum fee as an absolute token amount, set per swap from the fee
        // schedule. Bounded on-chain by the total fee cap applied to principal.
        uint256 signedFeeAmount;
        // Forward-compatibility commitment. The contract does NOT read this; it
        // only forces it into the signature. Off-chain it carries the hash of
        // any future non-monetary data. Set to bytes32(0) when unused.
        bytes32 extraHash;
    }

    /// @dev EIP-712 type of the Order struct.
    bytes internal constant ORDER_TYPE =
        "CherumOrder(bytes32 intentId,bytes32 legsHash,bytes32 nativeFeesHash,uint256 deadline,address account,address refundRecipient,address integratorRecipient,uint16 integratorBps,uint256 signedFeeAmount,bytes32 extraHash)";

    bytes32 internal constant ORDER_TYPEHASH = keccak256(ORDER_TYPE);

    /// @dev Witness type string passed to Permit2 `permitWitnessTransferFrom`.
    ///      It completes the Permit2 stub that ends in "...,uint256 deadline,"
    ///      with the witness member, then the referenced struct types in
    ///      EIP-712 order (CherumOrder before TokenPermissions).
    string internal constant WITNESS_TYPE_STRING =
        "CherumOrder order)CherumOrder(bytes32 intentId,bytes32 legsHash,bytes32 nativeFeesHash,uint256 deadline,address account,address refundRecipient,address integratorRecipient,uint16 integratorBps,uint256 signedFeeAmount,bytes32 extraHash)TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 struct hash of an order, used as the Permit2 witness.
    function hash(Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.intentId,
                order.legsHash,
                order.nativeFeesHash,
                order.deadline,
                order.account,
                order.refundRecipient,
                order.integratorRecipient,
                order.integratorBps,
                order.signedFeeAmount,
                order.extraHash
            )
        );
    }
}
