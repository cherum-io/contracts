# Cherum contracts

On-chain contracts behind [Cherum](https://cherum.io) — a non-custodial
cross-chain **fan-out swap** router. One signature splits a transfer into up to
twelve legs, each on its own chain and token, and delivers them atomically. A
leg that cannot fill is refunded to the payer.

This repository holds the exact Solidity sources deployed to mainnet. Every
address in [DEPLOYMENTS.md](DEPLOYMENTS.md) is verified on its network's block
explorer and on [Sourcify](https://sourcify.dev) — the source you read here is
the bytecode you interact with.

## What's inside

| Contract | Role |
|---|---|
| `CherumFanOutRouter` | Source leg. Pulls the payer's funds once (Permit2), takes the routing fee, and opens a batch that bridges each leg to its destination. |
| `CherumReceiver` | Destination leg. Receives bridged funds and delivers the exact amount to each recipient; optionally swaps into the recipient's token. |
| `CherumRouter` | Same-chain path. Splits and swaps entirely on one chain in a single call. |
| `CherumDisperse` | Same-chain batch distribution. One token to many recipients atomically — the engine behind Send / disperse. |
| `CherumOriginSettler` | ERC-7683 origin settler surface for cross-chain intents. |
| `CherumOrder`, `CherumPermit2Base`, `CherumFeeBase`, `CherumCallGuard`, `CherumAdmin` | Shared base modules: order hashing, Permit2 binding, fee accounting, call allow-listing, and admin/pause control. |

## Security model

- **Non-custodial.** Funds move from the payer straight into a contract call
  that splits and delivers in the same transaction. No contract holds a user
  balance between calls.
- **Explicit approval.** On EVM the payer signs a Permit2 typed message binding
  the exact token, amount and recipients. No blanket approvals.
- **Hard caps in code.** Fees are capped on-chain (e.g. `CherumDisperse`
  enforces a 5% ceiling and a recipient-count ceiling); admin cannot exceed
  them.
- **Admin behind a multisig.** Owner of every contract is a 2-of-3 Safe. No
  admin action can touch funds already in a user's wallet.
- **Reentrancy-guarded** (`ReentrancyGuardTransient`) and **pausable** on the
  fund-moving paths.

## Build

Requires [Foundry](https://book.getfoundry.sh).

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1
forge build
```

Compiler: `solc 0.8.35`, optimizer on (500 runs), EVM `prague`. See
`foundry.toml`.

## Verify against the chain

Pick any address from [DEPLOYMENTS.md](DEPLOYMENTS.md) and compare its verified
source on the explorer with the file in `src/`. They match byte-for-byte.

## License

[Business Source License 1.1](LICENSE) — source-available now, converts to MIT
on 2029-07-01. Production use is the deployment operated by Cherum; review,
audit and testing are always permitted. Questions: support@cherum.io.
