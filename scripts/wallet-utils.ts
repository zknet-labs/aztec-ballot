import { AztecAddress } from '@aztec/aztec.js/addresses';
import { getContractInstanceFromInstantiationParams } from '@aztec/aztec.js/contracts';
import { SponsoredFeePaymentMethod } from '@aztec/aztec.js/fee';
import { Fr } from '@aztec/aztec.js/fields';
import { GrumpkinScalar } from '@aztec/foundation/curves/grumpkin';
import { createAztecNodeClient } from '@aztec/aztec.js/node';
import type { DeployAccountOptions, Wallet } from '@aztec/aztec.js/wallet';
import { SPONSORED_FPC_SALT } from '@aztec/constants';
import { SponsoredFPCContractArtifact } from '@aztec/noir-contracts.js/SponsoredFPC';
import { EmbeddedWallet } from '@aztec/wallets/embedded';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

// ============================================================================
// Test Account Helper
// ============================================================================

export async function getTestAccountsData() {
  return Promise.resolve([
    { index: 0, label: 'Test Account 0' },
    { index: 1, label: 'Test Account 1' },
    { index: 2, label: 'Test Account 2' },
  ]);
}

// ============================================================================
// File Storage
// ============================================================================

export interface StoredAccountData {
  address: string;
  signingKey?: string;
  secretKey?: string;
  salt?: string;
  accountType?: string;
}

export class FileStorage {
  private storageDir: string;
  private accountFile: string;

  constructor(dataDir?: string) {
    this.storageDir = dataDir || join(homedir(), '.aztec', 'cli-wallet');
    this.accountFile = join(this.storageDir, 'account.json');

    if (!existsSync(this.storageDir)) {
      mkdirSync(this.storageDir, { recursive: true });
    }
  }

  saveAccount(data: StoredAccountData): void {
    writeFileSync(this.accountFile, JSON.stringify(data, null, 2), 'utf-8');
  }

  loadAccount(): StoredAccountData | null {
    if (!existsSync(this.accountFile)) {
      return null;
    }
    const data = readFileSync(this.accountFile, 'utf-8');
    return JSON.parse(data) as StoredAccountData;
  }

  clearAccount(): void {
    if (existsSync(this.accountFile)) {
      writeFileSync(this.accountFile, '', 'utf-8');
    }
  }
}

// ============================================================================
// CLI Wallet Wrapper
// ============================================================================

export class CLIWallet {
  private wallet: EmbeddedWallet | null = null;
  private storage: FileStorage;
  private connectedAddress: AztecAddress | null = null;
  private accounts: Map<string, any> = new Map();

  constructor(wallet: EmbeddedWallet, dataDir?: string) {
    this.wallet = wallet;
    this.storage = new FileStorage(dataDir);
  }

  private async registerAccount(accountManager: any): Promise<void> {
    if (!this.wallet) throw new Error('Wallet not initialized');
    const completeAddress = await accountManager.getCompleteAddress();
    const pxe = (this.wallet as any).pxe || this.wallet;
    if (pxe.registerRecipient) {
      await pxe.registerRecipient(completeAddress);
    }
  }

  static async initialize(nodeUrl: string, dataDir?: string) {
    const aztecNode = createAztecNodeClient(nodeUrl);

    const wallet = await EmbeddedWallet.create(aztecNode, {
      ephemeral: true,
      pxeConfig: { proverEnabled: process.env.PROVER_ENABLED === 'true' },
    });

    // Register sponsored FPC
    const sponsoredInstance = await getContractInstanceFromInstantiationParams(
      SponsoredFPCContractArtifact,
      { salt: new Fr(SPONSORED_FPC_SALT) }
    );
    await wallet.registerContract(
      sponsoredInstance,
      SponsoredFPCContractArtifact
    );

    return new CLIWallet(wallet, dataDir);
  }

