#!/usr/bin/env node

import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { createAztecNodeClient, type AztecNode } from '@aztec/aztec.js/node';
import { getContractInstanceFromInstantiationParams } from '@aztec/aztec.js/contracts';

import { SponsoredFeePaymentMethod } from '@aztec/aztec.js/fee';
import { SponsoredFPCContractArtifact } from '@aztec/noir-contracts.js/SponsoredFPC';
import { SPONSORED_FPC_SALT } from '@aztec/constants';
import { Fr } from '@aztec/foundation/curves/bn254';

import { readFileSync, existsSync } from 'fs';
import * as readline from 'readline';
import * as path from 'path';

import { CLIWallet } from './wallet-utils.ts';
import {
  deployContracts,
  writeEnvFile,
  computeArtifactsHash,
  VOTE_START_DELAY_SECONDS,
  VOTE_DURATION_SECONDS,
  ENV_FILE_PATH,
  type DeploymentInfo,
} from './deploy.ts';

// Generated wrappers from app/artifacts
// @ts-ignore
import { AgentRegistryContract } from '../app/artifacts/AgentRegistry.ts';
// @ts-ignore
import { OperationsContract } from '../app/artifacts/Operations.ts';
// @ts-ignore
import { PrivateVotingContract } from '../app/artifacts/PrivateVoting.ts';

// ============================================================================
// CLI helpers
// ============================================================================

const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  green: '\x1b[32m',
  blue: '\x1b[34m',
  yellow: '\x1b[33m',
  red: '\x1b[31m',
  cyan: '\x1b[36m',
};

const log = (msg: string, color: string = colors.reset) =>
  console.log(`${color}${msg}${colors.reset}`);

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

const question = (prompt: string, nonInteractiveDefault: string = ''): Promise<string> =>
  NON_INTERACTIVE
    ? (log(`[auto] ${prompt}${nonInteractiveDefault}`, colors.yellow), Promise.resolve(nonInteractiveDefault))
    : new Promise(resolve => rl.question(`${colors.cyan}${prompt}${colors.reset}`, resolve));

const short = (addr?: AztecAddress) => (addr ? `${addr.toString().slice(0, 10)}...` : '—');

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

const FORCE_FRESH = process.argv.includes('--fresh');
const NON_INTERACTIVE = process.env.NON_INTERACTIVE === 'true';

// ============================================================================
// Repo root
// ============================================================================

const repoRoot = path.dirname(path.dirname(import.meta.url).replace('file://', ''));

// ============================================================================
// Global runtime state
// ============================================================================

let wallet: CLIWallet;
let node: AztecNode;

let registryAddr: AztecAddress;
let operationsAddr: AztecAddress;
let votingAddr: AztecAddress;

let operatorAddr: AztecAddress;
let agentAddr: AztecAddress;

// ============================================================================
// Env loading
// ============================================================================

function loadEnvFromRepoRoot(): Record<string, string> {
  const envPath = path.join(repoRoot, '.env');
  if (!existsSync(envPath)) return {};
  const envContent = readFileSync(envPath, 'utf-8');

  return Object.fromEntries(
    envContent
      .split('\n')
      .filter(line => line.trim() && !line.trim().startsWith('#'))
      .map(line => {
        const [k, ...rest] = line.split('=');
        return [k.trim(), rest.join('=').trim()];
      }),
  );
}

// ============================================================================
// Detect whether a fresh deploy is needed
// ============================================================================

function needsFreshDeploy(envVars: Record<string, string>): { needed: boolean; reason: string } {
  if (FORCE_FRESH) {
    return { needed: true, reason: '--fresh flag provided' };
  }

  // No .env or missing addresses → need deploy
  if (!envVars.REGISTRY_CONTRACT_ADDRESS || !envVars.OPERATIONS_CONTRACT_ADDRESS || !envVars.VOTING_CONTRACT_ADDRESS) {
    return { needed: true, reason: 'no deployed contract addresses found in .env' };
  }

  // Artifacts changed since last deploy → need redeploy
  const deployedHash = envVars.ARTIFACTS_HASH || '';
  const currentHash = computeArtifactsHash();
  if (deployedHash !== currentHash) {
    return { needed: true, reason: `contracts recompiled (artifact hash: ${deployedHash.slice(0, 8) || 'none'} → ${currentHash.slice(0, 8)})` };
  }

  return { needed: false, reason: '' };
}

