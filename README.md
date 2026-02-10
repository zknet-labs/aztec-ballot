# Aztec-Ballot

A privacy-first delegated voting system built on the [Aztec Network](https://aztec.network/). An **Operator** privately registers an **Agent**, issues a vote instruction, and the Agent executes the vote — all without revealing any association between them on-chain.

## Prerequisites

- **Node.js** ≥ 22.0
- **Docker Desktop** (for Aztec sandbox / local network)
- **Aztec toolchain** (installed via setup script)
- Works on **macOS** (zsh/bash) and **Linux** (bash/zsh)
- Works on top of the local network, but can be adapted to work with a testnet

## Quick Start

### 1. Run the Setup Script

The setup script handles everything: Docker security, Aztec toolchain installation, version syncing, and dependency management. It can be run from any directory.

```bash
bash scripts/setup_install.sh
```

**What the setup script does:**

1. **OS & shell detection** — detects macOS/Linux and zsh/bash, uses the correct rc file
2. **Docker check** — verifies Docker is installed and running (platform-specific guidance)
3. **Mount security** — restricts Docker file access to your project directory (not `$HOME`)
4. **ROOTLESS env** — sets `ROOTLESS=true` in your shell rc file
5. **Version detection** — reads `aztec-version.txt` from project root
6. **Toolchain install/update** — runs `aztec-up` to match the project version
7. **Dependency sync** — updates all `@aztec/*` versions in `package.json` and all `tag=` references in `contracts/*/Nargo.toml` to match `aztec-version.txt`
8. **Security patches** — restricts Docker mount paths and configures nargo cache
9. **Docker Desktop config** — guides you through file sharing settings (skipped on native Linux Docker Engine)
10. **Auto-reload** — sources your shell rc file automatically if it was modified

### 2. Start the Aztec Sandbox

In a separate terminal:

```bash
aztec start --local-network
```

### 3. Compile Contracts

```bash
yarn build-contracts
```

### 4. Run the Demo

```bash
yarn start
```

The demo **automatically detects** whether contracts need to be deployed:
- **No `.env` file** → deploys fresh contracts
- **Contracts recompiled** (artifact hash changed) → deploys fresh contracts
- **Existing `.env` with matching artifacts** → reuses deployed contracts

You can also force a fresh deploy:

```bash
yarn start-clean
```

Or deploy contracts separately (writes `.env` for use by other tools):

```bash
yarn deploy-contracts
```

### Proofs

Proofs are **disabled by default** — the local sandbox accepts unproven transactions. For production deployment against a testnet/mainnet:

```bash
yarn deploy-production
yarn start-production
```

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                    CLI Demo (TypeScript)                  │
│  Operator account ←→ Agent account (auto-created)        │
└────────┬──────────────────────────────────┬──────────────┘
         │ private txs                      │ private + public txs
         ▼                                  ▼
┌─────────────────┐   ┌──────────────────┐  ┌────────────────────┐
│ AgentRegistry    │   │ Operations       │  │ PrivateVoting      │
│ (all private)    │◄──│ (private+public) │◄─│ (private→public)   │
│                  │   │                  │  │                    │
│ register_agent   │   │ issue_vote_instr │  │ cast_vote          │
│ unregister_agent │   │ consume_vote_ins │  │ add_to_tally_pub   │
│ prove_assoc_for  │   │ _mark_voted_pub  │  │ end_vote           │
└──────────────────┘   └──────────────────┘  └────────────────────┘
```

**Three Noir contracts** in a Nargo workspace:

| Contract | Purpose | State |
|---|---|---|
| **AgentRegistry** | Private operator↔agent association | All private |
| **Operations** | Vote instruction delivery + voted flag | Private notes + public `has_voted` |
| **PrivateVoting** | Tally, nullifier, time window | Private vote → public tally |

## CLI Demo Walkthrough

The demo creates one Operator and one Agent automatically, then presents a menu:

```
========== OPERATIONS MENU ==========
Operator : 0x1234...
Agent    : 0x5678...

--- Registration (private) ---
 1. Register agent
 2. Unregister agent

--- Voting (operator decides → agent executes) ---
 3. Issue vote instruction to agent
 4. Agent: execute vote

--- Admin ---
 5. End vote early (reveal results)

--- View ---
 6. View agent status
 7. View vote results
 8. View voting window

 0. Exit
```

### Typical Demo Flow

1. **Register agent** (option 1) — operator privately associates with agent
2. **Issue vote instruction** (option 3) — operator picks candidate, instruction delivered as private note
3. **Agent executes vote** (option 4) — agent consumes instruction, vote goes to tally
4. **End vote early** (option 5) — admin closes voting so results are visible
5. **View results** (option 7) — see the tally

### What Each Option Does

| # | Action | Who | Privacy |
|---|---|---|---|
| 1 | Register agent in Registry | Operator | Fully private |
| 2 | Unregister (revoke) agent | Operator | Fully private |
| 3 | Issue vote instruction | Operator | Private note to agent |
| 4 | Execute the vote | Agent | Private→public tally |
| 5 | End vote early | Admin (=operator) | Public state change |
| 6 | View agent status | — | Simulates private calls |
| 7 | View vote results | — | Public read (after vote ends) |
| 8 | View voting window | — | Public read |

## Environment

The CLI demo automatically loads deployment information from `.env` file. It also stores an `ARTIFACTS_HASH` to detect when contracts have been recompiled since the last deploy.

### Supported Networks

- **Local Network** (default): `http://localhost:8080`
- **Custom Network**: Set `AZTEC_NODE_URL` environment variable

```sh
AZTEC_NODE_URL=http://custom-node:8080 yarn start
```

## Updating the Aztec Version

1. Edit `aztec-version.txt` with the new version
2. Re-run the setup script:

```bash
bash scripts/setup_install.sh
```

The script will:
- Update the Aztec toolchain via `aztec-up`
- Rewrite all `@aztec/*` versions in `package.json`
- Rewrite all `tag=` references in `contracts/*/Nargo.toml`
- Auto-reload your shell config

Then recompile:

```bash
yarn build-contracts
```

## Available Scripts

| Script | Description |
|---|---|
| `yarn build-contracts` | Clean, compile, codegen, copy artifacts |
| `yarn test-contracts` | Run Noir contract tests (`aztec test`) |
| `yarn deploy-contracts` | Deploy all 3 contracts, write `.env` |
| `yarn start` | Run CLI demo (auto-deploys if needed) |
| `yarn start-clean` | Force fresh deploy + run CLI demo |
| `yarn deploy-production` | Deploy with proofs enabled (testnet/mainnet) |
| `yarn start-production` | Run CLI demo with proofs enabled |
| `yarn clean` | Remove build artifacts |

## Project Structure

```
aztec-version.txt           # Pinned Aztec version
package.json                # Node deps + scripts
contracts/
  Nargo.toml                # Workspace (registry, operations, voting)
  registry/src/main.nr      # AgentRegistry contract
  operations/src/main.nr    # Operations contract
  voting/src/main.nr        # PrivateVoting contract
scripts/
  setup_install.sh          # One-command project setup (macOS + Linux)
  cli-demo.ts               # Interactive CLI demo
  deploy.ts                 # Shared deploy logic + standalone deploy script
  wallet-utils.ts           # CLIWallet helper
app/artifacts/              # Compiled contract artifacts + TS wrappers
```

## Troubleshooting

### `ECONNREFUSED` on startup
Ensure the sandbox is running: `aztec start --local-network`

### Voting window shows "OPEN" but vote was ended
This was fixed — the demo now checks the `vote_ended` flag via `is_vote_finished()` in addition to timestamp checks. If you see "ENDED EARLY" in the status, the admin has already closed voting.

### Voting window shows far-future dates
The sandbox block timestamp runs ahead of wall clock (~10 min per block). Use the "End vote early" option (menu option 5) instead of waiting for the time window.

### Contracts auto-redeployed unexpectedly
The demo compares a SHA-256 hash of the artifact JSON files against the hash stored in `.env`. If you ran `yarn build-contracts`, the artifacts changed and the demo correctly redeploys. Use `yarn start-clean` to force this behavior explicitly.

### Contract test artifacts not found
Run `yarn build-contracts` — this includes the `link-test-artifacts` step that copies cross-package artifacts.

## More Info
- [Aztec Quick Start Guide](https://docs.aztec.network/developers/getting_started)
- [APPLICATION_GUIDE.md](APPLICATION_GUIDE.md) — full technical deep-dive