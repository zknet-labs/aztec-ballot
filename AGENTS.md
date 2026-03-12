# Agent & AI Contributor Guidelines — aztec-ballot

This project implements **delegated private voting** on the Aztec Network using three Noir smart
contracts and a TypeScript CLI demo. Read this file before making any changes.

---

## Project Overview

| Layer              | Path             | Purpose                                  |
| ------------------ | ---------------- | ---------------------------------------- |
| Noir contracts     | `contracts/`     | AgentRegistry, Operations, PrivateVoting |
| TypeScript scripts | `scripts/`       | CLI demo, deploy, wallet utilities       |
| Compiled artifacts | `app/artifacts/` | Generated — do not edit manually         |

Three contracts form a chain: AgentRegistry (fully private) → Operations (private + public) →
PrivateVoting (private → public tally).

---

## Aztec Version

The pinned version lives in **`aztec-version.txt`** (currently `3.0.0-devnet.6-patch.1`).

Every version-bearing file must agree with it:

| File                              | Field                              |
| --------------------------------- | ---------------------------------- |
| `aztec-version.txt`               | Canonical source of truth          |
| `package.json`                    | All `@aztec/*` dependency versions |
| `contracts/registry/Nargo.toml`   | `tag=` in aztec + field_note deps  |
| `contracts/operations/Nargo.toml` | `tag=` in aztec + field_note deps  |
| `contracts/voting/Nargo.toml`     | `tag=` in aztec dep                |

**Do not change the running Aztec version unilaterally.** When a version bump is needed,
coordinate with the human operator — changing the toolchain (`aztec-up`),
starting the local network (`aztec start --local-network`), and updating these files must
all happen together. The `scripts/setup_install.sh` script automates the file-sync step.

---

## Environment Setup

### Prerequisites

- Node.js ≥ 22
- Yarn 1.x (`packageManager` field in package.json)
- Docker (required for the Aztec local network)
- Aztec toolchain at the pinned version (see above)

### Install dependencies

```bash
yarn install
```

### Toolchain install / version switch

**Do not run this without coordinating with the human operator** — it changes the running
Aztec node version, which requires restarting the local network.

```bash
# Read the version from aztec-version.txt, then:
bash scripts/setup_install.sh
```

The setup script:

1. Detects OS/shell and sets `ROOTLESS=true`
2. Runs `aztec-up` to install/switch the toolchain to the pinned version
3. Rewrites all `@aztec/*` versions in `package.json`
4. Rewrites all `tag=` references in `contracts/*/Nargo.toml`
5. Sources the updated shell rc file

---

## Local Network

**Requires coordination with the human operator** — the network must run at the pinned version.

```bash
# In a separate terminal (keep running):
aztec start --local-network
```

Default node URL: `http://localhost:8080`

After restarting the network, clear stale PXE data:

```bash
rm -rf ~/.aztec/cli-wallet/.store
```

---

## Compile Contracts

No network required.

```bash
yarn build-contracts
```

This runs in sequence:

1. `yarn clean` — removes `contracts/target/`, `contracts/codegenCache.json`, `app/dist/`
2. `aztec compile` (from `contracts/`) — compiles all 3 Noir contracts
3. `aztec codegen target -o target` — generates TypeScript wrappers
4. `yarn link-test-artifacts` — copies `registry-AgentRegistry.json` → `operations-AgentRegistry.json`
   (cross-package artifact workaround for Noir TXE tests)
5. Copies `contracts/target/*.json` and `*.ts` → `app/artifacts/`

**After any contract change**, always run `yarn build-contracts` before testing or running the demo.

### Individual steps

```bash
yarn compile-contracts   # aztec compile only
yarn codegen-contracts   # codegen only
yarn clean               # remove all build artifacts
```

---

## Test Contracts (Noir TXE tests)

**No network required.** TXE tests run in the Aztec Testing eXecution Environment simulator.

```bash
yarn test-contracts
```

This runs `aztec test` from the `contracts/` workspace directory.

### What the tests cover

**`contracts/registry/src/main.nr`** — 4 tests:

- `test_register_and_prove_ok` — register agent, prove association succeeds
- `test_prove_fails_when_not_registered` — prove fails without registration
- `test_prove_fails_after_revoke` — prove fails after unregistration
- `test_re_register_after_revoke` — re-register after revoke restores association