// ============================================================================
// PXE registrations
// ============================================================================

async function registerContractsInPXE() {
  const w = wallet.getWallet();

  log('Registering SponsoredFPC + deployed contracts in PXE...', colors.yellow);

  const sponsoredInstance = await getContractInstanceFromInstantiationParams(
    SponsoredFPCContractArtifact,
    { salt: new Fr(SPONSORED_FPC_SALT) },
  );
  await w.registerContract(sponsoredInstance, SponsoredFPCContractArtifact);

  const regInstance = await node.getContract(registryAddr);
  if (!regInstance) throw new Error(`Node could not find Registry at ${registryAddr.toString()}`);
  await w.registerContract(regInstance, AgentRegistryContract.artifact);

  const opsInstance = await node.getContract(operationsAddr);
  if (!opsInstance) throw new Error(`Node could not find Operations at ${operationsAddr.toString()}`);
  await w.registerContract(opsInstance, OperationsContract.artifact);

  const votingInstance = await node.getContract(votingAddr);
  if (!votingInstance) throw new Error(`Node could not find Voting at ${votingAddr.toString()}`);
  await w.registerContract(votingInstance, PrivateVotingContract.artifact);

  log('✓ Contracts registered in PXE\n', colors.green);
}

// ============================================================================
// Wallet helpers
// ============================================================================

function getAccountWallet() {
  const accountObj = wallet.getConnectedAccountObject();
  return accountObj?.wallet || wallet.getWallet();
}

function getConnectedAddress(): AztecAddress {
  const connected = wallet.getConnectedAccount();
  if (!connected) throw new Error('No account connected');
  return connected;
}

async function switchToOperator(): Promise<void> {
  const accounts = await wallet.listWalletAccounts();
  const idx = accounts.findIndex(a => a.toString() === operatorAddr.toString());
  if (idx < 0) throw new Error('Operator not found in PXE');
  await wallet.connectWalletAccountByIndex(idx);
}

async function switchToAgent(): Promise<void> {
  const accounts = await wallet.listWalletAccounts();
  const idx = accounts.findIndex(a => a.toString() === agentAddr.toString());
  if (idx < 0) throw new Error('Agent not found in PXE');
  await wallet.connectWalletAccountByIndex(idx);
}

// ============================================================================
// Init — creates one operator + one agent automatically
// ============================================================================

async function initialize() {
  log('\n========================================', colors.bright);
  log('  AZTEC OPERATOR ↔ AGENT CLI DEMO', colors.bright);
  log('========================================\n', colors.bright);

  const envVars = loadEnvFromRepoRoot();
  const nodeUrl = envVars.AZTEC_NODE_URL || process.env.AZTEC_NODE_URL || 'http://localhost:8080';

  node = createAztecNodeClient(nodeUrl);
  wallet = await CLIWallet.initialize(nodeUrl);

  // Create operator + agent accounts
  log('Creating Operator account...', colors.yellow);
  operatorAddr = await wallet.createAccountAndConnect();
  log(`✓ Operator: ${operatorAddr.toString()}`, colors.green);

  log('Creating Agent account...', colors.yellow);
  agentAddr = await wallet.createAccountAndConnect();
  log(`✓ Agent:    ${agentAddr.toString()}\n`, colors.green);

  // Start as operator
  await switchToOperator();

  // Decide: fresh deploy or reuse existing contracts
  const { needed, reason } = needsFreshDeploy(envVars);

  if (needed) {
    log(`⟳ Fresh deploy needed: ${reason}`, colors.yellow);
    await deployFreshContracts(nodeUrl);
  } else {
    registryAddr = AztecAddress.fromString(envVars.REGISTRY_CONTRACT_ADDRESS);
    operationsAddr = AztecAddress.fromString(envVars.OPERATIONS_CONTRACT_ADDRESS);
    votingAddr = AztecAddress.fromString(envVars.VOTING_CONTRACT_ADDRESS);

    log(`Registry   : ${registryAddr.toString()}`, colors.green);
    log(`Operations : ${operationsAddr.toString()}`, colors.green);
    log(`Voting     : ${votingAddr.toString()}\n`, colors.green);
  }

  await registerContractsInPXE();
}

// ============================================================================
// Fee helper (sponsored)
// ============================================================================

