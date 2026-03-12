import { AztecAddress } from '@aztec/aztec.js/addresses';
import {
  DeployMethod,
  getContractInstanceFromInstantiationParams,
} from '@aztec/aztec.js/contracts';
import { SponsoredFeePaymentMethod } from '@aztec/aztec.js/fee';
import { Fr } from '@aztec/aztec.js/fields';
import { GrumpkinScalar } from '@aztec/foundation/curves/grumpkin';
import { PublicKeys } from '@aztec/aztec.js/keys';
import { createAztecNodeClient } from '@aztec/aztec.js/node';
import type { DeployAccountOptions, Wallet } from '@aztec/aztec.js/wallet';
import { type AztecNode } from '@aztec/aztec.js/node';
import { SPONSORED_FPC_SALT } from '@aztec/constants';
import { SponsoredFPCContractArtifact } from '@aztec/noir-contracts.js/SponsoredFPC';
import { getDefaultInitializer } from '@aztec/stdlib/abi';
import { EmbeddedWallet } from '@aztec/wallets/embedded';
import { createHash } from 'crypto';
import fs from 'fs';
import path from 'path';
// @ts-ignore
import { PrivateVotingContract } from '../app/artifacts/PrivateVoting.ts';
// @ts-ignore
import { AgentRegistryContract } from '../app/artifacts/AgentRegistry.ts';
// @ts-ignore
import { OperationsContract } from '../app/artifacts/Operations.ts';

// ============================================================================
// Configuration (single source of truth)
// ============================================================================

const AZTEC_NODE_URL = process.env.AZTEC_NODE_URL || 'http://localhost:8080';
const PROVER_ENABLED = process.env.PROVER_ENABLED === 'true';
const WRITE_ENV_FILE = process.env.WRITE_ENV_FILE === 'false' ? false : true;

export const VOTE_START_DELAY_SECONDS = 0;       // open immediately
export const VOTE_DURATION_SECONDS = 60 * 120;   // 2 hour window

const REPO_ROOT = path.resolve(import.meta.dirname, '..');
export const ENV_FILE_PATH = path.join(REPO_ROOT, '.env');

// ============================================================================
// Deployment result type
// ============================================================================

export interface DeploymentInfo {
  registryAddress: string;
  operationsAddress: string;
  votingAddress: string;
  deployerAddress: string;
  registrySalt: string;
  operationsSalt: string;
  votingSalt: string;
  artifactsHash: string;
}

// ============================================================================
// Artifact hashing — detect when contracts have been recompiled
// ============================================================================

const ARTIFACT_DIR = path.join(REPO_ROOT, 'app', 'artifacts');
const ARTIFACT_FILES = [
  'registry-AgentRegistry.json',
  'operations-Operations.json',
  'private_voting-PrivateVoting.json',
];

export function computeArtifactsHash(): string {
  const hash = createHash('sha256');
  for (const file of ARTIFACT_FILES) {
    const filePath = path.join(ARTIFACT_DIR, file);
    if (fs.existsSync(filePath)) {
      hash.update(fs.readFileSync(filePath));
    }
  }
  return hash.digest('hex').slice(0, 16);
}

// ============================================================================
// Shared helpers
// ============================================================================

async function getSponsoredPFCContract() {
  return await getContractInstanceFromInstantiationParams(
    SponsoredFPCContractArtifact,
    { salt: new Fr(SPONSORED_FPC_SALT) },
  );
}

// ============================================================================
// Core deploy function — used by both standalone and CLI demo
// ============================================================================

