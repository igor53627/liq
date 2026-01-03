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
import { readMnemonic } from "./utils.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const RPC_URL = process.env.RPC_URL || "https://ethereum-rpc.publicnode.com";

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
