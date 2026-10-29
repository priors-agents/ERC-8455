# ERC-8462: Token Launch Declarations (draft)

The facts a launchpad declares when it launches a token, attached to the launches that ERC-8376 (Token Launch Abuse
Detection and Remediation) already lists: the creator and its ERC-8004 identity, the supply allocated outside the sale
and how it vests, the lock that holds the liquidity and any financing of it, and where the creator's fees go. The
launchpad declares them in its launch transaction; detectors, wallets and lenders compare them with what they observe.

A launch the ERC-8376 directory lists is declared under its `launchId`, by the venue the directory names, with the
creator read from the directory, so the two never disagree. Any other launch is declared under an id scoped to the venue
that declares it, so two venues never collide and nobody can squat another venue's id. A venue names a creator outside
the directory, or attaches a creator's identity, only with that creator's authorization: the creator calls, or signs
(EIP-712, or ERC-1271 for a contract account). Nothing declared can change.

**Status: draft, submitted as [ethereum/ERCs#2106](https://github.com/ethereum/ERCs/pull/2106).** The text is in
[`ERCS/erc-8462.md`](ERCS/erc-8462.md). The editors assigned it ERC-8462 on 2026-10-27. Discussion: [Ethereum
Magicians](https://ethereum-magicians.org/t/erc-8462-launch-declarations/30038).

## Why

A buyer, a scanner or a lender looking at a new token cannot read, in any common form, who launched it, whether that
creator has a record to lose, how much supply it kept and on what schedule, or whether the liquidity is locked or
borrowed. ERC-8376 has detectors infer a deployer's conduct after the fact, and two of its abuse patterns ("undisclosed
pre-allocation", control kept "contrary to what was disclosed at launch") assume a disclosure it never defines. The
launchpad knows all of it at launch. Declaring it there, in typed fields a contract can read, makes each fact a public
claim that can be checked against the chain, and the declared ERC-8004 identity lets a reader fetch the creator's record
when it decides.

The nearest other proposal we know of is the Token Behavior Declaration idea on Ethereum Magicians
([t/29464](https://ethereum-magicians.org/t/29464), August 2026, no pull request). It declares a token's own mechanics
(fee on transfer, mintable, pausable and the like) as bit flags fixed at deployment, and says nothing about the creator,
the allocations, the liquidity and its financing, or the fee recipient. The two fit together: one describes the token
contract, the other the launch.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-8462.md` | The ERC text, in the ethereum/ERCs template |
| `src/ILaunchDeclarations.sol` | The interface |
| `src/ILaunchDirectory.sol` | ERC-8376's directory interface, which the reference reads |
| `src/LaunchDeclarations.sol` | A reference declarations contract (not audited) |
| `test/LaunchDeclarations.t.sol` | Foundry tests: both id kinds, creator signatures, squatting, collisions, lookups |
| `test/mocks/Mocks.sol` | Mock ERC-8376 directory, identity registries, ERC-1271 wallet, launchpad |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Liquidity Locks: one interface for any contract that locks pool liquidity
  (github.com/priors-agents/erc-liquidity-locks). A declared liquidity fact names a lock by its contract and id there, unless it declares
  the financing of liquidity in no lock.
- Creator Fee Rights: a launched token's creator fee stream, its history, and a recipient only the recipient can change
  (github.com/priors-agents/erc-creator-fee-rights). A declared fee recipient names the contract that accounts the fees.
- Agent Default Registry: lender-reported loan defaults of agent identities, countable on chain against trusted
  reporters (github.com/priors-agents/erc-agent-default-registry). A reader looks up the declared creator identity's
  defaults there.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