async function sponsoredFee() {
  const sponsoredInstance = await getContractInstanceFromInstantiationParams(
    SponsoredFPCContractArtifact,
    { salt: new Fr(SPONSORED_FPC_SALT) },
  );

  return {
    fee: { paymentMethod: new SponsoredFeePaymentMethod(sponsoredInstance.address) },
  };
}

// ============================================================================
// Fresh deploy — delegates to shared deploy.ts
// ============================================================================

async function deployFreshContracts(nodeUrl: string): Promise<void> {
  const w = wallet.getWallet();

  log('\n--- Deploying fresh contracts ---', colors.yellow);
  log(`  Vote start delay: ${VOTE_START_DELAY_SECONDS}s`, colors.cyan);
  log(`  Vote duration:    ${VOTE_DURATION_SECONDS / 60} min\n`, colors.cyan);

  const info = await deployContracts(w, operatorAddr);

  registryAddr = AztecAddress.fromString(info.registryAddress);
  operationsAddr = AztecAddress.fromString(info.operationsAddress);
  votingAddr = AztecAddress.fromString(info.votingAddress);

  log(`  ✓ Registry:   ${registryAddr}`, colors.green);
  log(`  ✓ Operations: ${operationsAddr}`, colors.green);
  log(`  ✓ Voting:     ${votingAddr}`, colors.green);

  // Persist so next run can reuse (if artifacts haven't changed)
  writeEnvFile(info, ENV_FILE_PATH, nodeUrl);
  log(`  ✓ Saved to .env\n`, colors.green);
}

// ============================================================================
// Voting window helpers
// ============================================================================

async function getVotingWindowStatus(caller: AztecAddress): Promise<{
  start: number;
  deadline: number;
  endedEarly: boolean;
}> {
  const voting = PrivateVotingContract.at(votingAddr, getAccountWallet());
  const start = Number(await voting.methods.get_start_timestamp().simulate({ from: caller }));
  const deadline = Number(await voting.methods.get_deadline_timestamp().simulate({ from: caller }));
  const finished = await voting.methods.is_vote_finished().simulate({ from: caller });

  // If finished but we're still before the deadline, admin ended it early
  const currentTime = await getCurrentTimestamp();
  const endedEarly = finished && currentTime <= deadline;

  return { start, deadline, endedEarly };
}

function formatWindowStatus(currentTime: number, start: number, deadline: number, endedEarly: boolean = false): string {
  const fmt = (ts: number) => new Date(ts * 1000).toLocaleTimeString();
  if (endedEarly) {
    return `ENDED EARLY — admin ended the vote before the deadline`;
  } else if (currentTime < start) {
    const secsLeft = start - currentTime;
    return `WAITING — opens at ${fmt(start)} (${secsLeft}s away)`;
  } else if (currentTime <= deadline) {
    const secsLeft = deadline - currentTime;
    return `OPEN — closes at ${fmt(deadline)} (${secsLeft}s remaining)`;
  } else {
    const secsAgo = currentTime - deadline;
    return `CLOSED — ended at ${fmt(deadline)} (${secsAgo}s ago)`;
  }
}

function getUTCCurrentTimestamp(): number {
  return Math.floor(Date.now() / 1000);
}

async function getCurrentTimestamp(): Promise<number> {
  const blockNumber = await node.getBlockNumber();
  const block = await node.getBlock(blockNumber);
  if (!block) return Math.floor(Date.now() / 1000);
  return Number(block.header.globalVariables.timestamp);
}

async function waitForVotingWindow(
  startTimestamp: number,
  deadline: number,
  pollIntervalMs: number = 5000,
): Promise<'open' | 'expired'> {
  let current = await getCurrentTimestamp();

  if (current > deadline) return 'expired';
  if (current >= startTimestamp) return 'open';

  const fmt = (ts: number) => new Date(ts * 1000).toLocaleTimeString();
  log(`\n⏳ Voting window opens at ${fmt(startTimestamp)}. Now: ${fmt(current)}.`, colors.yellow);
  log(`   Polling every ${pollIntervalMs / 1000}s... (Ctrl+C to cancel)\n`, colors.yellow);

  while (current < startTimestamp) {
    await sleep(pollIntervalMs);
    current = await getCurrentTimestamp();

    const secsLeft = startTimestamp - current;
    if (secsLeft > 0) {
      process.stdout.write(
        `${colors.yellow}   ${fmt(current)} — ${secsLeft}s until window opens...\r${colors.reset}`,
      );
    }

    if (current > deadline) {
      log('\n✗ Deadline passed while waiting!', colors.red);
      return 'expired';
    }
  }

  log(`\n✓ Voting window is now OPEN!`, colors.green);
  return 'open';
}

