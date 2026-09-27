// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

/// @dev ERC-7683 (legacy interface) data structures, matching the variant used
///      in production by Across and UniswapX.
struct Output {
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    uint256 chainId;
}

struct FillInstruction {
    uint64 destinationChainId;
    bytes32 destinationSettler;
    bytes originData;
}

struct ResolvedCrossChainOrder {
    address user;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    bytes32 orderId;
    Output[] maxSpent;
    Output[] minReceived;
    FillInstruction[] fillInstructions;
}

struct GaslessCrossChainOrder {
    address originSettler;
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    bytes32 orderDataType;
    bytes orderData;
}

struct OnchainCrossChainOrder {
    uint32 fillDeadline;
    bytes32 orderDataType;
    bytes orderData;
}

/// @title CherumOriginSettler
/// @notice ERC-7683 origin settler for Cherum fan-out intents, deployed in an
///         observation-only mode. It exposes the standard `resolve` surface so
///         solvers and indexers can read a Cherum order in the common 7683
///         shape, but it does not custody funds or execute: the on-chain
///         execution path is the flag-gated settler entry on the fan-out
///         router, not this contract. `open` / `openFor` therefore revert
///         until that path is wired in a later release.
/// @dev    The `orderData` schema below is provisional and used only for the
///         read surface; it firms up when the execution path is enabled.
contract CherumOriginSettler {
    /// @notice One destination of a fan-out, as carried in `orderData`.
    struct CherumLeg {
        uint64 destinationChainId;
        bytes32 destinationSettler;
        bytes32 outputToken;
        bytes32 recipient;
        uint256 outputAmount;
    }

    /// @notice Provisional Cherum order payload encoded into `orderData`.
    struct CherumOrderData {
        bytes32 inputToken;
        uint256 inputAmount;
        CherumLeg[] legs;
    }

    /// @notice EIP-712-style identifier of the Cherum order data type.
    bytes32 public constant CHERUM_ORDER_DATA_TYPE = keccak256("CherumOrderData");

    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    error ExecutionDisabled();
    error UnsupportedOrderDataType(bytes32 supplied);

    /// @notice Execution is not enabled on this settler. Cross-chain fan-out is
    ///         opened through the fan-out router's flag-gated settler entry.
    function open(OnchainCrossChainOrder calldata) external pure {
        revert ExecutionDisabled();
    }

    /// @notice Execution is not enabled on this settler.
    function openFor(GaslessCrossChainOrder calldata, bytes calldata, bytes calldata) external pure {
        revert ExecutionDisabled();
    }

    /// @notice Resolve an on-chain order into the standard 7683 shape.
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory) {
        if (order.orderDataType != CHERUM_ORDER_DATA_TYPE) revert UnsupportedOrderDataType(order.orderDataType);
        return _resolve(msg.sender, order.fillDeadline, order.fillDeadline, order.orderData);
    }

    /// @notice Resolve a gasless order into the standard 7683 shape.
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata)
        external
        view
        returns (ResolvedCrossChainOrder memory)
    {
        if (order.orderDataType != CHERUM_ORDER_DATA_TYPE) revert UnsupportedOrderDataType(order.orderDataType);
        return _resolve(order.user, order.openDeadline, order.fillDeadline, order.orderData);
    }

    function _resolve(address user, uint32 openDeadline, uint32 fillDeadline, bytes calldata orderData)
        private
        view
        returns (ResolvedCrossChainOrder memory resolved)
    {
        CherumOrderData memory d = abi.decode(orderData, (CherumOrderData));
        uint256 legsCount = d.legs.length;

        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({token: d.inputToken, amount: d.inputAmount, recipient: bytes32(0), chainId: block.chainid});

        Output[] memory minReceived = new Output[](legsCount);
        FillInstruction[] memory fills = new FillInstruction[](legsCount);
        for (uint256 i; i < legsCount; ++i) {
            CherumLeg memory leg = d.legs[i];
            minReceived[i] = Output({
                token: leg.outputToken,
                amount: leg.outputAmount,
                recipient: leg.recipient,
                chainId: leg.destinationChainId
            });
            fills[i] = FillInstruction({
                destinationChainId: leg.destinationChainId,
                destinationSettler: leg.destinationSettler,
                originData: abi.encode(leg)
            });
        }

        resolved = ResolvedCrossChainOrder({
            user: user,
            originChainId: block.chainid,
            openDeadline: openDeadline,
            fillDeadline: fillDeadline,
            orderId: keccak256(orderData),
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: fills
        });
    }
}
