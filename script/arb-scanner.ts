/**
 * DEX Arbitrage Scanner
 * 
 * Scans for price differences between Uniswap V2, Sushiswap, and Uniswap V3
 * for USDC pairs. Reports opportunities that exceed gas costs.
 * 
 * Usage:
 *   npx tsx script/arb-scanner.ts
 *   npx tsx script/arb-scanner.ts --watch    # Continuous monitoring
 */

import {
  createPublicClient,
  http,
  parseAbi,
  formatUnits,
  Address,
} from "viem";
import { mainnet } from "viem/chains";

const RPC_URL = process.env.RPC_URL || "https://ethereum-rpc.publicnode.com";
const WATCH_MODE = process.argv.includes("--watch");

// Token addresses
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" as Address;
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" as Address;
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7" as Address;
const DAI = "0x6B175474E89094C44Da98b954EedeAC495271d0F" as Address;
const WBTC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599" as Address;

// DEX Routers/Factories
const UNISWAP_V2_FACTORY = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f" as Address;
const SUSHISWAP_FACTORY = "0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac" as Address;
const UNISWAP_V3_FACTORY = "0x1F98431c8aD98523631AE4a59f267346ea31F984" as Address;
const UNISWAP_V3_QUOTER = "0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6" as Address;

// ABIs
const FACTORY_ABI = parseAbi([
  "function getPair(address tokenA, address tokenB) view returns (address)",
]);

const PAIR_ABI = parseAbi([
  "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
]);

const V3_FACTORY_ABI = parseAbi([
  "function getPool(address tokenA, address tokenB, uint24 fee) view returns (address)",
]);

const V3_QUOTER_ABI = parseAbi([
  "function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96) view returns (uint256 amountOut)",
]);

// V3 fee tiers
const V3_FEES = [500, 3000, 10000]; // 0.05%, 0.3%, 1%

interface PriceQuote {
  dex: string;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  amountOut: bigint;
  price: number; // tokenOut per tokenIn
  poolAddress: Address;
  fee?: number;
}

interface ArbOpportunity {
  tokenA: string;
  tokenB: string;
  buyDex: string;
  sellDex: string;
  buyPrice: number;
  sellPrice: number;
  spreadBps: number;
  profitUsd: number;
  amountIn: bigint;
}

const client = createPublicClient({
  chain: mainnet,
  transport: http(RPC_URL),
});

// Get Uniswap V2 style price
async function getV2Price(
  factory: Address,
  dexName: string,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint
): Promise<PriceQuote | null> {
  try {
    const pairAddress = await client.readContract({
      address: factory,
      abi: FACTORY_ABI,
      functionName: "getPair",
      args: [tokenIn, tokenOut],
    });

    if (pairAddress === "0x0000000000000000000000000000000000000000") {
      return null;
    }

    const [reserves, token0] = await Promise.all([
      client.readContract({
        address: pairAddress,
        abi: PAIR_ABI,
        functionName: "getReserves",
      }),
      client.readContract({
        address: pairAddress,
        abi: PAIR_ABI,
        functionName: "token0",
      }),
    ]);

    const [reserve0, reserve1] = reserves;
    
    let reserveIn: bigint, reserveOut: bigint;
    if (token0.toLowerCase() === tokenIn.toLowerCase()) {
      reserveIn = BigInt(reserve0);
      reserveOut = BigInt(reserve1);
    } else {
      reserveIn = BigInt(reserve1);
      reserveOut = BigInt(reserve0);
    }

    // Calculate output using constant product formula with 0.3% fee
    const amountInWithFee = amountIn * 997n;
    const numerator = amountInWithFee * reserveOut;
    const denominator = reserveIn * 1000n + amountInWithFee;
    const amountOut = numerator / denominator;

    if (amountOut === 0n) return null;

    const price = Number(amountOut) / Number(amountIn);

    return {
      dex: dexName,
      tokenIn,
      tokenOut,
      amountIn,
      amountOut,
      price,
      poolAddress: pairAddress,
    };
  } catch {
    return null;
  }
}

// Get Uniswap V3 price
async function getV3Price(
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  fee: number
): Promise<PriceQuote | null> {
  try {
    const poolAddress = await client.readContract({
      address: UNISWAP_V3_FACTORY,
      abi: V3_FACTORY_ABI,
      functionName: "getPool",
      args: [tokenIn, tokenOut, fee],
    });

    if (poolAddress === "0x0000000000000000000000000000000000000000") {
      return null;
    }

    const amountOut = await client.readContract({
      address: UNISWAP_V3_QUOTER,
      abi: V3_QUOTER_ABI,
      functionName: "quoteExactInputSingle",
      args: [tokenIn, tokenOut, fee, amountIn, 0n],
    });

    if (amountOut === 0n) return null;

    const price = Number(amountOut) / Number(amountIn);

    return {
      dex: `UniV3-${fee / 10000}%`,
      tokenIn,
      tokenOut,
      amountIn,
      amountOut,
      price,
      poolAddress,
      fee,
    };
  } catch {
    return null;
  }
}