// ============================================================================
// Contract actions
// ============================================================================

async function operatorRegisterAgent(): Promise<void> {
  await switchToOperator();
  const operator = getConnectedAddress();

  log('\n--- Operator: register_agent (private) ---', colors.blue);
  log(`Agent: ${short(agentAddr)}`, colors.cyan);

  try {
    const registry = AgentRegistryContract.at(registryAddr, getAccountWallet());
    log('Submitting tx...', colors.yellow);

    const receipt = await registry.methods
      .register_agent(agentAddr)
      .send({ from: operator, ...(await sponsoredFee()), wait: { timeout: 120 } });

    log(`✓ Agent registered`, colors.green);
    log(`  txHash: ${receipt.txHash}\n`, colors.cyan);
  } catch (e) {
    log(`✗ Failed: ${e instanceof Error ? e.message : String(e)}`, colors.red);
  }
}

async function operatorUnregisterAgent(): Promise<void> {
  await switchToOperator();
  const operator = getConnectedAddress();

  log('\n--- Operator: unregister_agent (private) ---', colors.blue);
  log(`Agent: ${short(agentAddr)}`, colors.cyan);

  try {
    const registry = AgentRegistryContract.at(registryAddr, getAccountWallet());
    log('Submitting tx...', colors.yellow);

    const receipt = await registry.methods
      .unregister_agent(agentAddr)
      .send({ from: operator, ...(await sponsoredFee()), wait: { timeout: 120 } });

    log(`✓ Agent unregistered`, colors.green);
    log(`  txHash: ${receipt.txHash}\n`, colors.cyan);
  } catch (e) {
    log(`✗ Failed: ${e instanceof Error ? e.message : String(e)}`, colors.red);
  }
}

async function operatorIssueVoteInstruction(): Promise<void> {
  await switchToOperator();
  const operator = getConnectedAddress();

  log('\n--- Operator: Issue Vote Instruction (private) ---', colors.blue);

  // Show current voting window status
  try {
    const { start, deadline, endedEarly } = await getVotingWindowStatus(operator);
    const current = await getCurrentTimestamp();
    const status = formatWindowStatus(current, start, deadline, endedEarly);
    const fmt = (ts: number) => new Date(ts * 1000).toLocaleTimeString();
    log(`Voting window: ${status}`, colors.cyan);
    log(`  Window: ${fmt(start)} → ${fmt(deadline)}  |  Now: ${fmt(current)}\n`, colors.cyan);

    if (endedEarly) {
      log('✗ Vote was ended early by admin. Cannot issue instruction.', colors.red);
      return;
    }

    if (current > deadline) {
      log('✗ Voting window has already closed. Cannot issue instruction.', colors.red);
      return;
    }

    if (current < start) {
      log('Note: window not yet open. Agent will auto-wait when executing.\n', colors.yellow);
    }
  } catch {
    log('(Could not fetch voting window info — continuing anyway)\n', colors.yellow);
  }

  log(`Target agent: ${short(agentAddr)}`, colors.cyan);
  log('Candidates: 1, 2, 3, 4, 5\n', colors.cyan);

  const candidateStr = await question('Select candidate (1-5): ', '1');
  const candidate = parseInt(candidateStr.trim());

  if (isNaN(candidate) || candidate < 1 || candidate > 5) {
    log('✗ Invalid candidate number', colors.red);
    return;
  }

  try {
    const ops = OperationsContract.at(operationsAddr, getAccountWallet());
    log('Submitting vote instruction tx...', colors.yellow);

    const receipt = await ops.methods
      .issue_vote_instruction(agentAddr, candidate)
      .send({ from: operator, ...(await sponsoredFee()), wait: { timeout: 120 } });

    log(`✓ Vote instruction issued to agent!`, colors.green);
    log(`  Candidate: ${candidate}`, colors.cyan);
    log(`  Agent: ${short(agentAddr)}`, colors.cyan);
    log(`  txHash: ${receipt.txHash}`, colors.cyan);
    log('  Now run "Agent: execute vote".\n', colors.green);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('Not associated')) {
      log('✗ Agent not registered. Register the agent first.', colors.red);
    } else if (msg.includes('Association revoked')) {
      log('✗ Agent has been unregistered.', colors.red);
    } else {
      log(`✗ Failed: ${msg}`, colors.red);
    }
  }
}

