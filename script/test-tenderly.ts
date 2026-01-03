/**
 * LIQFlashYul Full E2E Test on Tenderly Fork
 *
 * Tests:
 *   1. Deploy contract
 *   2. Mint USDC (impersonate whale)
 *   3. Deposit USDC
 *   4. Execute flash loan
 *   5. Withdraw funds
 *   6. Top-up (deposit more)
 *   7. Sync excess USDC
 *
 * Usage:
 *   source ~/.zsh_secrets
 *   npx tsx script/test-tenderly.ts
 */

import {
  createWalletClient,
  createPublicClient,
  http,
  parseAbi,
  formatUnits,
  Hex,
  Address,
  encodeFunctionData,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ============================================================================
// Configuration
// ============================================================================

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" as Address;
const USDC_WHALE = "0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341" as Address;

// Test amounts
const DEPOSIT_AMOUNT = 100_000n * 10n ** 6n; // 100k USDC
const FLASH_AMOUNT = 50_000n * 10n ** 6n; // 50k USDC
const WITHDRAW_AMOUNT = 25_000n * 10n ** 6n; // 25k USDC
const TOPUP_AMOUNT = 10_000n * 10n ** 6n; // 10k USDC

// ABIs
const USDC_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address, uint256) returns (bool)",
  "function approve(address, uint256) returns (bool)",
  "function allowance(address, address) view returns (uint256)",
]);

const LIQ_ABI = parseAbi([
  "function owner() view returns (address)",
  "function poolBalance() view returns (uint256)",
  "function flashLoan(address receiver, address token, uint256 amount, bytes data) returns (bool)",
  "function maxFlashLoan(address token) view returns (uint256)",
  "function flashFee(address token, uint256 amount) view returns (uint256)",
  "function deposit(uint256 amount)",
  "function withdraw(uint256 amount)",
  "function sync()",
  "function transferOwnership(address newOwner)",
]);

// Mock borrower bytecode (repays immediately)
const MOCK_BORROWER_BYTECODE = `0x608060405234801561001057600080fd5b50610400806100206000396000f3fe608060405234801561001057600080fd5b506004361061002b5760003560e01c806323e30c8b14610030575b600080fd5b61004a6004803603810190610045919061024e565b610060565b60405161005791906102f4565b60405180910390f35b60008373ffffffffffffffffffffffffffffffffffffffff1663a9059cbb33866040518363ffffffff1660e01b815260040161009d92919061031e565b6020604051808303816000875af11580156100bc573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100e0919061037f565b507f439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd960001b9050949350505050565b600080fd5b600080fd5b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b600061014482610119565b9050919050565b61015481610139565b811461015f57600080fd5b50565b6000813590506101718161014b565b92915050565b6000819050919050565b61018a81610177565b811461019557600080fd5b50565b6000813590506101a781610181565b92915050565b600080fd5b600080fd5b600080fd5b60008083601f8401126101d2576101d16101ad565b5b8235905067ffffffffffffffff8111156101ef576101ee6101b2565b5b60208301915083600182028301111561020b5761020a6101b7565b5b9250929050565b60008060008060006080868803121561022e5761022d61010f565b5b600061023c88828901610162565b955050602061024d88828901610162565b945050604061025e88828901610198565b935050606086013567ffffffffffffffff81111561027f5761027e610114565b5b61028b888289016101bc565b92509250509295509295909350565b6000819050919050565b6000819050919050565b60006102c96102c46102bf8461029a565b6102a4565b61029a565b9050919050565b6102d9816102ae565b82525050565b6102e881610177565b82525050565b600060208201905061030360008301846102d0565b92915050565b61031281610139565b82525050565b600060408201905061032d6000830185610309565b61033a60208301846102df565b9392505050565b60008115159050919050565b61035681610341565b811461036157600080fd5b50565b6000815190506103738161034d565b92915050565b60006020828403121561038f5761038e61010f565b5b600061039d84828501610364565b9150509291505056fea2646970667358221220` as Hex;

// ============================================================================
// Tenderly Fork Creation
// ============================================================================

