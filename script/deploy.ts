/**
 * LIQFlashYul Mainnet Deployment Script
 *
 * Features:
 *   - Timestamped logging with bigint serialization
 *   - Dry-run mode (--dry-run)
 *   - Secure mnemonic input (no echo)
 *   - Mainnet confirmation prompt
 *   - JSON output with deployment info
 *   - Etherscan verification guidance
 *
 * Usage:
 *   npx tsx script/deploy.ts --dry-run                    # Simulate without credentials
 *   npx tsx script/deploy.ts --mnemonic                   # Deploy with mnemonic input
 *   PRIVATE_KEY=0x... npx tsx script/deploy.ts            # Deploy with private key
 *   npx tsx script/deploy.ts --tenderly                   # Deploy to Tenderly fork
 */

import {
  createWalletClient,
  createPublicClient,
  http,
  formatEther,
  keccak256,
  Hex,
} from "viem";
import { privateKeyToAccount, mnemonicToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";
import readline from "readline";
import { readMnemonic } from "./utils.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ============================================================================
// Configuration
// ============================================================================

const VERSION = "1.0.0";
const CONTRACT_NAME = "LIQFlashYul";

// Public RPCs (no API keys needed)
const PUBLIC_RPCS = [
  "https://eth.drpc.org",
  "https://ethereum-rpc.publicnode.com",
  "https://rpc.mevblocker.io",
];

const RPC_URL = process.env.RPC_URL || PUBLIC_RPCS[0];

const isDryRun = process.argv.includes("--dry-run");
const useMnemonic = process.argv.includes("--mnemonic");
const isTenderly = process.argv.includes("--tenderly");

const network = isTenderly ? "tenderly" : "mainnet";

// ============================================================================
// Timestamped Logging (bigint-safe)
// ============================================================================

const logFile = path.join(
  __dirname,
  `../deploy-${network}-${Date.now()}.log`
);
const logStream = fs.createWriteStream(logFile, { flags: "a" });
const originalLog = console.log;
const originalError = console.error;

const safeStringify = (obj: any) => {
  return JSON.stringify(
    obj,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2
  );
};

console.log = (...args: any[]) => {
  const msg = args
    .map((a) => (typeof a === "object" ? safeStringify(a) : String(a)))
    .join(" ");
  logStream.write(`[${new Date().toISOString()}] ${msg}\n`);
  originalLog.apply(console, args);
};

console.error = (...args: any[]) => {
  const msg = args
    .map((a) => (typeof a === "object" ? safeStringify(a) : String(a)))
    .join(" ");
  logStream.write(`[${new Date().toISOString()}] ERROR: ${msg}\n`);
  originalError.apply(console, args);
};

// ============================================================================
// Confirmation Prompt
// ============================================================================

async function confirm(message: string): Promise<boolean> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(`${message} (y/N): `, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === "y");
    });
  });
}

// ============================================================================
// Artifact Loading
// ============================================================================

function readArtifact(contractName: string): { abi: any; bytecode: Hex } {
  const artifactPath = path.join(
    __dirname,
    `../out/${contractName}.sol/${contractName}.json`
  );

  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  let bytecode = artifact.bytecode?.object || artifact.bytecode;

  if (!bytecode.startsWith("0x")) {
    bytecode = "0x" + bytecode;
  }

  return { abi: artifact.abi, bytecode: bytecode as Hex };
}

// ============================================================================
// Main Deployment
// ============================================================================