async function agentExecuteVote(): Promise<void> {
  await switchToAgent();
  const agent = getConnectedAddress();

  log('\n--- Agent: Execute Vote (private → public tally) ---', colors.blue);
  log('The agent consumes the operator\'s vote instruction note.', colors.yellow);
  log('Only the tally changes publicly.\n', colors.yellow);

  // Check voting window before submitting
  try {
    const { start, deadline, endedEarly } = await getVotingWindowStatus(agent);
    const current = await getCurrentTimestamp();
    const status = formatWindowStatus(current, start, deadline, endedEarly);
    const fmt = (ts: number) => new Date(ts * 1000).toLocaleTimeString();
    log(`Voting window: ${status}`, colors.cyan);
    log(`  Window: ${fmt(start)} → ${fmt(deadline)}  |  Now: ${fmt(current)}\n`, colors.cyan);

    if (endedEarly) {
      log('✗ Vote was ended early by admin. Cannot vote.', colors.red);
      return;
    }

    if (current > deadline) {
      log('✗ Voting window has closed. Cannot vote.', colors.red);
      return;
    }

    if (current < start) {
      const proceed = (await question('Window not open yet. Wait for it? (y/n): ', 'y')).trim().toLowerCase();
      if (proceed !== 'y') {
        log('Cancelled.', colors.yellow);
        return;
      }

      const result = await waitForVotingWindow(start, deadline);
      if (result === 'expired') {
        log('✗ Voting window expired while waiting.', colors.red);
        return;
      }
    }
  } catch {
    log('(Could not fetch voting window — attempting vote anyway)\n', colors.yellow);
  }

  try {
    const voting = PrivateVotingContract.at(votingAddr, getAccountWallet());
    log('Submitting vote tx...', colors.yellow);

    const receipt = await voting.methods
      .cast_vote()
      .send({ from: agent, ...(await sponsoredFee()), wait: { timeout: 120 } });

    log(`✓ Vote executed on-chain!`, colors.green);
    log(`  txHash: ${receipt.txHash}`, colors.cyan);
    log('  The candidate was chosen by the operator. Only the tally changed publicly.\n', colors.green);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('nullifier') || msg.includes('already')) {
      log('✗ This agent has already voted!', colors.red);
    } else if (msg.includes('No vote instruction')) {
      log('✗ No vote instruction found. Operator must issue one first.', colors.red);
    } else if (msg.includes('not started') || msg.includes('Voting has not started')) {
      log('✗ Voting window has not started yet.', colors.red);
    } else if (msg.includes('expired') || msg.includes('Voting period')) {
      log('✗ Voting period has expired.', colors.red);
    } else if (msg.includes('Vote has ended') || msg.includes('ended')) {
      log('✗ Vote has been ended by admin.', colors.red);
    } else if (msg.includes('app_logic_reverted')) {
      // Sandbox often swallows assertion messages — check vote state to give a better error
      try {
        const voting = PrivateVotingContract.at(votingAddr, getAccountWallet());
        const finished = await voting.methods.is_vote_finished().simulate({ from: agent });
        if (finished) {
          log('✗ Vote has already ended (ended early by admin or deadline passed).', colors.red);
        } else {
          log(`✗ Transaction reverted. The sandbox did not provide a reason.\n  Raw: ${msg}`, colors.red);
        }
      } catch {
        log(`✗ Transaction reverted. The sandbox did not provide a reason.\n  Raw: ${msg}`, colors.red);
      }
    } else {
      log(`✗ Failed: ${msg}`, colors.red);
    }
  }
}

