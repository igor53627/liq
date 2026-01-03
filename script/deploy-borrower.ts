/**
 * Deploy TestBorrower for flash loan testing
 */

import {
  createWalletClient,
  createPublicClient,
  http,
  Hex,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import readline from "readline";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const RPC_URL = process.env.RPC_URL || "https://ethereum-rpc.publicnode.com";

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

function readArtifact(contractName: string): { abi: any; bytecode: Hex } {
  const artifactPath = path.join(
    __dirname,
    `../out/${contractName}.sol/${contractName}.json`
  );
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  let bytecode = artifact.bytecode?.object || artifact.bytecode;
  if (!bytecode.startsWith("0x")) {
    bytecode = "0x" + bytecode;
  }
  return { abi: artifact.abi, bytecode: bytecode as Hex };
}

async function main() {
  console.log("Deploying TestBorrower...");
  
  const mnemonic = await readMnemonic();
  const mnemonicAccount = mnemonicToAccount(mnemonic.trim(), { addressIndex: 0 });
  const hdKey = mnemonicAccount.getHdKey();
  const privateKey = `0x${Buffer.from(hdKey.privateKey!).toString("hex")}` as Hex;
  const account = privateKeyToAccount(privateKey);
  
  console.log(`Deployer: ${account.address}`);

  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(RPC_URL),
  });

  const artifact = readArtifact("TestBorrower");

  const hash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode,
  });

  console.log(`Tx: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`[OK] TestBorrower deployed: ${receipt.contractAddress}`);
  console.log(`Gas: ${receipt.gasUsed.toLocaleString()}`);
}

main().catch(console.error);
