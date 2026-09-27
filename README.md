# Cherum contracts

Solidity sources of the contracts [Cherum](https://cherum.io) runs on chain.
Cherum is four products: **Exchange**, **Payouts**, **Payments** and
**Claims**. Every live address is listed in [DEPLOYMENTS.md](DEPLOYMENTS.md):
54 deployments on Ethereum, Base, Arbitrum One, Optimism, Polygon, BNB Chain
and HyperEVM. Each one is built from the files in `src/`, and building this
repository reproduces the deployed runtime bytecode exactly, metadata hash
included. See [Verify a deployment](#verify-a-deployment).

## Products and contracts

| Product | Contract | What it does |
|---|---|---|
| Exchange | [`CherumFanOutRouter`](src/v2/CherumFanOutRouter.sol) | Cross-chain send. Pulls the payer's token once under a Permit2 signature, takes the fee and hands each leg to its bridge, all in one transaction. Delivery on the destination network happens afterwards, through the bridge. |
| Exchange | [`CherumReceiver`](src/v2/CherumReceiver.sol) | Destination side for Across and Circle CCTP V2 legs. Across calls it with the leg's payload; for CCTP V2, Cherum's relayer delivers the minted USDC with two co-signer signatures. Swaps into the requested token if needed and forwards it to the recipient. Other bridges deliver straight to the recipient without it. |
| Exchange | [`CherumRouter`](src/v2/CherumRouter.sol) | Same-chain swap and split. One signature; each leg is swapped through an allowlisted aggregator and sent to its own recipient. A leg that fails is refunded to the order's refund address in the same transaction. |
| Exchange | [`CherumOriginSettler`](src/v2/CherumOriginSettler.sol) | ERC-7683 origin settler. Deployed and verified, but not used by any route: `open` and `openFor` always revert. |
| Payouts | [`CherumDisperse`](src/v2/CherumDisperse.sol) | One token to many recipients in one transaction. All or nothing: one failing recipient reverts the whole batch. |
| Payments | [`CherumDepositFactory`](src/pay/CherumDepositFactory.sol), [`CherumDepositForwarder`](src/pay/CherumDepositForwarder.sol) | One deposit address per invoice (an EIP-1167 clone at a CREATE2 address, known before it has code), and the sweep of whatever lands on it into the Cherum treasury. |
| Claims | [`CherumClaim`](src/v2/CherumClaim.sol) | Escrow. A funder deposits a campaign against a Merkle root, each listed recipient claims their own share, and whatever is left goes back to the funder after the campaign expires. |

Shared modules: `CherumAdmin` (two-step ownership, pause), `CherumCallGuard`
(call allowlist), `CherumFeeBase` (fee ceilings), `CherumPermit2Base`
(Permit2 pull) and `CherumOrder` (the order the payer signs).

## Security model

### Custody, product by product

**Exchange, Payouts and Claims are non-custodial.** Money goes only to the
recipients in the order the payer signed, or back to the refund address in
that order (for Claims, to the funder). Cherum does not take custody of it.
The one place where Cherum's keys decide where user money goes is
`CherumReceiver` on the destination network. That case and the others where
funds can rest in a contract, with what can move them, are listed in the next
section.

**Payments is custodial until the merchant is credited.** Anything sent to an
invoice's deposit address can go to exactly one place: the Cherum treasury,
the 2-of-3 Safe, fixed in the forwarder's bytecode. The sweep (`flush`,
`flushNative`, `deployAndFlush`) can be called by anyone, because the
destination cannot change. There is no owner, no setting and no pause. Cherum
then pays the merchant from its own wallets, outside these contracts. A
mistaken deposit is refunded by Cherum, never from the deposit address.

### Where funds can rest in a contract

- **CherumClaim holds campaign funds by design.** They stay until each
  recipient claims, or until the funder takes back the remainder after expiry
  (`refund`, `refundTo`, funder only). No owner function reaches campaign
  funds. The only owner recovery, `sweepStrayNative`, is limited to native
  coin above what campaigns hold, and works only while paused. An ERC-20 sent
  to the contract by mistake cannot be recovered by anyone.
- **CherumFanOutRouter can hold a leg that a bridge sent back.** Legs leave in
  the transaction that opens them, so the router normally holds nothing. If a
  bridge returns a leg's funds to the router, they stay there until
  `claimStuckFunds(intentId, legIdx)` is called after the leg's deadline, by
  the leg's `refundRecipient` or by the owner. It always pays that leg's
  `refundRecipient` the leg's full amount. Every bridge leg Cherum builds names
  the paying wallet, not the router, wherever the bridge takes a refund
  address, so refunds go straight back to the payer. If a bridge does return a leg to the router, the
  Safe can pay it out with `claimStuckFunds` once the leg's deadline has
  passed; the call reverts if the router holds less than the leg's amount.
  The owner's `withdraw` (paused only) cannot touch balances counted in the
  refund reserve.
- **CherumReceiver: what it holds is directed by Cherum's keys.**
  - *Circle CCTP V2 legs.* CCTP mints the USDC to the Receiver and does not
    call it. Cherum's relayer then calls `dispatchCctpDeliveryWithCoSign`
    with the leg's payload, signed by both dispatch co-signer keys, which the
    owner sets. The contract does not compare that payload with the burned
    message, so on this path delivery to the recipient the payer signed for
    rests on those two Cherum keys. Across legs are different: the Across
    SpokePool calls the Receiver with the payload itself.
  - *Parking.* If the payload cannot be decoded, names no recipient, or the
    delivery itself reverts, the tokens stay on the Receiver instead of
    reverting (a revert could strand the bridge transfer). Parked USDC is
    booked per intent wherever the intent is known. There is no on-chain
    claim for the payer or the recipient. Parked funds leave through
    `withdraw` or `withdrawParkedIntents` (owner, paused only) to an address
    the owner chooses, or through `dispatchParkedDelivery` from an
    allowlisted dispatcher, to the recipient in the payload that dispatcher
    submits.
  - *The owner's reach.* Gateways and dispatchers are set by the owner at
    once, and a registered gateway's callback names the token, the amount
    and the recipient. So the owner can move anything the Receiver holds at
    any time, not only while it is paused.
  - A swap that fails is not parked: the recipient gets the bridged token
    itself instead of the requested one. The Receiver also holds native
    coin, funded by Cherum, for gas drops (at most 0.01 of the native coin
    per leg).
- **CherumRouter and CherumDisperse are pass-through.** Every token call ends
  with a balance check, and a native disperse must pay out exactly the value
  it receives, so nothing of a user's rests there between transactions. The
  owner can sweep a stray transfer while paused (`rescue`, `withdraw`).

### Owner and admin

- `CherumFanOutRouter`, `CherumReceiver`, `CherumRouter`, `CherumDisperse` and
  `CherumClaim` are owned by the Cherum 2-of-3 Safe
  `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0`. Ownership moves in two steps
  (`Ownable2Step`), and `renounceOwnership` always reverts.
  `CherumDepositFactory`, `CherumDepositForwarder` and `CherumOriginSettler`
  have no owner.
- **There is no timelock.** Every owner setting takes effect as soon as two
  of three signers agree, including pausing and removing an allowlist entry.
  One comment in `CherumFanOutRouter` (on `bridgeAndCallBatchExternal`) still
  says the settler is allowlisted "under the timelock"; it is out of date, and
  the source is kept exactly as deployed.
- **What the owner can set:** call targets and selectors (FanOut, Router);
  bridge approval targets, a per-bridge kill switch, the ERC-7683 settler
  switch and per-order and daily volume caps (FanOut); bridge gateways,
  trusted source routers, swap routers, dispatchers, dispatch co-signers and
  the single-key emergency dispatch switch (Receiver); the fee collector,
  which must be an address without code; whether a third party may submit a
  signed order (`setRelayerEnabled`); the leg and recipient limits below; and
  pause.
- **What the owner cannot do:** raise a fee ceiling or a limit ceiling (they
  are constants); on FanOut and Router, allowlist a token-moving selector
  (`transfer`, `transferFrom`, `approve`, `permit`, `setApprovalForAll`) or
  make Permit2, the contract itself or the token being moved a call target;
  or change an order a payer signed. The legs or recipients, the fee and the
  refund address are inside the Permit2 signature. No function pulls tokens
  from any address other than the caller or the account that signed the
  order. What the owner can reach on `CherumReceiver` is described above.

### Approvals

- On the Exchange paths and `disperseTokenPermit2`, the payer signs a Permit2
  transfer for the exact token and amount, bound to the Cherum contract and to
  the order (legs or recipients, fee, deadline, refund address). A relayer
  that submits it cannot change any of that. The Cherum app asks, once per
  token, for an unlimited ERC-20 approval to the canonical Permit2 contract
  `0x000000000022D473030F116dDEE9F6B43aC78BA3`, the usual Permit2 setup. The
  Cherum contracts themselves get no standing approval on these paths.
- The direct paths, `disperseToken` and `createCampaign`, take the tokens
  with `transferFrom` from the caller, so they need an ERC-20 approval to the
  Cherum contract itself.

### Fees and limits

The Cherum fee is an absolute amount. On the Permit2 paths it is part of the
order the payer signs; on the direct paths (`disperseToken`, `disperseNative`,
`createCampaign`) the caller passes it. The rate is set off-chain. The
contracts enforce only the ceilings, which are constants in the bytecode:

| Ceiling | Value | Constant |
|---|---|---|
| Total fee, Cherum and integrator together | 10% | `MAX_TOTAL_FEE_BPS` (FanOut, Router, Disperse, Claim) |
| Integrator share | 5% | `MAX_INTEGRATOR_FEE_BPS` (FanOut, Router, Disperse, Claim) |
| Cherum fee on a disperse | 5% of the batch | `MAX_DISPERSE_FEE_BPS` |
| Cherum fee on a claim campaign | 5% of the campaign | `MAX_CLAIM_FEE_BPS` |

Limits:

- Legs per order (FanOut, Router): `maxBatchLegs`, 12 at deployment and on
  every network when read on 2026-09-27. The owner can change it without a
  redeploy, up to `MAX_BATCH_LEGS_CEILING` = 30.
- Recipients per disperse: `maxRecipients`, set by the owner up to
  `MAX_RECIPIENTS_CEILING` = 10,000 (500 to 925 depending on the network on
  2026-09-27).
- Leaves per `claimMany`: 150. Campaign lifetime: 7 to 365 days.
- Order deadline: 1 to 24 hours ahead for a cross-chain order (FanOut), at
  most 1 hour ahead for a same-chain swap order (Router).
- Gas drop on delivery: at most 0.01 of the native coin per leg.

### Pause

`pause()` stops the entry points that take in new money. On FanOut and Claim
the exits stay open.

| Contract | Stops while paused | Keeps working while paused | Owner only, paused only |
|---|---|---|---|
| `CherumFanOutRouter` | `bridgeAndCallBatch`, `bridgeAndCallBatchExternal` | `claimStuckFunds` | `withdraw` (not the refund reserve) |
| `CherumRouter` | `batchSwap` | | `rescue` |
| `CherumDisperse` | `disperseToken`, `disperseTokenPermit2`, `disperseNative` | | `withdraw` |
| `CherumClaim` | `createCampaign` | `claim`, `claimViaSig`, `claimMany`, `refund`, `refundTo`, `setListURI` | `sweepStrayNative` (native coin above campaign balances only) |
| `CherumReceiver` | bridge callbacks and dispatches | | `withdraw`, `withdrawParkedIntents` |

`CherumDepositFactory` and `CherumDepositForwarder` have no pause: a sweep can
only ever go to the treasury. `CherumOriginSettler` holds no state and nothing
to pause.

### Call safety

- In the Exchange, Payouts and Claims contracts every entry point that moves
  user funds is `nonReentrant` (`ReentrancyGuardTransient`). The Payments
  sweep has no guard and needs none: it can only send to the treasury.
- Routed calls (bridges on FanOut, aggregators on Router) go only to
  allowlisted targets with allowlisted selectors, read from the first four
  bytes of the calldata. The Receiver swaps only through allowlisted swap
  routers. Approvals are for the exact amount and are reset to zero after
  each call. On the cross-chain router a per-leg balance check confirms that
  exactly the leg amount left.
- Fee-on-transfer tokens are rejected: every pull checks that the exact
  amount arrived.
- No upgradeable proxies. The only proxies are the Payments deposit
  addresses, EIP-1167 clones of a fixed `CherumDepositForwarder` that cannot
  be repointed.

## Build

Tested with Foundry v1.7.0 (`foundryup --install v1.7.0`), OpenZeppelin
Contracts v5.6.1 (commit `5fd1781b`) and forge-std v1.16.2.

```bash
git clone https://github.com/cherum-io/contracts.git && cd contracts
forge install foundry-rs/forge-std@v1.16.2
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1
forge build
```

From a downloaded archive without git history, install the libraries with
`forge install --no-git foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.6.1`.

Settings are in `foundry.toml`: solc 0.8.35, optimizer on with 500 runs,
via-IR, EVM `prague`. The source paths and the three remappings are part of
the metadata hash. Keep the files where they are and do not add remappings,
or the build will match the chain in logic but not byte for byte. The lint
warnings forge prints do not affect the output.

## Verify a deployment

**Read the verified source.** Every row in [DEPLOYMENTS.md](DEPLOYMENTS.md)
links to the verified source on the network's explorer and on Sourcify, where
the files sit under the same paths as here (`src/v2/...`, `src/pay/...`).

**Rebuild and compare.** After `forge build`, compare the runtime code on
chain with the build output. For `CherumFanOutRouter`, `CherumRouter`,
`CherumDisperse` and `CherumOriginSettler` the two are identical:

```bash
cast code 0x94095aEe407A1D01C24c12cACf752eb9dB2EF135 --rpc-url https://base-rpc.publicnode.com > onchain.hex
jq -r .deployedBytecode.object out/CherumDisperse.sol/CherumDisperse.json > local.hex
cmp onchain.hex local.hex && echo identical
```

`CherumReceiver`, `CherumClaim`, `CherumDepositFactory` and
`CherumDepositForwarder` have immutables: values fixed at deployment, such as
the treasury address, that are written into the runtime code. Zero the byte
ranges listed under `deployedBytecode.immutableReferences` in the build
artifact on both sides, then compare. Everything else, including the metadata
hash at the end, must match.

On 2026-09-27 this repository, built as above, matched all 54 deployments in
DEPLOYMENTS.md this way.

## Reporting a vulnerability

See [SECURITY.md](SECURITY.md).

## License

[Business Source License 1.1](LICENSE): source-available now, converts to MIT
on 2029-07-01. Production use is the deployment operated by Cherum at the
addresses in DEPLOYMENTS.md; review, audit and testing are always permitted.
Questions: support@cherum.io.
