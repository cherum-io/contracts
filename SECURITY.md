# Security policy

## Reporting a vulnerability

Email **support@cherum.io** with "Security" in the subject line. Please
include:

- the contract and the network: chain ID and address from
  [DEPLOYMENTS.md](DEPLOYMENTS.md);
- what is wrong and what it lets an attacker do;
- steps to reproduce, ideally a Foundry test against a mainnet fork.

Please do not open a public issue or pull request for a vulnerability, and do
not demonstrate it against mainnet contracts; a fork is enough.

## Scope

The sources in `src/` as deployed at the addresses in
[DEPLOYMENTS.md](DEPLOYMENTS.md). Older, superseded Cherum addresses are
listed at [docs.cherum.io/contracts](https://docs.cherum.io/contracts); they
are out of every route, but if you find funds at risk there, report that too.

## Documented behaviour

The following is by design and described in the [README](README.md#security-model).
A report that shows real harm beyond what is described there is still welcome.

- There is no timelock: owner settings apply as soon as two of three Safe
  signers agree.
- The contracts enforce fee ceilings; the rate itself is set per order.
- Bridge legs built by Cherum take their refunds to the paying wallet, not to
  `CherumFanOutRouter`.
- `CherumReceiver` keeps a delivery it cannot complete (parks it) instead of
  reverting. What it holds is directed by Cherum's keys: a Circle CCTP V2
  delivery takes its payload from Cherum's relayer under two co-signer
  signatures, and the owner can reach the Receiver's balance at any time
  through a gateway or dispatcher it allowlists, as well as directly while
  the contract is paused.
- An ERC-20 sent to `CherumClaim` by mistake cannot be recovered.
- Fee-on-transfer, rebasing and hook-bearing tokens are not supported.
