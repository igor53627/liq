/**
 * Test flash loan on mainnet via TestBorrower
 * 
 * Usage:
 *   npx tsx script/test-flashloan.ts [amount_usdc]
 * 
 * Examples:
 *   npx tsx script/test-flashloan.ts        # 10 USDC (default)
 *   npx tsx script/test-flashloan.ts 50     # 50 USDC
 */

import {
  createWalletClient,
  createPublicClient,
  http,
  parseAbi,
  formatUnits,
  Hex,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import readline from "readline";

const LIQ_ADDRESS = "0xe9eb8a0f6328e243086fe6efee0857e14fa2cb87";
const BORROWER_ADDRESS = "0x53cddbcdee2dc2b756a25307f4810c609b28c3e7";
const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const RPC_URL = process.env.RPC_URL || "https://ethereum-rpc.publicnode.com";

const LIQ_ABI = parseAbi([
  "function poolBalance() view returns (uint256)",
  "function maxFlashLoan(address) view returns (uint256)",
]);

const BORROWER_ABI = parseAbi([
  "function borrow(address lender, uint256 amount)",
  "function borrowSilent(address lender, uint256 amount)",
]);

async function readMnemonic(): Promise<string> {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    process.stdout.write("Enter mnemonic: ");

    if (process.stdin.isTTY) {
      (process.stdin as any).setRawMode(true);
    }

    let mnemonic = "";
    process.stdin.on("data", (char) => {
      const c = char.toString();
      if (c === "\n" || c === "\r" || c === "\u0004") {
        if (process.stdin.isTTY) {
          (process.stdin as any).setRawMode(false);
        }
        console.log("");
        rl.close();
        resolve(mnemonic);
      } else if (c === "\u007F" || c === "\b") {
        mnemonic = mnemonic.slice(0, -1);
      } else if (c === "\u0003") {
        process.exit(1);
      } else {
        mnemonic += c;
      }
    });
  });
}

async function main() {
  const amountUSDC = parseFloat(process.argv[2] || "10");
  const amount = BigInt(Math.floor(amountUSDC * 1e6));

  console.log("============================================================");
  console.log("LIQ Flash Loan Test (Mainnet)");
  console.log("============================================================");
  console.log("");
  console.log(`LIQ:      ${LIQ_ADDRESS}`);
  console.log(`Borrower: ${BORROWER_ADDRESS}`);
  console.log(`Amount:   ${amountUSDC} USDC`);
  console.log("");

  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(RPC_URL),
  });

  // Check pool balance
  const poolBalance = await publicClient.readContract({
    address: LIQ_ADDRESS,
    abi: LIQ_ABI,
    functionName: "poolBalance",
  });

  console.log(`Pool balance: ${formatUnits(poolBalance, 6)} USDC`);

  if (amount > poolBalance) {
    console.error(`[X] Amount exceeds pool balance`);
    process.exit(1);
  }

  // Get mnemonic
  const mnemonic = await readMnemonic();
  const mnemonicAccount = mnemonicToAccount(mnemonic.trim(), { addressIndex: 0 });
  const hdKey = mnemonicAccount.getHdKey();
  const privateKey = `0x${Buffer.from(hdKey.privateKey!).toString("hex")}` as Hex;
  const account = privateKeyToAccount(privateKey);

  console.log(`Sender: ${account.address}`);
  console.log("");

  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(RPC_URL),
  });

  // Execute flash loan
  console.log(`Executing ${amountUSDC} USDC flash loan...`);

  const hash = await walletClient.writeContract({
    address: BORROWER_ADDRESS,
    abi: BORROWER_ABI,
    functionName: "borrow",
    args: [LIQ_ADDRESS, amount],
  });

  console.log(`Tx: ${hash}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  console.log("");
  console.log(`[OK] Flash loan complete!`);
  console.log(`Gas used: ${receipt.gasUsed.toLocaleString()}`);
  console.log(`Etherscan: https://etherscan.io/tx/${hash}`);
}

main().catch((err) => {
  console.error("[X] Failed:", err.message);
  process.exit(1);
});
