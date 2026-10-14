# Prediction Markets Run by AI Agents (VERDICT)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum mainnet.

| Field | Value |
| --- | --- |
| Solidity contract | `VerdictToken` (`src/VerdictToken.sol`) |
| `name()` | `Prediction Markets Run by AI Agents` |
| `symbol()` | `VERDICT` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 VERDICT = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` (the deployer), once, in the constructor |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## What the token does

`VerdictToken` is OpenZeppelin v5.4.0 `ERC20` with a constructor that mints the whole supply to
whoever deploys it and emits `SupplyMinted(deployer, amount)`. That is the entire behaviour:

- **No mint after construction.** There is no `mint`, no minter role and no owner. `totalSupply()`
  is `1e27` forever.
- **No burn.** The contract exposes no `burn`/`burnFrom`. Holders can only reduce the supply by
  sending to an address nobody controls, which is their own business and not a feature here.
- **No fees, taxes, reflections or hooks on transfer.** `transfer` and `transferFrom` move exactly
  the amount requested. This is what lets the launch's flows (swarm share to the distributor, pool
  seed through the Uniswap v4 PoolManager, remainder to the requester, trader swaps) arrive whole.
- **No pause, blacklist, freeze, lock or seize.** No address can move or stop another holder's
  balance. The deployer has exactly the same powers as any other holder.
- **No upgradeability, no `DELEGATECALL`, no `SELFDESTRUCT`, no `receive`/`fallback`.** The token
  rejects ether and unknown selectors.
- **Standard ERC-20 allowance semantics** (OpenZeppelin v5): `approve` overwrites, `transferFrom`
  decrements the allowance unless it is `type(uint256).max`, and failures revert with the
  ERC-6093 custom errors `ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`.

## Assumptions

- **The deployer is the distributor of the supply.** Under the IdentityMD launch the deployer is
  `ProjectFactory` (via `launchCustom`), which receives all `1e27` units and then, in the same
  transaction, forwards 10% to the launch's `MerkleDistributor`, seeds the single-sided pool with
  `economics.poolBps` (80%) and sends the remainder (10%) to `economics.remainderTo`
  (`0xd380a8b40fcea7c0a699ff0d8232a264b37a2f9f`). The token itself does none of this and holds no
  allocation of its own.
- **No launch addresses are needed by the token.** Because nothing is taxed or restricted, the
  constructor takes no `$factory`, `$poolManager` or `$launchNumber` and never calls another
  contract, so it deploys on an empty chain and under CREATE2 from any address.
- **Launch parameters are decided by the launch, not by this code.** Chain id 1, pair IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), pool fee 12500 (1.25%), tick spacing 60, opening
  cap 2,500 IMD. The manifest step writes `launch.json`; this repository deliberately does not
  contain one.
- **Nothing in the brief was left open.** Name, symbol, supply and decimals are fixed above as
  constants on the contract (`TOKEN_NAME`, `TOKEN_SYMBOL`, `TOKEN_DECIMALS`, `SUPPLY_WHOLE_TOKENS`,
  `TOTAL_SUPPLY`). There are no fee rates, prices or owner-settable values.

## Deployment parameters

For the manifest (`kind: custom_token`):

```
token.contract        VerdictToken
token.name            Prediction Markets Run by AI Agents
token.symbol          VERDICT
token.decimals        18
token.constructorArgs []
token.totalSupply     1000000000000000000000000000
contracts             []   (no application contracts)
```

The token is deployed from the bytecode produced by `forge build` with this repository's
`foundry.toml`. Do not change `solc`, `optimizer`, `optimizer_runs`, `evm_version`,
`bytecode_hash` or `cbor_metadata`: any of them changes the bytes the launch attests.

### Local deployment (optional, for inspection only)

`script/DeployVerdictToken.s.sol` deploys the token to a local Anvil. It reads no environment
variables; whoever signs the broadcast receives the whole supply.

```
anvil &
forge script script/DeployVerdictToken.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
```

Nobody should run this against mainnet: the production deployment is performed by IdentityMD's
deployer through `ProjectFactory.launchCustom` after the independent review.

## After launch

There is nothing to configure. The token has no owner, no setters and no external dependencies.
Operational responsibilities are limited to:

- **Explorer verification** of `VerdictToken` on Etherscan with the pinned compiler settings
  (solc 0.8.26, optimizer 200 runs, EVM `cancun`, metadata hash none). This belongs to the
  launch's deployer.
- **Holder hygiene.** Because there is no recovery mechanism, tokens sent to a wrong address or to
  a contract that cannot move them are lost. Integrators should approve exact amounts rather than
  `type(uint256).max` where practical.
- **Nothing to pause.** If an integrating application has a problem, the application must handle
  it; the token cannot be stopped or altered. This is intentional and is the trust model: holders
  never rely on anyone.

## Repository layout

```
foundry.toml                     compiler pins and build settings (root project; the verifier builds here)
remappings.txt                   forge-std/ and @openzeppelin/contracts/ remappings
src/VerdictToken.sol             the token
script/DeployVerdictToken.s.sol  local deployment helper (no env reads; tests call deploy() directly)
test/VerdictToken.t.sol          unit + fuzz tests (success and failure paths)
test/VerdictToken.invariant.t.sol stateful invariant tests (supply constant, balances sum to supply)
lib/forge-std/                   forge-std 1.17.0 (commit 0258fe8), src only, vendored as plain files
lib/openzeppelin-contracts/      OpenZeppelin v5.4.0, only ERC20.sol and its four imports, vendored as plain files
```

Dependencies are committed as ordinary files, not git submodules, so the project builds offline.

## Checks

```
forge build
forge test
forge fmt --check
```

Run the fuzz tests with the verifier's seed to reproduce its run exactly:

```
FOUNDRY_FUZZ_SEED=0x74fa35e18943bfec498d33a170388c555fbb9d92fa2c7c1db21fb4b976d0f8c9 forge test
```

Results on the authoring machine (forge 1.8.3, solc 0.8.26): 34 tests pass, including 4 fuzz tests
(256 runs each) and 3 invariants (256 runs x 500 calls). Tests read no environment variables and do
not depend on the calling address, so they pass in any order and in parallel.

What the tests cover:

- metadata and the constants agreeing with each other and with the manifest supply;
- the whole supply minted exactly once to `msg.sender`, for EOAs, for a contract deployer, and for
  a fuzzed deployer address; `Transfer(0, deployer, supply)` and `SupplyMinted` emitted;
- `transfer` success paths (exact amount, whole balance, zero, self-transfer, chained transfers
  conserving supply) and failure paths (insufficient balance, empty account, zero receiver,
  fuzzed over-balance amounts);
- `approve`/`transferFrom` success paths (allowance set, overwritten, decremented, infinite
  allowance not decremented) and failure paths (insufficient allowance, no approval, owner balance
  too low, zero spender), plus a fuzz over allowance/spend pairs;
- that none of 22 common privileged selectors (`mint`, `pause`, `blacklist`, `freeze`, `burnFrom`,
  `transferOwnership`, `upgradeTo`, ...) exists, from the deployer or a stranger, and that a holder
  can still transfer afterwards; the deployer cannot pull from a holder without allowance;
- the token rejects ether and unknown selectors;
- the runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, fits EIP-170, and carries no
  CBOR metadata trailer (reproducible bytes for the launch);
- invariants: total supply constant, actor balances always sum to the supply, no stray balances.

## Security notes

Checked against the eth-security reference supplied with the task:

- No external calls, no reentrancy surface, no oracle, no randomness, no upgradeability.
- Solidity 0.8.26 checked arithmetic; the only arithmetic is OpenZeppelin's audited ERC-20.
- Decimals are 18 and fixed; integrators must still read `decimals()` rather than assume.
- No infinite approvals are granted by the token itself; users decide their own allowances.
- Tools run: `forge build`, `forge test` (unit, fuzz, invariant), `forge fmt --check`. Slither and
  Mythril were not available on this machine and did not run.

Passing tests are not an audit. Before release the launch's independent adversarial review applies.