async function adminEndVoteEarly(): Promise<void> {
  await switchToOperator(); // operator is admin (deployer)
  const admin = getConnectedAddress();

  log('\n--- Admin: End Vote Early ---', colors.blue);

  try {
    const voting = PrivateVotingContract.at(votingAddr, getAccountWallet());

    // Check if already ended
    const finished = await voting.methods.is_vote_finished().simulate({ from: admin });
    if (finished) {
      log('Vote has already ended.', colors.yellow);
      return;
    }

    const confirm = (await question('End voting now? Results will become visible. (y/n): ', 'y')).trim().toLowerCase();
    if (confirm !== 'y') {
      log('Cancelled.', colors.yellow);
      return;
    }

    log('Submitting end_vote tx...', colors.yellow);
    const receipt = await voting.methods
      .end_vote()
      .send({ from: admin, ...(await sponsoredFee()), wait: { timeout: 120 } });

    log(`✓ Vote ended by admin!`, colors.green);
    log(`  txHash: ${receipt.txHash}`, colors.cyan);
    log('  Results are now visible via "View vote results".\n', colors.green);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('Only admin')) {
      log('✗ Only the admin (deployer) can end the vote.', colors.red);
    } else {
      log(`✗ Failed: ${msg}`, colors.red);
    }
  }
}

async function viewAgentStatus(): Promise<void> {
  log('\n--- Agent Status ---', colors.blue);
  log(`Agent: ${short(agentAddr)}`, colors.cyan);

  // 1. Check has_voted (public)
  try {
    const ops = OperationsContract.at(operationsAddr, getAccountWallet());
    const hasVoted = await ops.methods.get_has_voted(agentAddr).simulate({ from: getConnectedAddress() });
    log(`  Has Voted    : ${hasVoted ? '✅ Yes' : '❌ No'}`, hasVoted ? colors.green : colors.yellow);
  } catch {
    log(`  Has Voted    : ❓ Unknown`, colors.yellow);
  }

  // 2. Check registered (private — simulate from operator)
  try {
    await switchToOperator();
    const operator = getConnectedAddress();
    const registry = AgentRegistryContract.at(registryAddr, getAccountWallet());
    await registry.methods
      .prove_association_for(operator, agentAddr)
      .simulate({ from: operator });
    log(`  Registered   : ✅ Yes`, colors.green);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('revoked')) {
      log(`  Registered   : ❌ Unregistered`, colors.red);
    } else if (msg.includes('Not associated')) {
      log(`  Registered   : ❌ No`, colors.yellow);
    } else {
      log(`  Registered   : ❓ Unknown`, colors.yellow);
    }
  }

  // 3. Check has vote instruction (private — simulate from agent)
  try {
    await switchToAgent();
    const agent = getConnectedAddress();
    const ops = OperationsContract.at(operationsAddr, getAccountWallet());
    await ops.methods
      .consume_vote_instruction(agentAddr)
      .simulate({ from: agent });
    log(`  Instructed   : ✅ Yes`, colors.green);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('No vote instruction')) {
      log(`  Instructed   : ❌ No`, colors.yellow);
    } else {
      log(`  Instructed   : ❓ Unknown`, colors.yellow);
    }
  }

  log('', colors.reset);
}


async function viewVoteResults(): Promise<void> {
  const caller = getConnectedAddress();

  log('\n--- Vote Results ---', colors.blue);

  try {
    const voting = PrivateVotingContract.at(votingAddr, getAccountWallet());

    // Check if voting is finished (contract-level check)
    const finished = await voting.methods.is_vote_finished().simulate({ from: caller });
    if (!finished) {
      const { start, deadline, endedEarly } = await getVotingWindowStatus(caller);
      const current = await getCurrentTimestamp();
      const status = formatWindowStatus(current, start, deadline, endedEarly);
      log(`\n🔒 Results are hidden until the voting window closes.`, colors.yellow);
      log(`   ${status}\n`, colors.yellow);
      return;
    }

    log('Fetching vote counts...', colors.yellow);

    const results: { [key: number]: number } = {};
    let totalVotes = 0;

    for (let i = 1; i <= 5; i++) {
      const count = await voting.methods.get_vote(i).simulate({ from: caller });
      results[i] = Number(count);
      totalVotes += results[i];
    }

    log('\nVote Tally:', colors.green);
    for (let i = 1; i <= 5; i++) {
      const votes = results[i];
      const barLength = Math.max(0, 20 - votes);
      const bar = '█'.repeat(votes) + '░'.repeat(barLength);
      log(`  Candidate ${i}: ${bar} ${votes} vote${votes !== 1 ? 's' : ''}`, colors.cyan);
    }
    log(`\nTotal votes: ${totalVotes}\n`, colors.green);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('not closed yet') || msg.includes('has not closed')) {
      log(`\n🔒 Results are hidden until the voting window closes.\n`, colors.yellow);
    } else {
      log(`✗ Failed: ${msg}`, colors.red);
    }
  }
}

