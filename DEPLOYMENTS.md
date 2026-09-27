# Deployments

Every Cherum contract on chain, grouped by product: 54 deployments of 8 contracts across 7 networks (Ethereum, Base, Arbitrum One, Optimism, Polygon, BNB Chain and HyperEVM), plus the Safe that owns them. Each one is built from the source in this repository; [README.md](README.md#verify-a-deployment) shows how to check that yourself.

- **Explorer verification.** Checked 2026-09-16 with the Etherscan v2 API, all seven networks including HyperEVM 999: every address below returns verified source, and the contract name on chain matches the table (the Safe verifies as `SafeProxy`).
- **Sourcify.** All 54 Cherum deployments have their source on [Sourcify](https://sourcify.dev) (checked 2026-09-16), a second, independent copy of the same files.
- **Owner.** `CherumFanOutRouter`, `CherumReceiver`, `CherumRouter`, `CherumDisperse` and `CherumClaim` are owned by the Cherum 2-of-3 Safe `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` (Safe v1.4.1, the same address on all 7 networks). `CherumDepositFactory`, `CherumDepositForwarder` and `CherumOriginSettler` have no owner.
- **Match on the pair, not the address.** The contracts were deployed with plain `CREATE`, so the same address can be a different contract on a different network. The two Payments contracts are the exception: the same address on every network they are on.
- **You never need to send funds to a contract by hand.** The address you pay is the one the service hands you. This list is for checking an address you were given.

## Exchange

Cross-chain and same-chain swaps.

### CherumFanOutRouter

Source: [`src/v2/CherumFanOutRouter.sol`](src/v2/CherumFanOutRouter.sol) · 7 networks

Starts a cross-chain send. One signature is split into legs across bridges and destination chains.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0x7ba303dc458da48a5bcccad16ab529533935b9d7` | [Etherscan](https://etherscan.io/address/0x7ba303dc458da48a5bcccad16ab529533935b9d7#code) | [source](https://repo.sourcify.dev/1/0x7ba303dc458da48a5bcccad16ab529533935b9d7) |
| Base | 8453 | `0x652F64bdB2F2CfF37c2481636C7784C9f1F65e45` | [Basescan](https://basescan.org/address/0x652F64bdB2F2CfF37c2481636C7784C9f1F65e45#code) | [source](https://repo.sourcify.dev/8453/0x652F64bdB2F2CfF37c2481636C7784C9f1F65e45) |
| Arbitrum One | 42161 | `0x0902e9819119a9d1b51efb85842983b76cab3145` | [Arbiscan](https://arbiscan.io/address/0x0902e9819119a9d1b51efb85842983b76cab3145#code) | [source](https://repo.sourcify.dev/42161/0x0902e9819119a9d1b51efb85842983b76cab3145) |
| Optimism | 10 | `0xb0284630e35c7df89e6e18dcddb6e490fbe55560` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0xb0284630e35c7df89e6e18dcddb6e490fbe55560#code) | [source](https://repo.sourcify.dev/10/0xb0284630e35c7df89e6e18dcddb6e490fbe55560) |
| Polygon | 137 | `0x925a2eda850f786fc40bef6afb42c2b36631d391` | [Polygonscan](https://polygonscan.com/address/0x925a2eda850f786fc40bef6afb42c2b36631d391#code) | [source](https://repo.sourcify.dev/137/0x925a2eda850f786fc40bef6afb42c2b36631d391) |
| BNB Chain | 56 | `0x7d38a643f3592bc5532bba5d615f5b3d5bb97b7c` | [BscScan](https://bscscan.com/address/0x7d38a643f3592bc5532bba5d615f5b3d5bb97b7c#code) | [source](https://repo.sourcify.dev/56/0x7d38a643f3592bc5532bba5d615f5b3d5bb97b7c) |
| HyperEVM | 999 | `0x0b331496dc2730aac4f20fe0c61c09f7e050d839` | [HyperEVMScan](https://hyperevmscan.io/address/0x0b331496dc2730aac4f20fe0c61c09f7e050d839#code) | [source](https://repo.sourcify.dev/999/0x0b331496dc2730aac4f20fe0c61c09f7e050d839) |

### CherumReceiver

Source: [`src/v2/CherumReceiver.sol`](src/v2/CherumReceiver.sol) · 7 networks

Takes delivery on the destination chain for Across and Circle CCTP V2 legs: swaps into the token that was asked for and forwards it to the final recipient. Across calls it with the leg payload; a CCTP V2 leg is delivered by Cherum's relayer under two co-signer signatures.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0x9852ef708fac8f8c29998511771d43303c03ff53` | [Etherscan](https://etherscan.io/address/0x9852ef708fac8f8c29998511771d43303c03ff53#code) | [source](https://repo.sourcify.dev/1/0x9852ef708fac8f8c29998511771d43303c03ff53) |
| Base | 8453 | `0x925A2EdA850f786fc40BEF6AFb42c2B36631d391` | [Basescan](https://basescan.org/address/0x925A2EdA850f786fc40BEF6AFb42c2B36631d391#code) | [source](https://repo.sourcify.dev/8453/0x925A2EdA850f786fc40BEF6AFb42c2B36631d391) |
| Arbitrum One | 42161 | `0x37e98e1d1a84b1def801de2495d3b169ff4e40b3` | [Arbiscan](https://arbiscan.io/address/0x37e98e1d1a84b1def801de2495d3b169ff4e40b3#code) | [source](https://repo.sourcify.dev/42161/0x37e98e1d1a84b1def801de2495d3b169ff4e40b3) |
| Optimism | 10 | `0x652f64bdb2f2cff37c2481636c7784c9f1f65e45` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x652f64bdb2f2cff37c2481636c7784c9f1f65e45#code) | [source](https://repo.sourcify.dev/10/0x652f64bdb2f2cff37c2481636c7784c9f1f65e45) |
| Polygon | 137 | `0x97922a747ce22320dc39e24271f753b6d9142ff6` | [Polygonscan](https://polygonscan.com/address/0x97922a747ce22320dc39e24271f753b6d9142ff6#code) | [source](https://repo.sourcify.dev/137/0x97922a747ce22320dc39e24271f753b6d9142ff6) |
| BNB Chain | 56 | `0x6cf547e33977a531ff8fd8f2bda0dde1ee5d8da8` | [BscScan](https://bscscan.com/address/0x6cf547e33977a531ff8fd8f2bda0dde1ee5d8da8#code) | [source](https://repo.sourcify.dev/56/0x6cf547e33977a531ff8fd8f2bda0dde1ee5d8da8) |
| HyperEVM | 999 | `0x7512163687bec48998677bf8be2d35fc2e84d4a3` | [HyperEVMScan](https://hyperevmscan.io/address/0x7512163687bec48998677bf8be2d35fc2e84d4a3#code) | [source](https://repo.sourcify.dev/999/0x7512163687bec48998677bf8be2d35fc2e84d4a3) |

### CherumRouter

Source: [`src/v2/CherumRouter.sol`](src/v2/CherumRouter.sol) · 7 networks

Swap and fan-out inside one chain: one signature, many recipients, no bridge involved.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0xc8e81fa8f5fac773b13866773005acb0a80fc5ca` | [Etherscan](https://etherscan.io/address/0xc8e81fa8f5fac773b13866773005acb0a80fc5ca#code) | [source](https://repo.sourcify.dev/1/0xc8e81fa8f5fac773b13866773005acb0a80fc5ca) |
| Base | 8453 | `0xe7BE2634a4bFFE751F08Cb2043651e2E9A13Ca60` | [Basescan](https://basescan.org/address/0xe7BE2634a4bFFE751F08Cb2043651e2E9A13Ca60#code) | [source](https://repo.sourcify.dev/8453/0xe7BE2634a4bFFE751F08Cb2043651e2E9A13Ca60) |
| Arbitrum One | 42161 | `0x833aaffba7ed2b1cbc32a49c1c40b5f76db1b5e1` | [Arbiscan](https://arbiscan.io/address/0x833aaffba7ed2b1cbc32a49c1c40b5f76db1b5e1#code) | [source](https://repo.sourcify.dev/42161/0x833aaffba7ed2b1cbc32a49c1c40b5f76db1b5e1) |
| Optimism | 10 | `0xe7be2634a4bffe751f08cb2043651e2e9a13ca60` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0xe7be2634a4bffe751f08cb2043651e2e9a13ca60#code) | [source](https://repo.sourcify.dev/10/0xe7be2634a4bffe751f08cb2043651e2e9a13ca60) |
| Polygon | 137 | `0xa0eca6a116b192d24df3d423e0839e44c1ee12fa` | [Polygonscan](https://polygonscan.com/address/0xa0eca6a116b192d24df3d423e0839e44c1ee12fa#code) | [source](https://repo.sourcify.dev/137/0xa0eca6a116b192d24df3d423e0839e44c1ee12fa) |
| BNB Chain | 56 | `0x2b3428784aece90865251d94dedeb3efcfff4c6c` | [BscScan](https://bscscan.com/address/0x2b3428784aece90865251d94dedeb3efcfff4c6c#code) | [source](https://repo.sourcify.dev/56/0x2b3428784aece90865251d94dedeb3efcfff4c6c) |
| HyperEVM | 999 | `0x6a10e5bfbf26969384db32ad58aad6e35bf2f080` | [HyperEVMScan](https://hyperevmscan.io/address/0x6a10e5bfbf26969384db32ad58aad6e35bf2f080#code) | [source](https://repo.sourcify.dev/999/0x6a10e5bfbf26969384db32ad58aad6e35bf2f080) |

## Payouts

Pay many recipients at once.

### CherumDisperse

Source: [`src/v2/CherumDisperse.sol`](src/v2/CherumDisperse.sol) · 7 networks

Pays many recipients one token in a single transaction.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0x059645c61488dE1c18f22D7C617a0A5C1A1a9Ec7` | [Etherscan](https://etherscan.io/address/0x059645c61488dE1c18f22D7C617a0A5C1A1a9Ec7#code) | [source](https://repo.sourcify.dev/1/0x059645c61488dE1c18f22D7C617a0A5C1A1a9Ec7) |
| Base | 8453 | `0x94095aEe407A1D01C24c12cACf752eb9dB2EF135` | [Basescan](https://basescan.org/address/0x94095aEe407A1D01C24c12cACf752eb9dB2EF135#code) | [source](https://repo.sourcify.dev/8453/0x94095aEe407A1D01C24c12cACf752eb9dB2EF135) |
| Arbitrum One | 42161 | `0x2361981655c935169FB74816E57E072C6D568E46` | [Arbiscan](https://arbiscan.io/address/0x2361981655c935169FB74816E57E072C6D568E46#code) | [source](https://repo.sourcify.dev/42161/0x2361981655c935169FB74816E57E072C6D568E46) |
| Optimism | 10 | `0x38c855Ac446A2C077F8d720416C5558709781c6e` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x38c855Ac446A2C077F8d720416C5558709781c6e#code) | [source](https://repo.sourcify.dev/10/0x38c855Ac446A2C077F8d720416C5558709781c6e) |
| Polygon | 137 | `0x833aaffBA7Ed2b1CbC32a49C1C40B5F76DB1B5E1` | [Polygonscan](https://polygonscan.com/address/0x833aaffBA7Ed2b1CbC32a49C1C40B5F76DB1B5E1#code) | [source](https://repo.sourcify.dev/137/0x833aaffBA7Ed2b1CbC32a49C1C40B5F76DB1B5E1) |
| BNB Chain | 56 | `0x2A8aA0316D112E1FFd0EBfFfe32b49687E2D1A6d` | [BscScan](https://bscscan.com/address/0x2A8aA0316D112E1FFd0EBfFfe32b49687E2D1A6d#code) | [source](https://repo.sourcify.dev/56/0x2A8aA0316D112E1FFd0EBfFfe32b49687E2D1A6d) |
| HyperEVM | 999 | `0x9801537583a16Ec4ec3b7541B5B6f53A971A0B6C` | [HyperEVMScan](https://hyperevmscan.io/address/0x9801537583a16Ec4ec3b7541B5B6f53A971A0B6C#code) | [source](https://repo.sourcify.dev/999/0x9801537583a16Ec4ec3b7541B5B6f53A971A0B6C) |

## Payments

Accept crypto against an invoice.

### CherumDepositFactory

Source: [`src/pay/CherumDepositFactory.sol`](src/pay/CherumDepositFactory.sol) · 6 networks

Mints the deposit address of an invoice and sweeps what lands on it into the treasury — deploy and flush in one transaction.

Deployed from nonce 0 on every chain, so the address is the same on all six — and so is the deposit address of any given invoice.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27` | [Etherscan](https://etherscan.io/address/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27#code) | [source](https://repo.sourcify.dev/1/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27) |
| Base | 8453 | `0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27` | [Basescan](https://basescan.org/address/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27#code) | [source](https://repo.sourcify.dev/8453/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27) |
| Arbitrum One | 42161 | `0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27` | [Arbiscan](https://arbiscan.io/address/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27#code) | [source](https://repo.sourcify.dev/42161/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27) |
| Optimism | 10 | `0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27#code) | [source](https://repo.sourcify.dev/10/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27) |
| Polygon | 137 | `0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27` | [Polygonscan](https://polygonscan.com/address/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27#code) | [source](https://repo.sourcify.dev/137/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27) |
| BNB Chain | 56 | `0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27` | [BscScan](https://bscscan.com/address/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27#code) | [source](https://repo.sourcify.dev/56/0x17FEa05aAB678A2cfF0860c3ec7c11aFcA551B27) |

### CherumDepositForwarder

Source: [`src/pay/CherumDepositForwarder.sol`](src/pay/CherumDepositForwarder.sol) · 6 networks

The template every deposit address is cloned from. It is a blueprint: nothing is ever paid to this address itself.

It has no owner: the treasury it flushes into is baked into the bytecode as an immutable, and reads back as the Safe below.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920` | [Etherscan](https://etherscan.io/address/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920#code) | [source](https://repo.sourcify.dev/1/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920) |
| Base | 8453 | `0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920` | [Basescan](https://basescan.org/address/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920#code) | [source](https://repo.sourcify.dev/8453/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920) |
| Arbitrum One | 42161 | `0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920` | [Arbiscan](https://arbiscan.io/address/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920#code) | [source](https://repo.sourcify.dev/42161/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920) |
| Optimism | 10 | `0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920#code) | [source](https://repo.sourcify.dev/10/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920) |
| Polygon | 137 | `0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920` | [Polygonscan](https://polygonscan.com/address/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920#code) | [source](https://repo.sourcify.dev/137/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920) |
| BNB Chain | 56 | `0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920` | [BscScan](https://bscscan.com/address/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920#code) | [source](https://repo.sourcify.dev/56/0x67d124b0037F1f52ceecBEf319D75a8C1Ff3E920) |

## Claims

The recipient withdraws for themselves.

### CherumClaim

Source: [`src/v2/CherumClaim.sol`](src/v2/CherumClaim.sol) · 7 networks

Escrow the recipient withdraws from: a campaign is funded once, each recipient claims their own share against a stored proof.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0xc9B3d35dd109fFc36fe234D6F34DA6E68e899FDD` | [Etherscan](https://etherscan.io/address/0xc9B3d35dd109fFc36fe234D6F34DA6E68e899FDD#code) | [source](https://repo.sourcify.dev/1/0xc9B3d35dd109fFc36fe234D6F34DA6E68e899FDD) |
| Base | 8453 | `0x978106be459e54dB995d443a15742EBb41c75a4e` | [Basescan](https://basescan.org/address/0x978106be459e54dB995d443a15742EBb41c75a4e#code) | [source](https://repo.sourcify.dev/8453/0x978106be459e54dB995d443a15742EBb41c75a4e) |
| Arbitrum One | 42161 | `0x35A206944784dc9FadFB1a834Ede5A7bc18C9d82` | [Arbiscan](https://arbiscan.io/address/0x35A206944784dc9FadFB1a834Ede5A7bc18C9d82#code) | [source](https://repo.sourcify.dev/42161/0x35A206944784dc9FadFB1a834Ede5A7bc18C9d82) |
| Optimism | 10 | `0x833aaffBA7Ed2b1CbC32a49C1C40B5F76DB1B5E1` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x833aaffBA7Ed2b1CbC32a49C1C40B5F76DB1B5E1#code) | [source](https://repo.sourcify.dev/10/0x833aaffBA7Ed2b1CbC32a49C1C40B5F76DB1B5E1) |
| Polygon | 137 | `0xFdB201f9176571C2f3DCA0B02A68c2bf0692A560` | [Polygonscan](https://polygonscan.com/address/0xFdB201f9176571C2f3DCA0B02A68c2bf0692A560#code) | [source](https://repo.sourcify.dev/137/0xFdB201f9176571C2f3DCA0B02A68c2bf0692A560) |
| BNB Chain | 56 | `0xEDc66D96a671D119DA3347b6960849be39eF10A0` | [BscScan](https://bscscan.com/address/0xEDc66D96a671D119DA3347b6960849be39eF10A0#code) | [source](https://repo.sourcify.dev/56/0xEDc66D96a671D119DA3347b6960849be39eF10A0) |
| HyperEVM | 999 | `0x389ED74baF28dAD29b1D420bC8f6278bFCa1cF27` | [HyperEVMScan](https://hyperevmscan.io/address/0x389ED74baF28dAD29b1D420bC8f6278bFCa1cF27#code) | [source](https://repo.sourcify.dev/999/0x389ED74baF28dAD29b1D420bC8f6278bFCa1cF27) |

## Deployed, not wired

On chain and verified, but not used by any route today. Listed so that an address you find under our deployer has an explanation.

### CherumOriginSettler

Source: [`src/v2/CherumOriginSettler.sol`](src/v2/CherumOriginSettler.sol) · 7 networks

ERC-7683 origin settler — the standard intent entry point. Deployed and verified, but not part of any live route.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0xb6401c713f14e32adb1b06d3855befe74d97b96c` | [Etherscan](https://etherscan.io/address/0xb6401c713f14e32adb1b06d3855befe74d97b96c#code) | [source](https://repo.sourcify.dev/1/0xb6401c713f14e32adb1b06d3855befe74d97b96c) |
| Base | 8453 | `0x97922a747ce22320dc39e24271f753b6d9142ff6` | [Basescan](https://basescan.org/address/0x97922a747ce22320dc39e24271f753b6d9142ff6#code) | [source](https://repo.sourcify.dev/8453/0x97922a747ce22320dc39e24271f753b6d9142ff6) |
| Arbitrum One | 42161 | `0x64a8518985b1b91812b85324bb0177f272998192` | [Arbiscan](https://arbiscan.io/address/0x64a8518985b1b91812b85324bb0177f272998192#code) | [source](https://repo.sourcify.dev/42161/0x64a8518985b1b91812b85324bb0177f272998192) |
| Optimism | 10 | `0x925a2eda850f786fc40bef6afb42c2b36631d391` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x925a2eda850f786fc40bef6afb42c2b36631d391#code) | [source](https://repo.sourcify.dev/10/0x925a2eda850f786fc40bef6afb42c2b36631d391) |
| Polygon | 137 | `0x3b42b9ad50bc77f010b293f45d7b3e3fd43fedb1` | [Polygonscan](https://polygonscan.com/address/0x3b42b9ad50bc77f010b293f45d7b3e3fd43fedb1#code) | [source](https://repo.sourcify.dev/137/0x3b42b9ad50bc77f010b293f45d7b3e3fd43fedb1) |
| BNB Chain | 56 | `0xfd08f39d9432cee9abb99003b81a2e5259c1036e` | [BscScan](https://bscscan.com/address/0xfd08f39d9432cee9abb99003b81a2e5259c1036e#code) | [source](https://repo.sourcify.dev/56/0xfd08f39d9432cee9abb99003b81a2e5259c1036e) |
| HyperEVM | 999 | `0x60a685370f165ef0ebe6836309867bcc9202314a` | [HyperEVMScan](https://hyperevmscan.io/address/0x60a685370f165ef0ebe6836309867bcc9202314a#code) | [source](https://repo.sourcify.dev/999/0x60a685370f165ef0ebe6836309867bcc9202314a) |

Why it is not in use (checked 2026-09-16):

- `open` and `openFor` on the settler revert with `ExecutionDisabled` — the contract is a read surface, it never takes custody.
- The settler entry on the fan-out router is flag-gated, and `settlerExecutionEnabled()` reads false on all seven chains (read 2026-09-16 over public RPC).
- No route in the backend or the frontend references it.

## Ownership

Who owns the contracts and holds the funds.

### Safe 2-of-3

7 networks · not a Cherum contract, source is not in this repository

Owner of `CherumFanOutRouter`, `CherumReceiver`, `CherumRouter`, `CherumDisperse` and `CherumClaim`, and the treasury that Payments deposit addresses sweep into. `CherumDepositFactory`, `CherumDepositForwarder` and `CherumOriginSettler` have no owner. Two of three signatures move anything.

Safe v1.4.1, the same address on all seven chains.

| Network | Chain ID | Address | Explorer | Sourcify |
|---|---|---|---|---|
| Ethereum | 1 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [Etherscan](https://etherscan.io/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | [source](https://repo.sourcify.dev/1/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0) |
| Base | 8453 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [Basescan](https://basescan.org/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | [source](https://repo.sourcify.dev/8453/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0) |
| Arbitrum One | 42161 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [Arbiscan](https://arbiscan.io/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | not on Sourcify |
| Optimism | 10 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [Optimistic Etherscan](https://optimistic.etherscan.io/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | [source](https://repo.sourcify.dev/10/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0) |
| Polygon | 137 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [Polygonscan](https://polygonscan.com/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | [source](https://repo.sourcify.dev/137/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0) |
| BNB Chain | 56 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [BscScan](https://bscscan.com/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | not on Sourcify |
| HyperEVM | 999 | `0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0` | [HyperEVMScan](https://hyperevmscan.io/address/0x3271Bd563cD39cAa67EC8944f2Dc7e67a81543B0#code) | not on Sourcify |

## Superseded

A contract cannot be removed from a chain, so 31 older Cherum addresses still have code: 19 replaced by later deploys and 12 from the first release (never verified). They are out of every config and every route, they are not built from this repository, and they are not listed here. Do not send anything to them. The full list, so that an address from an old transaction has an answer, is at [docs.cherum.io/contracts](https://docs.cherum.io/contracts).

---

Generated from the canonical Cherum contract registry, the same source as docs.cherum.io/contracts. Do not edit by hand.