  async createAccountAndConnect() {
    if (!this.wallet) throw new Error('Wallet not initialized');

    const salt = Fr.random();
    const secretKey = Fr.random();
    const signingKey = GrumpkinScalar.random();

    const accountManager = await this.wallet.createSchnorrAccount(
      secretKey,
      salt,
      signingKey
    );

    // Register account BEFORE deployment
    await this.registerAccount(accountManager);

    // Deploy the account
    const deployMethod = await accountManager.getDeployMethod();
    const sponsoredInstance = await getContractInstanceFromInstantiationParams(
      SponsoredFPCContractArtifact,
      { salt: new Fr(SPONSORED_FPC_SALT) }
    );

    const deployOpts: DeployAccountOptions<{ timeout: number }> = {
      from: AztecAddress.ZERO,
      fee: {
        paymentMethod: new SponsoredFeePaymentMethod(sponsoredInstance.address),
      },
      skipClassPublication: true,
      skipInstancePublication: true,
      wait: { timeout: 120 },
    };

    await deployMethod.send(deployOpts);

    // IMPORTANT: Register the complete address with PXE after deployment
    const completeAddress = await accountManager.getCompleteAddress();
    const pxe = (this.wallet as any).pxe || this.wallet;
    if (pxe.registerRecipient) {
      await pxe.registerRecipient(completeAddress);
    }

    // Add to accounts map
    const account = await accountManager.getAccount();
    this.accounts.set(accountManager.address.toString(), account);

    // Save to file
    this.storage.saveAccount({
      address: accountManager.address.toString(),
      signingKey: signingKey.toString(),
      secretKey: secretKey.toString(),
      salt: salt.toString(),
      accountType: 'schnorr',
    });

    this.connectedAddress = accountManager.address;
    return accountManager.address;
  }

  async connectTestAccount(index: number) {
    if (!this.wallet) throw new Error('Wallet not initialized');

    const accounts = await this.wallet.getAccounts();
    const testAccount = accounts[index];
    if (!testAccount) throw new Error(`Test account ${index} not found`);

    this.connectedAddress = testAccount.item;
    this.accounts.set(testAccount.item.toString(), testAccount.item);
    this.storage.saveAccount({ address: testAccount.item.toString() });
    return testAccount.item;
  }

  async connectExistingAccount() {
    const stored = this.storage.loadAccount();
    if (!stored) return null;

    const address = AztecAddress.fromString(stored.address);

    // If we have stored credentials, recover the account
    if (stored.signingKey && stored.secretKey && stored.salt) {
      try {
        const secretKey = Fr.fromString(stored.secretKey);
        const salt = Fr.fromString(stored.salt);
        const signingKey = GrumpkinScalar.fromString(stored.signingKey);

        if (!this.wallet) throw new Error('Wallet not initialized');
        const accountManager = await this.wallet.createSchnorrAccount(
          secretKey,
          salt,
          signingKey
        );
        const account = await accountManager.getAccount();
        this.accounts.set(address.toString(), account);

        // Register the complete address
        const completeAddress = await accountManager.getCompleteAddress();
        const pxe = (this.wallet as any).pxe || this.wallet;
        if (pxe.registerRecipient) {
          await pxe.registerRecipient(completeAddress);
        }
      } catch (error) {
        console.warn('Could not recover account from credentials:', error);
      }
    }

    // Check if account exists in wallet
    const accounts = await this.wallet.getAccounts();
    const exists = accounts.find((acc) => acc.item.equals(address));

    if (exists) {
      this.connectedAddress = address;
      this.accounts.set(address.toString(), address);
      return this.connectedAddress;
    }

    return null;
  }

  getConnectedAccount(): AztecAddress | null {
    return this.connectedAddress;
  }

  getConnectedAccountObject(): any | null {
    if (!this.connectedAddress) return null;
    return this.accounts.get(this.connectedAddress.toString()) || null;
  }

  getWallet(): Wallet {
    if (!this.wallet) throw new Error('Wallet not initialized');
    return this.wallet;
  }

  clearStoredAccount() {
    this.storage.clearAccount();
    this.connectedAddress = null;
  }

  async listWalletAccounts(): Promise<AztecAddress[]> {
    if (!this.wallet) throw new Error('Wallet not initialized');
    const accounts = await this.wallet.getAccounts();
    return accounts.map((a) => a.item);
  }

  async connectWalletAccountByIndex(index: number): Promise<AztecAddress> {
    if (!this.wallet) throw new Error('Wallet not initialized');

    const accounts = await this.wallet.getAccounts();
    const acc = accounts[index];
    if (!acc) throw new Error(`Account index ${index} not found`);

    this.connectedAddress = acc.item;
    this.accounts.set(acc.item.toString(), acc.item);

    // Keep the old behavior for "last connected"
    this.storage.saveAccount({ address: acc.item.toString() });

    return acc.item;
  }
}