// Get all prices for a token pair
async function getAllPrices(
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint
): Promise<PriceQuote[]> {
  const quotes: (PriceQuote | null)[] = await Promise.all([
    getV2Price(UNISWAP_V2_FACTORY, "UniV2", tokenIn, tokenOut, amountIn),
    getV2Price(SUSHISWAP_FACTORY, "Sushi", tokenIn, tokenOut, amountIn),
    ...V3_FEES.map((fee) => getV3Price(tokenIn, tokenOut, amountIn, fee)),
  ]);

  return quotes.filter((q): q is PriceQuote => q !== null);
}

// Find arbitrage opportunities
async function findArbOpportunities(
  tokenA: Address,
  tokenB: Address,
  tokenASymbol: string,
  tokenBSymbol: string,
  amountIn: bigint,
  tokenADecimals: number
): Promise<ArbOpportunity[]> {
  const opportunities: ArbOpportunity[] = [];

  // Get prices for A -> B (buy B with A)
  const buyQuotes = await getAllPrices(tokenA, tokenB, amountIn);
  
  // Get prices for B -> A (sell B for A)
  // For this we need to estimate how much B we'd have from buying
  if (buyQuotes.length < 2) return opportunities;

  // Compare all pairs of DEXes
  for (const buyQuote of buyQuotes) {
    // Get sell quotes for the amount of tokenB we'd receive
    const sellQuotes = await getAllPrices(tokenB, tokenA, buyQuote.amountOut);

    for (const sellQuote of sellQuotes) {
      if (buyQuote.dex === sellQuote.dex) continue; // Skip same DEX

      // Calculate profit: sellQuote.amountOut - amountIn
      const profit = sellQuote.amountOut - amountIn;
      const profitUsd = Number(formatUnits(profit, tokenADecimals));
      
      // Calculate spread in bps
      const spreadBps = (Number(profit) / Number(amountIn)) * 10000;

      // Only report if profitable (> 0.1% to cover gas)
      if (spreadBps > 10) {
        opportunities.push({
          tokenA: tokenASymbol,
          tokenB: tokenBSymbol,
          buyDex: buyQuote.dex,
          sellDex: sellQuote.dex,
          buyPrice: buyQuote.price,
          sellPrice: sellQuote.price,
          spreadBps,
          profitUsd,
          amountIn,
        });
      }
    }
  }

  return opportunities;
}

// Token pairs to scan
const PAIRS = [
  { tokenA: USDC, tokenB: WETH, symbolA: "USDC", symbolB: "WETH", decimalsA: 6, amountA: 10000n * 10n ** 6n }, // 10k USDC
  { tokenA: USDC, tokenB: WBTC, symbolA: "USDC", symbolB: "WBTC", decimalsA: 6, amountA: 10000n * 10n ** 6n },
  { tokenA: USDC, tokenB: USDT, symbolA: "USDC", symbolB: "USDT", decimalsA: 6, amountA: 10000n * 10n ** 6n },
];

async function scan() {
  console.log("=".repeat(60));
  console.log(`Scanning for arbitrage opportunities...`);
  console.log(`Time: ${new Date().toISOString()}`);
  console.log("=".repeat(60));
  console.log("");

  let totalOpportunities = 0;

  for (const pair of PAIRS) {
    console.log(`[${pair.symbolA}/${pair.symbolB}] Checking prices...`);

    // Get all prices for display
    const prices = await getAllPrices(pair.tokenA, pair.tokenB, pair.amountA);
    
    if (prices.length === 0) {
      console.log("  No liquidity found");
      continue;
    }

    // Show prices
    console.log(`  Prices for ${formatUnits(pair.amountA, pair.decimalsA)} ${pair.symbolA}:`);
    for (const p of prices.sort((a, b) => b.price - a.price)) {
      console.log(`    ${p.dex.padEnd(12)} -> ${formatUnits(p.amountOut, pair.symbolB === "WETH" ? 18 : pair.symbolB === "WBTC" ? 8 : 6)} ${pair.symbolB}`);
    }

    // Find arb opportunities
    const opps = await findArbOpportunities(
      pair.tokenA,
      pair.tokenB,
      pair.symbolA,
      pair.symbolB,
      pair.amountA,
      pair.decimalsA
    );

    if (opps.length > 0) {
      console.log(`  [!] Opportunities found:`);
      for (const opp of opps.sort((a, b) => b.spreadBps - a.spreadBps)) {
        console.log(`    Buy on ${opp.buyDex}, sell on ${opp.sellDex}: +${opp.spreadBps.toFixed(1)} bps ($${opp.profitUsd.toFixed(2)} profit)`);
      }
      totalOpportunities += opps.length;
    } else {
      console.log(`  No profitable arb (spread < 10 bps)`);
    }

    console.log("");
  }

  console.log("=".repeat(60));
  console.log(`Total opportunities: ${totalOpportunities}`);
  console.log("=".repeat(60));
}

async function main() {
  if (WATCH_MODE) {
    console.log("Starting continuous monitoring (Ctrl+C to stop)...");
    console.log("");
    
    while (true) {
      await scan();
      console.log("");
      console.log("Waiting 12 seconds (1 block)...");
      console.log("");
      await new Promise((r) => setTimeout(r, 12000));
    }
  } else {
    await scan();
  }
}

main().catch(console.error);