async function viewVotingWindow(): Promise<void> {
  const caller = getConnectedAddress();

  log('\n--- Voting Window ---', colors.blue);

  try {
    const { start, deadline, endedEarly } = await getVotingWindowStatus(caller);
    const current = await getCurrentTimestamp();
    const status = formatWindowStatus(current, start, deadline, endedEarly);
    const fmt = (ts: number) => new Date(ts * 1000).toISOString();

    log(`  Start    : ${fmt(start)}`, colors.cyan);
    log(`  Deadline : ${fmt(deadline)}`, colors.cyan);
    log(`  Now      : ${fmt(current)}`, colors.cyan);
    log(`  Duration : ${deadline - start} seconds`, colors.cyan);
    if (endedEarly) log(`  Ended    : ⚡ Early (by admin)`, colors.yellow);
    log(`\n  Status: ${status}\n`, colors.green);
  } catch (e) {
    log(`✗ Failed: ${e instanceof Error ? e.message : String(e)}`, colors.red);
  }
}

// ============================================================================
// Non-interactive E2E sequence
// ============================================================================

async function runE2ESequence(): Promise<void> {
  log('\n========== NON-INTERACTIVE E2E SEQUENCE ==========', colors.bright);
  log('Running full happy-path: register → status → issue → vote → end → results → window → unregister', colors.yellow);
  log('(All prompts auto-answered. Set NON_INTERACTIVE=true to enable this mode.)\n', colors.yellow);

  await operatorRegisterAgent();        // 1. Register agent
  await viewAgentStatus();              // 6. View agent status
  await operatorIssueVoteInstruction(); // 3. Issue vote instruction (auto: candidate 1)
  await agentExecuteVote();             // 4. Execute vote (auto-wait if window not open)
  await adminEndVoteEarly();            // 5. End vote early (auto-confirm)
  await viewVoteResults();              // 7. View vote results
  await viewVotingWindow();             // 8. View voting window
  await operatorUnregisterAgent();      // 2. Unregister agent

  log('\n✓ E2E sequence complete.\n', colors.green);
}

// ============================================================================
// Single menu
// ============================================================================

async function mainMenu(): Promise<boolean> {
  log('\n========== OPERATIONS MENU ==========', colors.bright);
  log(`Operator : ${operatorAddr}`, colors.cyan);
  log(`Agent    : ${agentAddr}\n`, colors.cyan);

  log('--- Registration (private) ---', colors.blue);
  log(' 1. Register agent', colors.cyan);
  log(' 2. Unregister agent', colors.cyan);

  log('\n--- Voting (operator decides → agent executes) ---', colors.blue);
  log(' 3. Issue vote instruction to agent', colors.cyan);
  log(' 4. Agent: execute vote', colors.cyan);

  log('\n--- Admin ---', colors.blue);
  log(' 5. End vote early (reveal results)', colors.cyan);

  log('\n--- View ---', colors.blue);
  log(' 6. View agent status', colors.cyan);
  log(' 7. View vote results', colors.cyan);
  log(' 8. View voting window', colors.cyan);

  log('\n 0. Exit\n', colors.cyan);

  const choice = (await question('Select option: ')).trim();

  switch (choice) {
    case '1': await operatorRegisterAgent(); break;
    case '2': await operatorUnregisterAgent(); break;
    case '3': await operatorIssueVoteInstruction(); break;
    case '4': await agentExecuteVote(); break;
    case '5': await adminEndVoteEarly(); break;
    case '6': await viewAgentStatus(); break;
    case '7': await viewVoteResults(); break;
    case '8': await viewVotingWindow(); break;
    case '0': return false;
    default: log('✗ Invalid option', colors.red);
  }
  return true;
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  try {
    await initialize();

    if (NON_INTERACTIVE) {
      await runE2ESequence();
    } else {
      let running = true;
      while (running) {
        running = await mainMenu();
      }
    }

    log('\nGoodbye!\n', colors.green);
    rl.close();
    process.exit(0);
  } catch (e) {
    log(`✗ Fatal: ${e instanceof Error ? e.message : String(e)}`, colors.red);
    rl.close();
    process.exit(1);
  }
}

process.on('SIGINT', () => {
  log('\n\nGoodbye!\n', colors.green);
  rl.close();
  process.exit(0);
});

main();