async function createTenderlyFork(): Promise<string> {
  const accessKey = process.env.TENDERLY_ACCESS_KEY;
  const account = process.env.TENDERLY_ACCOUNT || "pse-team";
  const project = process.env.TENDERLY_PROJECT || "yolo";

  if (!accessKey) {
    throw new Error("TENDERLY_ACCESS_KEY not set. Source ~/.zsh_secrets first.");
  }

  console.log("Creating Tenderly fork...");

  const response = await fetch(
    `https://api.tenderly.co/api/v1/account/${account}/project/${project}/vnets`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Access-Key": accessKey,
      },
      body: JSON.stringify({
        slug: `liq-test-${Date.now()}`,
        display_name: `LIQ E2E Test ${new Date().toISOString()}`,
        fork_config: {
          network_id: 1,
        },
        virtual_network_config: {
          chain_config: {
            chain_id: 1,
          },
        },
        sync_state_config: {
          enabled: false,
        },
        explorer_page_config: {
          enabled: true,
          verification_visibility: "src",
        },
      }),
    }
  );

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Failed to create Tenderly fork: ${response.status} ${text}`);
  }

  const data = await response.json();
  const rpcUrl = data.rpcs?.[0]?.url;

  if (!rpcUrl) {
    console.log("Response:", JSON.stringify(data, null, 2));
    throw new Error("No RPC URL in Tenderly response");
  }

  console.log(`[OK] Fork created: ${rpcUrl}`);
  return rpcUrl;
}

// ============================================================================
// Artifact Loading
// ============================================================================

function readArtifact(contractName: string, solFileName?: string): { abi: any; bytecode: Hex } {
  const fileName = solFileName || `${contractName}.sol`;
  const artifactPath = path.join(
    __dirname,
    `../out/${fileName}/${contractName}.json`
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
// Test Helpers
// ============================================================================

function formatUSDC(amount: bigint): string {
  return formatUnits(amount, 6);
}

function passed(msg: string) {
  console.log(`[PASS] ${msg}`);
}

function failed(msg: string) {
  console.log(`[FAIL] ${msg}`);
  process.exit(1);
}

// ============================================================================
// Main Test
// ============================================================================

async function main() {
  console.log("============================================================");
  console.log("LIQFlashYul E2E Test on Tenderly");
  console.log("============================================================");
  console.log("");

  // Build artifacts
  console.log("Building contracts...");
  execSync("forge build", { stdio: "inherit", cwd: path.join(__dirname, "..") });
  console.log("");

  // Create Tenderly fork
  const rpcUrl = await createTenderlyFork();
  console.log("");

  // Setup test account
  const testKey = `0x${"ac".repeat(32)}` as Hex;
  const testAccount = privateKeyToAccount(testKey);
  console.log(`Test account: ${testAccount.address}`);

  // Create clients
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account: testAccount,
    chain: mainnet,
    transport: http(rpcUrl),
  });

  // Fund test account with ETH using Tenderly RPC
  console.log("Funding test account with ETH...");
  await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "tenderly_setBalance",
      params: [testAccount.address, "0x8AC7230489E80000"], // 10 ETH
      id: 1,
    }),
  });
  passed("Test account funded with 10 ETH");

  // ========== TEST 1: Deploy Contract ==========
  console.log("");
  console.log("--- TEST 1: Deploy LIQFlashYul ---");

  const artifact = readArtifact("LIQFlashYul");

  const deployHash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode,
  });

  const deployReceipt = await publicClient.waitForTransactionReceipt({
    hash: deployHash,
  });

  const liqAddress = deployReceipt.contractAddress!;
  console.log(`Contract deployed: ${liqAddress}`);
  console.log(`Gas used: ${deployReceipt.gasUsed.toLocaleString()}`);

  const owner = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "owner",
  });

  if (owner !== testAccount.address) {
    failed(`Owner mismatch: ${owner} != ${testAccount.address}`);
  }
  passed("Contract deployed, owner verified");

  // ========== TEST 2: Mint USDC (impersonate whale) ==========
  console.log("");
  console.log("--- TEST 2: Get USDC from whale ---");

  const whaleBalance = await publicClient.readContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: [USDC_WHALE],
  });
  console.log(`Whale USDC balance: ${formatUSDC(whaleBalance)}`);

  // Fund whale with ETH and transfer USDC via Tenderly RPC
  await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "tenderly_setBalance",
      params: [USDC_WHALE, "0xDE0B6B3A7640000"], // 1 ETH
      id: 2,
    }),
  });

  // Use tenderly_simulateTransaction to transfer USDC from whale
  const transferCalldata = encodeFunctionData({
    abi: USDC_ABI,
    functionName: "transfer",
    args: [testAccount.address, DEPOSIT_AMOUNT + TOPUP_AMOUNT],
  });

  // Execute as whale using eth_sendTransaction with from override
  const transferResult = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_sendTransaction",
      params: [{
        from: USDC_WHALE,
        to: USDC,
        data: transferCalldata,
        gas: "0x30000",
      }],
      id: 3,
    }),
  });
  const transferJson = await transferResult.json() as { result?: string; error?: any };
  if (transferJson.error) {
    throw new Error(`Transfer failed: ${JSON.stringify(transferJson.error)}`);
  }
  const transferHash = transferJson.result as Hex;
  await publicClient.waitForTransactionReceipt({ hash: transferHash });

  const testBalance = await publicClient.readContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: [testAccount.address],
  });
  console.log(`Test account USDC: ${formatUSDC(testBalance)}`);
  passed(`Received ${formatUSDC(DEPOSIT_AMOUNT + TOPUP_AMOUNT)} USDC from whale`);

  // ========== TEST 3: Deposit USDC ==========
  console.log("");
  console.log("--- TEST 3: Deposit USDC ---");

  // Approve
  const approveHash = await walletClient.writeContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "approve",
    args: [liqAddress, DEPOSIT_AMOUNT],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  // Deposit
  const depositHash = await walletClient.writeContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "deposit",
    args: [DEPOSIT_AMOUNT],
  });
  const depositReceipt = await publicClient.waitForTransactionReceipt({
    hash: depositHash,
  });

  const poolBalance = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  console.log(`Pool balance: ${formatUSDC(poolBalance)} USDC`);
  console.log(`Gas used: ${depositReceipt.gasUsed.toLocaleString()}`);

  if (poolBalance !== DEPOSIT_AMOUNT) {
    failed(`Pool balance mismatch: ${poolBalance} != ${DEPOSIT_AMOUNT}`);
  }
  passed(`Deposited ${formatUSDC(DEPOSIT_AMOUNT)} USDC`);

  // ========== TEST 4: Check maxFlashLoan and flashFee ==========
  console.log("");
  console.log("--- TEST 4: Check ERC-3156 interface ---");

  const maxLoan = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "maxFlashLoan",
    args: [USDC],
  });

  const fee = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "flashFee",
    args: [USDC, FLASH_AMOUNT],
  });

  console.log(`maxFlashLoan: ${formatUSDC(maxLoan)} USDC`);
  console.log(`flashFee: ${fee}`);

  if (maxLoan !== DEPOSIT_AMOUNT) {
    failed(`maxFlashLoan mismatch: ${maxLoan} != ${DEPOSIT_AMOUNT}`);
  }
  if (fee !== 0n) {
    failed(`flashFee should be 0, got ${fee}`);
  }
  passed("ERC-3156 interface correct (zero fee)");

  // ========== TEST 5: Execute Flash Loan ==========
  console.log("");
  console.log("--- TEST 5: Execute Flash Loan ---");

  // Deploy mock borrower that repays immediately
  // Using the test contract from the test file (YulTest.t.sol)
  const borrowerArtifact = readArtifact("MockBorrower", "YulTest.t.sol");

  const borrowerHash = await walletClient.deployContract({
    abi: borrowerArtifact.abi,
    bytecode: borrowerArtifact.bytecode,
  });
  const borrowerReceipt = await publicClient.waitForTransactionReceipt({
    hash: borrowerHash,
  });
  const borrowerAddress = borrowerReceipt.contractAddress!;
  console.log(`MockBorrower deployed: ${borrowerAddress}`);

  // Execute flash loan via borrower
  const borrowAbi = parseAbi([
    "function borrow(address lender, uint256 amount)",
    "function borrowTwice(address lender, uint256 amount)",
  ]);

  // Single flash loan (cold tx)
  const flashHashCold = await walletClient.writeContract({
    address: borrowerAddress,
    abi: borrowAbi,
    functionName: "borrow",
    args: [liqAddress, FLASH_AMOUNT],
  });

  const flashReceiptCold = await publicClient.waitForTransactionReceipt({
    hash: flashHashCold,
  });

  console.log(`Flash loan (single tx): ${flashReceiptCold.gasUsed.toLocaleString()}`);
  console.log(`[!] For cold/warm breakdown, check Tenderly trace with "full trace" enabled`);

  const poolAfterFlash = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  if (poolAfterFlash !== DEPOSIT_AMOUNT) {
    failed(`Pool balance changed after flash: ${poolAfterFlash}`);
  }
  passed(`Flash loan of ${formatUSDC(FLASH_AMOUNT)} USDC completed`);

  // ========== TEST 6: Withdraw funds ==========
  console.log("");
  console.log("--- TEST 6: Withdraw funds ---");

  const balanceBefore = await publicClient.readContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: [testAccount.address],
  });

  const withdrawHash = await walletClient.writeContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "withdraw",
    args: [WITHDRAW_AMOUNT],
  });

  const withdrawReceipt = await publicClient.waitForTransactionReceipt({
    hash: withdrawHash,
  });

  const balanceAfter = await publicClient.readContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: [testAccount.address],
  });

  const poolAfterWithdraw = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  console.log(`Withdrew: ${formatUSDC(balanceAfter - balanceBefore)} USDC`);
  console.log(`Pool balance: ${formatUSDC(poolAfterWithdraw)} USDC`);
  console.log(`Gas used: ${withdrawReceipt.gasUsed.toLocaleString()}`);

  if (balanceAfter - balanceBefore !== WITHDRAW_AMOUNT) {
    failed(`Withdraw amount mismatch`);
  }
  if (poolAfterWithdraw !== DEPOSIT_AMOUNT - WITHDRAW_AMOUNT) {
    failed(`Pool balance after withdraw incorrect`);
  }
  passed(`Withdrew ${formatUSDC(WITHDRAW_AMOUNT)} USDC`);

  // ========== TEST 7: Top-up (deposit more) ==========
  console.log("");
  console.log("--- TEST 7: Top-up deposit ---");

  const approveHash2 = await walletClient.writeContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "approve",
    args: [liqAddress, TOPUP_AMOUNT],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash2 });

  const topupHash = await walletClient.writeContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "deposit",
    args: [TOPUP_AMOUNT],
  });

  const topupReceipt = await publicClient.waitForTransactionReceipt({
    hash: topupHash,
  });

  const poolAfterTopup = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  console.log(`Pool balance: ${formatUSDC(poolAfterTopup)} USDC`);
  console.log(`Gas used: ${topupReceipt.gasUsed.toLocaleString()}`);

  const expectedPool = DEPOSIT_AMOUNT - WITHDRAW_AMOUNT + TOPUP_AMOUNT;
  if (poolAfterTopup !== expectedPool) {
    failed(`Pool balance after topup incorrect: ${poolAfterTopup} != ${expectedPool}`);
  }
  passed(`Topped up ${formatUSDC(TOPUP_AMOUNT)} USDC`);

  // ========== TEST 8: Sync excess USDC ==========
  console.log("");
  console.log("--- TEST 8: Sync excess USDC ---");

  // Send USDC directly to contract (simulates donation/excess)
  const excessAmount = 5_000n * 10n ** 6n;
  
  const excessCalldata = encodeFunctionData({
    abi: USDC_ABI,
    functionName: "transfer",
    args: [liqAddress, excessAmount],
  });

  const excessResult = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_sendTransaction",
      params: [{
        from: USDC_WHALE,
        to: USDC,
        data: excessCalldata,
        gas: "0x30000",
      }],
      id: 10,
    }),
  });
  const excessJson = await excessResult.json() as { result?: string; error?: any };
  if (excessJson.error) {
    throw new Error(`Excess transfer failed: ${JSON.stringify(excessJson.error)}`);
  }
  const excessHash = excessJson.result as Hex;
  await publicClient.waitForTransactionReceipt({ hash: excessHash });

  const actualBalance = await publicClient.readContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: [liqAddress],
  });

  const poolBeforeSync = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  console.log(`Actual USDC: ${formatUSDC(actualBalance)}`);
  console.log(`Pool balance (before sync): ${formatUSDC(poolBeforeSync)}`);
  console.log(`Excess: ${formatUSDC(actualBalance - poolBeforeSync)}`);

  // Sync
  const syncHash = await walletClient.writeContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "sync",
  });
  const syncReceipt = await publicClient.waitForTransactionReceipt({
    hash: syncHash,
  });

  const poolAfterSync = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  console.log(`Pool balance (after sync): ${formatUSDC(poolAfterSync)}`);
  console.log(`Gas used: ${syncReceipt.gasUsed.toLocaleString()}`);

  if (poolAfterSync !== actualBalance) {
    failed(`Sync failed: poolBalance != actualBalance`);
  }
  passed(`Synced ${formatUSDC(excessAmount)} excess USDC`);

  // ========== SUMMARY ==========
  console.log("");
  console.log("============================================================");
  console.log("ALL TESTS PASSED");
  console.log("============================================================");
  console.log("");
  console.log(`Contract: ${liqAddress}`);
  console.log(`Final pool balance: ${formatUSDC(poolAfterSync)} USDC`);
  console.log("");
  console.log("Gas Summary:");
  console.log(`  Deploy:     ${deployReceipt.gasUsed.toLocaleString()}`);
  console.log(`  Deposit:    ${depositReceipt.gasUsed.toLocaleString()}`);
  console.log(`  Flash loan: ${flashReceiptCold.gasUsed.toLocaleString()}`);
  console.log(`  Withdraw:   ${withdrawReceipt.gasUsed.toLocaleString()}`);
  console.log(`  Top-up:     ${topupReceipt.gasUsed.toLocaleString()}`);
  console.log(`  Sync:       ${syncReceipt.gasUsed.toLocaleString()}`);
}

main().catch((err) => {
  console.error("[X] Test failed:", err);
  process.exit(1);
});