export async function deployContracts(
  wallet: Wallet,
  deployer: AztecAddress,
  options?: {
    voteStartDelay?: number;
    voteDuration?: number;
  },
): Promise<DeploymentInfo> {
  const sponsoredPFCContract = await getSponsoredPFCContract();
  const feeOpts = {
    paymentMethod: new SponsoredFeePaymentMethod(sponsoredPFCContract.address),
  };

  const registrySalt = Fr.random();
  const operationsSalt = Fr.random();
  const votingSalt = Fr.random();

  const startDelay = options?.voteStartDelay ?? VOTE_START_DELAY_SECONDS;
  const duration = options?.voteDuration ?? VOTE_DURATION_SECONDS;

  // Registry
  console.log('Deploying AgentRegistry...');
  const registry = await AgentRegistryContract.deploy(wallet)
    .send({ fee: feeOpts, from: deployer, contractAddressSalt: registrySalt, wait: { timeout: 120 } });
  console.log(`AgentRegistry deployed at ${registry.address}`);

  // Operations
  console.log('Deploying OperationsContract...');
  const operations = await OperationsContract.deploy(wallet, registry.address)
    .send({ fee: feeOpts, from: deployer, contractAddressSalt: operationsSalt, wait: { timeout: 120 } });
  console.log(`Operations deployed at ${operations.address}`);

  // Voting
  console.log('Deploying PrivateVoting...');
  console.log(`  Vote start delay: ${startDelay}s`);
  console.log(`  Vote duration:    ${duration / 60} min`);

  const voting = await PrivateVotingContract.deploy(
    wallet, deployer, operations.address, startDelay, duration,
  )
    .send({ fee: feeOpts, from: deployer, contractAddressSalt: votingSalt, wait: { timeout: 120 } });
  console.log(`PrivateVoting deployed at ${voting.address}`);

  return {
    registryAddress: registry.address.toString(),
    operationsAddress: operations.address.toString(),
    votingAddress: voting.address.toString(),
    deployerAddress: deployer.toString(),
    registrySalt: registrySalt.toString(),
    operationsSalt: operationsSalt.toString(),
    votingSalt: votingSalt.toString(),
    artifactsHash: computeArtifactsHash(),
  };
}

// ============================================================================
// .env persistence — used by both standalone and CLI demo
// ============================================================================

export function writeEnvFile(
  deploymentInfo: DeploymentInfo,
  envFilePath: string = ENV_FILE_PATH,
  nodeUrl: string = AZTEC_NODE_URL,
): void {
  const envConfig = [
    `REGISTRY_CONTRACT_ADDRESS=${deploymentInfo.registryAddress}`,
    `OPERATIONS_CONTRACT_ADDRESS=${deploymentInfo.operationsAddress}`,
    `VOTING_CONTRACT_ADDRESS=${deploymentInfo.votingAddress}`,
    `DEPLOYER_ADDRESS=${deploymentInfo.deployerAddress}`,
    `AZTEC_NODE_URL=${nodeUrl}`,
    `REGISTRY_DEPLOYMENT_SALT=${deploymentInfo.registrySalt}`,
    `OPERATIONS_DEPLOYMENT_SALT=${deploymentInfo.operationsSalt}`,
    `VOTING_DEPLOYMENT_SALT=${deploymentInfo.votingSalt}`,
    `ARTIFACTS_HASH=${deploymentInfo.artifactsHash}`,
  ].join('\n');

  fs.writeFileSync(envFilePath, envConfig);
  console.log(`Contracts deployed successfully. Config saved to ${envFilePath}`);
}

// ============================================================================
// Standalone execution (only runs when this file is executed directly)
// ============================================================================

async function setupWallet(aztecNode: AztecNode): Promise<EmbeddedWallet> {
  return await EmbeddedWallet.create(aztecNode, {
    ephemeral: true,
    pxeConfig: { proverEnabled: PROVER_ENABLED },
  });
}

async function createAccount(wallet: EmbeddedWallet) {
  const salt = Fr.random();
  const secretKey = Fr.random();
  const signingKey = GrumpkinScalar.random();
  const accountManager = await wallet.createSchnorrAccount(
    secretKey,
    salt,
    signingKey,
  );

  const deployMethod = await accountManager.getDeployMethod();
  const sponsoredPFCContract = await getSponsoredPFCContract();
  const deployOpts: DeployAccountOptions<{ timeout: number }> = {
    from: AztecAddress.ZERO,
    fee: {
      paymentMethod: new SponsoredFeePaymentMethod(sponsoredPFCContract.address),
    },
    skipClassPublication: true,
    skipInstancePublication: true,
    wait: { timeout: 120 },
  };
  await deployMethod.send(deployOpts);

  return accountManager.address;
}

async function main() {
  const aztecNode = createAztecNodeClient(AZTEC_NODE_URL);
  const wallet = await setupWallet(aztecNode);

  await wallet.registerContract(
    await getSponsoredPFCContract(),
    SponsoredFPCContractArtifact,
  );

  const accountAddress = await createAccount(wallet);
  const deploymentInfo = await deployContracts(wallet, accountAddress);

  if (WRITE_ENV_FILE) {
    writeEnvFile(deploymentInfo);
  }
}

// Only run main() when executed directly, not when imported
const isDirectExecution = process.argv[1]?.replace(/\.ts$/, '').endsWith('deploy');

if (isDirectExecution) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