async function main() {
  console.log("=".repeat(60));
  console.log(`LIQFlashYul Deployment v${VERSION}`);
  console.log("=".repeat(60));
  console.log("");
  console.log(`Log file: ${logFile}`);
  console.log("");

  // Rebuild artifacts
  if (!isDryRun) {
    console.log("Rebuilding artifacts...");
    execSync("forge build --force", {
      stdio: "inherit",
      cwd: path.join(__dirname, ".."),
    });
    console.log("[OK] Artifacts rebuilt");
    console.log("");
  }

  // Load artifact
  const artifact = readArtifact(CONTRACT_NAME);
  const bytecodeHash = keccak256(artifact.bytecode);
  console.log(`Bytecode hash: ${bytecodeHash}`);
  console.log("");

  // Setup account
  let account: ReturnType<typeof privateKeyToAccount>;

  if (isDryRun) {
    const dummyKey = `0x${"b".repeat(64)}` as Hex;
    account = privateKeyToAccount(dummyKey);
    console.log(`[DRY RUN] Using dummy account: ${account.address}`);
  } else if (useMnemonic) {
    const mnemonic = await readMnemonic();
    const mnemonicAccount = mnemonicToAccount(mnemonic.trim(), {
      addressIndex: 0,
    });
    const hdKey = mnemonicAccount.getHdKey();
    if (!hdKey.privateKey) {
      console.error("[X] Failed to derive private key from mnemonic");
      process.exit(1);
    }
    const privateKey = `0x${Buffer.from(hdKey.privateKey).toString(
      "hex"
    )}` as Hex;
    account = privateKeyToAccount(privateKey);
    console.log(`Account from mnemonic: ${account.address}`);
  } else if (process.env.PRIVATE_KEY) {
    const pk = process.env.PRIVATE_KEY;
    if (!/^0x[a-fA-F0-9]{64}$/.test(pk)) {
      console.error("[X] Invalid PRIVATE_KEY format (expected 0x + 64 hex chars)");
      process.exit(1);
    }
    account = privateKeyToAccount(pk as Hex);
    console.log(`Account from PRIVATE_KEY: ${account.address}`);
  } else {
    console.error("[X] No credentials provided");
    console.error("    Use --mnemonic or set PRIVATE_KEY env var");
    process.exit(1);
  }

  console.log("");
  console.log(`Network:  ${network}`);
  console.log(`RPC:      ${RPC_URL}`);
  console.log(`Deployer: ${account.address}`);
  console.log(`Dry Run:  ${isDryRun ? "YES" : "NO"}`);
  console.log("");

  // Create clients
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(RPC_URL),
  });

  // Check balance (skip in dry-run)
  if (!isDryRun) {
    const balance = await publicClient.getBalance({ address: account.address });
    console.log(`ETH Balance: ${formatEther(balance)} ETH`);

    if (balance < BigInt(0.01e18)) {
      console.error("[X] Insufficient ETH for deployment (need >= 0.01 ETH)");
      process.exit(1);
    }
    console.log("");
  }

  // Mainnet confirmation
  if (!isTenderly && !isDryRun) {
    console.log("=".repeat(60));
    console.log("MAINNET DEPLOYMENT CONFIRMATION");
    console.log("=".repeat(60));
    console.log("");
    console.log(`Deployer: ${account.address}`);
    console.log(`Contract: ${CONTRACT_NAME}`);
    console.log(`Owner:    ${account.address} (deployer)`);
    console.log("");
    console.log("[!] Contract will be owned by deployer");
    console.log("    Use transferOwnership() to transfer to multisig");
    console.log("");

    const confirmed = await confirm(
      "Deploy to MAINNET? This will cost real ETH!"
    );
    if (!confirmed) {
      console.log("Deployment cancelled.");
      process.exit(0);
    }
    console.log("");
  }

  // Deploy
  console.log("Deploying LIQFlashYul...");

  let contractAddress: Hex;
  let deployTxHash: Hex | undefined;
  let gasUsed: bigint | undefined;

  if (isDryRun) {
    contractAddress = "0x" + "0".repeat(40) as Hex;
    console.log(`[DRY RUN] Would deploy to: ${contractAddress}`);
  } else {
    const hash = await walletClient.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      gas: 3_000_000n,
    });

    console.log(`Tx hash: ${hash}`);
    deployTxHash = hash;

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    contractAddress = receipt.contractAddress!;
    gasUsed = receipt.gasUsed;

    console.log(`[OK] Deployed: ${contractAddress}`);
    console.log(`Gas used: ${gasUsed.toLocaleString()}`);
  }

  console.log("");

  // Verify deployment
  if (!isDryRun) {
    const owner = await publicClient.readContract({
      address: contractAddress,
      abi: artifact.abi,
      functionName: "owner",
    });

    const poolBalance = await publicClient.readContract({
      address: contractAddress,
      abi: artifact.abi,
      functionName: "poolBalance",
    });

    console.log(`Owner:        ${owner}`);
    console.log(`Pool Balance: ${poolBalance}`);
    console.log("");
  }

  // Save deployment JSON
  const output = {
    version: VERSION,
    deployedAt: new Date().toISOString(),
    network,
    chainId: 1,
    dryRun: isDryRun,
    rpcUrl: RPC_URL,
    deployer: account.address,
    deployTxHash,
    contract: {
      name: CONTRACT_NAME,
      address: contractAddress,
      bytecodeHash,
    },
    gasUsed: gasUsed?.toString(),
    verification: {
      command: `forge verify-contract ${contractAddress} src/LIQFlashYul.sol:LIQFlashYul --chain mainnet`,
    },
  };

  const jsonOutputFile = path.join(
    __dirname,
    `../deployment-${network}.json`
  );
  fs.writeFileSync(jsonOutputFile, JSON.stringify(output, null, 2));
  console.log(`Deployment saved to: ${jsonOutputFile}`);

  // Post-deployment guidance
  console.log("");
  console.log("=".repeat(60));
  console.log("POST-DEPLOYMENT STEPS");
  console.log("=".repeat(60));
  console.log("");
  console.log("1. Verify on Etherscan:");
  console.log(
    `   forge verify-contract ${contractAddress} src/LIQFlashYul.sol:LIQFlashYul --chain mainnet`
  );
  console.log("");
  console.log("2. Fund the contract via deposit():");
  console.log("   - Approve USDC: usdc.approve(liq, amount)");
  console.log("   - Deposit:      liq.deposit(amount)");
  console.log("");
  console.log("3. Update docs/index.html:");
  console.log(`   const LIQ_ADDRESS = '${contractAddress}';`);
  console.log("");
  console.log("4. Optional: Transfer ownership to multisig");
  console.log("   liq.transferOwnership(SAFE_ADDRESS)");
  console.log("");
  console.log("=".repeat(60));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
}

main()
  .catch((err) => {
    console.error("[X] Deployment failed:", err);
    process.exit(1);
  })
  .finally(() => {
    logStream.end();
  });
