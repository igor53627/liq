/**
 * Arbitrage Simulation on Tenderly Fork
 * 
 * Simulates a flash loan arbitrage trade:
 * 1. Flash loan USDC from LIQ
 * 2. Swap USDC -> WETH on cheaper DEX
 * 3. Swap WETH -> USDC on more expensive DEX
 * 4. Repay flash loan
 * 5. Keep profit
 * 
 * Usage:
 *   source ~/.zsh_secrets
 *   npx tsx script/arb-simulate.ts
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  formatUnits,
  encodeFunctionData,
  Hex,
  Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Addresses
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" as Address;
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" as Address;
const USDC_WHALE = "0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341" as Address;

// DEX Routers
const UNISWAP_V2_ROUTER = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D" as Address;
const SUSHISWAP_ROUTER = "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F" as Address;

// ABIs
const USDC_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address, uint256) returns (bool)",
  "function approve(address, uint256) returns (bool)",
]);

const ROUTER_ABI = parseAbi([
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) returns (uint256[] memory amounts)",
  "function getAmountsOut(uint256 amountIn, address[] calldata path) view returns (uint256[] memory amounts)",
]);

const LIQ_ABI = parseAbi([
  "function poolBalance() view returns (uint256)",
  "function flashLoan(address receiver, address token, uint256 amount, bytes data) returns (bool)",
  "function deposit(uint256 amount)",
]);

// Create Tenderly fork
async function createTenderlyFork(): Promise<string> {
  const accessKey = process.env.TENDERLY_ACCESS_KEY;
  const account = process.env.TENDERLY_ACCOUNT || "pse-team";
  const project = process.env.TENDERLY_PROJECT || "yolo";

  if (!accessKey) {
    throw new Error("TENDERLY_ACCESS_KEY not set");
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
        slug: `arb-sim-${Date.now()}`,
        display_name: `Arb Simulation ${new Date().toISOString()}`,
        fork_config: { network_id: 1 },
        virtual_network_config: { chain_config: { chain_id: 1 } },
        sync_state_config: { enabled: false },
        explorer_page_config: { enabled: true, verification_visibility: "src" },
      }),
    }
  );

  if (!response.ok) {
    throw new Error(`Failed to create fork: ${await response.text()}`);
  }

  const data = await response.json();
  const rpcUrl = data.rpcs?.[0]?.url;
  if (!rpcUrl) throw new Error("No RPC URL in response");

  console.log(`[OK] Fork created`);
  return rpcUrl;
}

// Deploy ArbExecutor contract
function getArbExecutorBytecode(): { abi: any; bytecode: Hex } {
  const artifactPath = path.join(__dirname, "../out/ArbExecutor.sol/ArbExecutor.json");
  
  if (!fs.existsSync(artifactPath)) {
    throw new Error("ArbExecutor not compiled. Run: forge build");
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  let bytecode = artifact.bytecode?.object || artifact.bytecode;
  if (!bytecode.startsWith("0x")) bytecode = "0x" + bytecode;

  return { abi: artifact.abi, bytecode: bytecode as Hex };
}

async function main() {
  console.log("============================================================");
  console.log("Arbitrage Simulation");
  console.log("============================================================");
  console.log("");

  // Build contracts
  console.log("Building contracts...");
  execSync("forge build", { stdio: "inherit", cwd: path.join(__dirname, "..") });
  console.log("");

  // Create fork
  const rpcUrl = await createTenderlyFork();
  console.log("");

  // Setup test account
  const testKey = `0x${"ab".repeat(32)}` as Hex;
  const testAccount = privateKeyToAccount(testKey);
  console.log(`Test account: ${testAccount.address}`);

  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account: testAccount,
    chain: mainnet,
    transport: http(rpcUrl),
  });

  // Fund test account
  console.log("Funding test account...");
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

  // Transfer USDC to test account from whale
  const usdcAmount = 100_000n * 10n ** 6n; // 100k USDC
  const transferCalldata = encodeFunctionData({
    abi: USDC_ABI,
    functionName: "transfer",
    args: [testAccount.address, usdcAmount],
  });

  await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_sendTransaction",
      params: [{ from: USDC_WHALE, to: USDC, data: transferCalldata, gas: "0x30000" }],
      id: 2,
    }),
  });

  const usdcBalance = await publicClient.readContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: [testAccount.address],
  });
  console.log(`USDC balance: ${formatUnits(usdcBalance, 6)}`);
  console.log("");

  // Deploy LIQFlashYul
  console.log("Deploying LIQFlashYul...");
  const liqArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../out/LIQFlashYul.sol/LIQFlashYul.json"), "utf8")
  );
  let liqBytecode = liqArtifact.bytecode?.object || liqArtifact.bytecode;
  if (!liqBytecode.startsWith("0x")) liqBytecode = "0x" + liqBytecode;

  const liqDeployHash = await walletClient.deployContract({
    abi: liqArtifact.abi,
    bytecode: liqBytecode as Hex,
  });
  const liqReceipt = await publicClient.waitForTransactionReceipt({ hash: liqDeployHash });
  const liqAddress = liqReceipt.contractAddress!;
  console.log(`LIQ deployed: ${liqAddress}`);

  // Fund LIQ with USDC
  const depositAmount = 50_000n * 10n ** 6n; // 50k
  await walletClient.writeContract({
    address: USDC,
    abi: USDC_ABI,
    functionName: "approve",
    args: [liqAddress, depositAmount],
  });
  await walletClient.writeContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "deposit",
    args: [depositAmount],
  });

  const poolBalance = await publicClient.readContract({
    address: liqAddress,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });
  console.log(`LIQ pool balance: ${formatUnits(poolBalance, 6)} USDC`);
  console.log("");

  // Check prices on different DEXes
  console.log("Checking DEX prices...");
  const flashAmount = 10_000n * 10n ** 6n; // 10k USDC

  const [uniAmounts, sushiAmounts] = await Promise.all([
    publicClient.readContract({
      address: UNISWAP_V2_ROUTER,
      abi: ROUTER_ABI,
      functionName: "getAmountsOut",
      args: [flashAmount, [USDC, WETH]],
    }),
    publicClient.readContract({
      address: SUSHISWAP_ROUTER,
      abi: ROUTER_ABI,
      functionName: "getAmountsOut",
      args: [flashAmount, [USDC, WETH]],
    }),
  ]);

  const uniWethOut = uniAmounts[1];
  const sushiWethOut = sushiAmounts[1];

  console.log(`UniV2:  ${formatUnits(flashAmount, 6)} USDC -> ${formatUnits(uniWethOut, 18)} WETH`);
  console.log(`Sushi:  ${formatUnits(flashAmount, 6)} USDC -> ${formatUnits(sushiWethOut, 18)} WETH`);

  // Determine which DEX is cheaper for buying WETH
  const buyOnUni = uniWethOut > sushiWethOut;
  const buyRouter = buyOnUni ? UNISWAP_V2_ROUTER : SUSHISWAP_ROUTER;
  const sellRouter = buyOnUni ? SUSHISWAP_ROUTER : UNISWAP_V2_ROUTER;
  const wethAmount = buyOnUni ? uniWethOut : sushiWethOut;

  console.log(`Best buy: ${buyOnUni ? "UniV2" : "Sushi"} (${formatUnits(wethAmount, 18)} WETH)`);

  // Get sell price
  const sellAmounts = await publicClient.readContract({
    address: sellRouter,
    abi: ROUTER_ABI,
    functionName: "getAmountsOut",
    args: [wethAmount, [WETH, USDC]],
  });
  const usdcBack = sellAmounts[1];

  console.log(`Sell on ${buyOnUni ? "Sushi" : "UniV2"}: ${formatUnits(wethAmount, 18)} WETH -> ${formatUnits(usdcBack, 6)} USDC`);

  const profit = usdcBack - flashAmount;
  const profitPct = (Number(profit) / Number(flashAmount)) * 100;

  console.log("");
  console.log(`Expected profit: ${formatUnits(profit, 6)} USDC (${profitPct.toFixed(3)}%)`);

  if (profit <= 0n) {
    console.log("");
    console.log("[!] No profitable arbitrage opportunity found");
    console.log("    This is expected - major pairs are heavily arbitraged");
    console.log("    In production, you'd scan many pairs and wait for opportunities");
    console.log("");
    console.log("Simulation complete (no trade executed)");
    return;
  }

  // If profitable, we would deploy ArbExecutor and execute the trade
  console.log("");
  console.log("[OK] Profitable opportunity found!");
  console.log("    In production, this would trigger the ArbExecutor contract");
  console.log("");
  console.log("============================================================");
  console.log("SIMULATION COMPLETE");
  console.log("============================================================");
}

main().catch((err) => {
  console.error("[X] Simulation failed:", err);
  process.exit(1);
});
