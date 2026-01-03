/**
 * Shared utilities for deployment scripts
 */

import readline from "readline";

/**
 * Securely read mnemonic from stdin (no echo)
 */
export async function readMnemonic(): Promise<string> {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    process.stdout.write(
      "Enter your 12/24 word mnemonic (will not be echoed): "
    );

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