**`contracts/operations/src/main.nr`** — 4 tests:

- `test_authorized_agent_can_consume_instruction` — full happy path: authorize → issue → consume
- `test_consume_fails_without_instruction` — consume fails if no instruction issued
- `test_issue_fails_without_registration` — rogue operator cannot issue
- `test_issue_fails_after_unregister` — revoked agent cannot receive instruction

**Important**: `yarn test-contracts` requires `yarn build-contracts` to have been run first
(specifically the `link-test-artifacts` step for cross-package artifact resolution). Run:

```bash
yarn build-contracts && yarn test-contracts
```

---

## Run the CLI Demo

**Requires the local network to be running.**

```bash
yarn start
```

The demo auto-detects whether contracts need to be deployed:

- No `.env` file → deploys fresh contracts
- Artifact hash mismatch (contracts recompiled) → deploys fresh contracts
- Existing `.env` with matching artifact hash → reuses deployed contracts

Force a fresh deploy:

```bash
yarn start-clean    # equivalent to yarn start --fresh
```

Deploy contracts without running the demo:

```bash
yarn deploy-contracts
```

### Demo accounts

The demo creates **one Operator** and **one Agent** automatically on startup via sponsored
fee payment (SponsoredFPC). No native tokens needed.

### Custom node URL

```bash
AZTEC_NODE_URL=http://my-node:8080 yarn start
```

### Non-interactive / E2E test mode

**Requires the local network to be running.** Set `NON_INTERACTIVE=true` to run the full
happy-path sequence without any user input:

```bash
yarn test-e2e
```

This is equivalent to running `NON_INTERACTIVE=true node --experimental-transform-types scripts/cli-demo.ts`.

The sequence executed is:

1. Register agent (option 1)
2. View agent status (option 6)
3. Issue vote instruction — auto-selects **candidate 1** (option 3)
4. Agent executes vote — **auto-waits** if window is not yet open (option 4)
5. End vote early — **auto-confirms** (option 5)
6. View vote results (option 7)
7. View voting window (option 8)
8. Unregister agent (option 2)

All auto-answered prompts are logged with an `[auto]` prefix so CI output remains readable.

The `NON_INTERACTIVE` flag works with any other env vars (`AZTEC_NODE_URL`, `FORCE_FRESH`, etc.):

```bash
yarn start-clean NON_INTERACTIVE=true   # force fresh deploy + e2e run
```

or equivalently:

```bash
NON_INTERACTIVE=true yarn start --fresh
```

---

## Production / Proofs

Proofs are **disabled by default** — the local sandbox accepts unproven transactions.
Enable for devnet/testnet deployment:

```bash
yarn deploy-production    # deploy with PROVER_ENABLED=true
yarn start-production     # run demo with PROVER_ENABLED=true
```

---

## Code Conventions

### Noir contracts

- One contract per Nargo crate under `contracts/`
- Use `dep::aztec::` imports in `voting/` (has `dep::` in its dependency declarations);
  use bare `aztec::` in `registry/` and `operations/`
- `#[external("private")]` for private execution, `#[external("public")]` for public,
  `#[external("utility")] unconstrained` for offchain read-only helpers
- `#[only_self]` on public functions that should only be called by the same contract
- `MessageDelivery.CONSTRAINED_ONCHAIN` / `MessageDelivery.UNCONSTRAINED_ONCHAIN` — choose
  explicitly on every `.deliver()` call; never leave delivery implicit
- No `return` statements inside `unconstrained` functions — use `if/else` expressions
- Hardcoded iteration bounds (e.g., `for i in 0..16`) are intentional; Noir requires
  compile-time loop bounds for `BoundedVec` iteration

### TypeScript

- ESM project (`"type": "module"`) — all imports use `.ts` extensions explicitly
- Run with `node --experimental-transform-types` (no build step required)
- `tsconfig.json` sets `noEmit: true` — TypeScript is type-checked but not compiled to JS
- Use `strict: false` is intentional (existing codebase convention)
- **Always call `.simulate()` before `.send()`** for every state-changing transaction.
  This surfaces revert reasons immediately rather than waiting for an opaque send timeout:

  ```typescript
  await contract.methods.my_fn(arg).simulate({ from: address });
  await contract.methods.my_fn(arg).send({ from: address, fee: { paymentMethod }, ... });
  ```

