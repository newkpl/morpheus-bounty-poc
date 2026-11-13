# Morpheus Bug Bounty — Proof-of-Concept Tests

Foundry fork tests for two reports submitted to the Morpheus (Lumerin)
bug bounty program (devs@mor.org). Each test runs against a mainnet
fork pinned to a block and targets the deployed Appendix A contract —
no privileged accounts are used anywhere; all actors are fresh,
unprivileged addresses created inside the test.

## Requirements

- Foundry (`forge`) — developed against forge 1.9.0, solc 0.8.24
- Network access to the public fork RPC endpoints configured in
  `foundry.toml` (`base` / `eth` — publicnode)

## Run

Full suite:

```sh
forge test
```

Per report:

```sh
# SR-1 — SessionRouter provider approvals are not bound to the approved user
# (LumerinDiamond, Base — fork pinned at Base block 56,849,002)
forge test --match-test test_approvalNotBoundToUser
forge test --match-test test_victimOpensWithOwnApproval

# DP-1 — DepositPool self-referral collects both referral reward streams
# (DepositPool stETH pool, Ethereum — fork pinned at block 26,404,985)
forge test --match-test test_selfReferralUplift
```

`test/BuildersConservation.t.sol` is a supporting conservation check
for the Builders protocol that was run during the same assessment
(no finding; included for completeness).

## Layout

- `foundry.toml` — project config + fork RPC endpoints
- `test/Harness.sol` — minimal self-contained harness (cheatcode
  interface, token interface, assertion helpers; no external imports)
- `test/SessionApproval.t.sol` — SR-1 proof of concept
- `test/SelfReferral.t.sol` — DP-1 proof of concept

The tests are fully self-contained: no library dependencies beyond a
Foundry installation itself.