- `deployContracts()` in `scripts/deploy.ts` is both a library export and a standalone script
- Artifact hash in `.env` (`ARTIFACTS_HASH`) drives automatic redeploy detection

### Generated files — never edit manually

- `app/artifacts/*.ts` — generated by `aztec codegen`
- `app/artifacts/*.json` — generated by `aztec compile`
- `contracts/target/` — compilation output
- `yarn.lock` — only update via `yarn install`

---

## Project Structure

```
aztec-version.txt              # Pinned Aztec version — single source of truth
package.json                   # Node deps + yarn scripts
tsconfig.json                  # TypeScript config (ES2022, ESNext, Bundler resolution)
contracts/
  Nargo.toml                   # Workspace: [registry, operations, voting]
  registry/
    Nargo.toml                 # aztec + field_note deps at pinned tag
    src/main.nr                # AgentRegistry contract + TXE tests
  operations/
    Nargo.toml                 # aztec + field_note + registry deps
    src/main.nr                # Operations contract + TXE tests
  voting/
    Nargo.toml                 # aztec + operations dep
    src/main.nr                # PrivateVoting contract
scripts/
  setup_install.sh             # Toolchain install + version sync (run manually)
  deploy.ts                    # Shared deploy logic + standalone deploy script
  cli-demo.ts                  # Interactive CLI demo (main entry point)
  wallet-utils.ts              # CLIWallet: account creation, connection, storage
app/
  artifacts/                   # Generated artifacts (do not edit)
```

---

## Environment Variables

| Variable                      | Default                 | Purpose                                                |
| ----------------------------- | ----------------------- | ------------------------------------------------------ |
| `AZTEC_NODE_URL`              | `http://localhost:8080` | Aztec node endpoint                                    |
| `PROVER_ENABLED`              | `false`                 | Enable ZK proof generation                             |
| `WRITE_ENV_FILE`              | `true`                  | Persist deployment info to `.env`                      |
| `NON_INTERACTIVE`             | `false`                 | Run CLI demo non-interactively (e2e test mode)         |
| `REGISTRY_CONTRACT_ADDRESS`   | —                       | Set by deploy; read by CLI demo                        |
| `OPERATIONS_CONTRACT_ADDRESS` | —                       | Set by deploy; read by CLI demo                        |
| `VOTING_CONTRACT_ADDRESS`     | —                       | Set by deploy; read by CLI demo                        |
| `ARTIFACTS_HASH`              | —                       | SHA-256 of artifact JSONs; triggers redeploy on change |

Copy `.env.example` to `.env` to pre-populate (or let `yarn deploy-contracts` write it).

---

## Key Limitations (Known)

- **Note iteration bound**: `get_notes` loops are bounded at 16. An operator can register
  at most ~16 unique agents before hitting this ceiling in `prove_association_for`.
- **CRS limit**: `prove_association_for` already uses 2 `get_notes` calls (associations +
  revocations) — at the practical circuit limit. Do not add more `get_notes` calls to that
  function.
- **Append-only notes**: Registration/revocation notes are never deleted. Note counts grow
  with each register/unregister cycle.
- **Sandbox timestamps**: The sandbox advances block time ~10 min per block, unrelated to
  wall-clock time. Use `end_vote()` (menu option 5) to close voting in demos rather than
  waiting for the time window to expire.
- **Cross-package test artifacts**: Operations tests deploy AgentRegistry using the
  `link-test-artifacts` workaround (`operations-AgentRegistry.json` symlink). Always run
  `yarn build-contracts` before `yarn test-contracts`.

---

## Pull Requests

- Commit messages should be concise and describe _why_, not just _what_.
- State which tests were run (TXE unit tests, `yarn test-e2e`, CLI demo, or some combination).
- Do not commit generated artifacts (`app/artifacts/`, `contracts/target/`).
- Do not commit `.env` (contains deployment addresses that are environment-specific).
- Do not change `aztec-version.txt` without coordinating a full version upgrade.
