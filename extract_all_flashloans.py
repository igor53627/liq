#!/usr/bin/env python3
"""
Extract ALL Balancer V2 FlashLoan events with loan sizes using Envio HyperSync.
Exports to CSV for analysis.

Requires: pip install hypersync
"""
from __future__ import annotations
import hypersync
import asyncio
import os
import csv
from typing import Optional
from datetime import datetime

BALANCER_VAULT = "0xBA12222222228d8Ba445958a75a0704d566BF2C8"
FLASHLOAN_TOPIC = "0x0d7d75e01ab95780d3cd1c8ec0dd6c2ce19e3a20427eec8bf53283b6fb8e95f0"

KNOWN_TOKENS = {
    "0x000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6),
    "0x000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6),
    "0x0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f": ("DAI", 18),
    "0x000000000000000000000000853d955acef822db058eb8505911ed77f175b99e": ("FRAX", 18),
    "0x0000000000000000000000005f98805a4e8be255a32880fdec7f6728c6568ba0": ("LUSD", 18),
    "0x000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": ("WETH", 18),
    "0x0000000000000000000000002260fac5e5542a773aa44fbcfedf7c193bc2c599": ("WBTC", 8),
    "0x000000000000000000000000cd5fe23c85820f7b72d0926fc9b05b43e359b7ee": ("weETH", 18),
    "0x0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0": ("wstETH", 18),
    "0x000000000000000000000000ae78736cd615f374d3085123a210448e74fc6393": ("rETH", 18),
    "0x000000000000000000000000be9895146f7af43049ca1c1ae358b0541ea49704": ("cbETH", 18),
    "0x000000000000000000000000a35b1b31ce002fbf2058d22f30f95d405200a15b": ("ETHx", 18),
    "0x000000000000000000000000ac3e018457b222d93114458476f3e3416abbe38f": ("sfrxETH", 18),
}


async def query_flashloans(from_block: int, to_block: int | None = None):
    """Query ALL FlashLoan events from Balancer Vault."""
    
    api_token = os.environ.get("ENVIO_API_KEY") or os.environ.get("ENVIO_API_TOKEN")
    if not api_token:
        print("[WARN] No ENVIO_API_KEY found, rate limited mode")
        config = hypersync.ClientConfig(url="https://eth.hypersync.xyz")
    else:
        config = hypersync.ClientConfig(
            url="https://eth.hypersync.xyz",
            bearer_token=api_token
        )
    
    client = hypersync.HypersyncClient(config)
    
    query = hypersync.Query(
        from_block=from_block,
        to_block=to_block,
        logs=[
            hypersync.LogSelection(
                address=[BALANCER_VAULT],
                topics=[[FLASHLOAN_TOPIC]],
            )
        ],
        field_selection=hypersync.FieldSelection(
            log=[
                hypersync.LogField.TRANSACTION_HASH,
                hypersync.LogField.BLOCK_NUMBER,
                hypersync.LogField.TOPIC0,
                hypersync.LogField.TOPIC1,
                hypersync.LogField.TOPIC2,
                hypersync.LogField.DATA,
            ],
            transaction=[
                hypersync.TransactionField.GAS_USED,
                hypersync.TransactionField.GAS_PRICE,
                hypersync.TransactionField.HASH,
            ],
        ),
        include_all_blocks=False,
        join_mode=hypersync.JoinMode.JOIN_ALL,
    )
    
    print(f"Querying FlashLoan events from block {from_block} to {to_block or 'latest'}...")
    
    all_logs = []
    all_txs = {}
    
    while True:
        res = await client.get(query)
        
        if res.data.logs:
            all_logs.extend(res.data.logs)
        
        if res.data.transactions:
            for tx in res.data.transactions:
                if hasattr(tx, 'hash') and tx.hash:
                    all_txs[tx.hash] = tx
        
        target = to_block or res.archive_height
        pct = (res.next_block - from_block) / (target - from_block) * 100 if target > from_block else 100
        print(f"  {len(all_logs):,} events | block {res.next_block:,} | {pct:.1f}%")
        
        if res.next_block >= target:
            break
        
        query.from_block = res.next_block
    
    return all_logs, all_txs


def decode_flashloan_log(log, txs):
    """Decode a FlashLoan event log with loan size."""
    recipient_topic = log.topics[1] if len(log.topics) > 1 else None
    token_topic = log.topics[2] if len(log.topics) > 2 else None
    
    token_info = KNOWN_TOKENS.get(token_topic)
    if token_info:
        token_name, decimals = token_info
    else:
        token_name = token_topic[26:42] + "..." if token_topic else "Unknown"
        decimals = 18
    
    amount_raw = 0
    fee_raw = 0
    if log.data and len(log.data) >= 66:
        amount_raw = int(log.data[2:66], 16)
        if len(log.data) >= 130:
            fee_raw = int(log.data[66:130], 16)
    
    amount_formatted = amount_raw / (10 ** decimals)
    
    tx = txs.get(log.transaction_hash)
    gas_used = 0
    gas_price = 0
    if tx:
        if hasattr(tx, 'gas_used') and tx.gas_used:
            gas_used = int(tx.gas_used, 16) if isinstance(tx.gas_used, str) else tx.gas_used
        if hasattr(tx, 'gas_price') and tx.gas_price:
            gas_price = int(tx.gas_price, 16) if isinstance(tx.gas_price, str) else tx.gas_price
    
    return {
        "tx_hash": log.transaction_hash,
        "block": log.block_number,
        "token": token_name,
        "token_address": token_topic[26:] if token_topic else "",
        "amount_raw": amount_raw,
        "amount": amount_formatted,
        "decimals": decimals,
        "fee_raw": fee_raw,
        "gas_used": gas_used,
        "gas_price_gwei": gas_price / 1e9 if gas_price else 0,
        "recipient": recipient_topic[26:] if recipient_topic else "",
    }


async def main():
    from_block = 19000000
    to_block = 21000000
    
    logs, txs = await query_flashloans(from_block, to_block)
    
    print(f"\n{'='*80}")
    print(f"Found {len(logs):,} FlashLoan events")
    print(f"{'='*80}\n")
    
    if not logs:
        print("No flash loans found.")
        return
    
    events = []
    for log in logs:
        events.append(decode_flashloan_log(log, txs))
    
    csv_file = "balancer_flashloans_full.csv"
    with open(csv_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "tx_hash", "block", "token", "token_address", 
            "amount_raw", "amount", "decimals", "fee_raw",
            "gas_used", "gas_price_gwei", "recipient"
        ])
        writer.writeheader()
        for e in events:
            writer.writerow(e)
    
    print(f"Saved {len(events):,} events to {csv_file}")
    
    from collections import defaultdict
    by_token = defaultdict(list)
    for e in events:
        by_token[e["token"]].append(e)
    
    print(f"\n{'='*80}")
    print("SUMMARY BY TOKEN")
    print(f"{'='*80}\n")
    
    for token, token_events in sorted(by_token.items(), key=lambda x: -len(x[1]))[:15]:
        amounts = [e["amount"] for e in token_events]
        gas_list = [e["gas_used"] for e in token_events if e["gas_used"] > 0]
        
        print(f"{token}: {len(token_events):,} flash loans")
        print(f"  Loan sizes: min={min(amounts):,.2f}, max={max(amounts):,.2f}, avg={sum(amounts)/len(amounts):,.2f}")
        if gas_list:
            print(f"  Gas: min={min(gas_list):,}, max={max(gas_list):,}, avg={sum(gas_list)/len(gas_list):,.0f}")
        print()
    
    stables = ["USDC", "USDT", "DAI", "FRAX", "LUSD"]
    stable_events = [e for e in events if e["token"] in stables]
    
    print(f"\n{'='*80}")
    print(f"STABLECOIN FLASH LOANS: {len(stable_events):,} events")
    print(f"{'='*80}\n")
    
    for token in stables:
        token_events = [e for e in stable_events if e["token"] == token]
        if not token_events:
            continue
        amounts = [e["amount"] for e in token_events]
        gas_list = [e["gas_used"] for e in token_events if e["gas_used"] > 0]
        
        print(f"{token}: {len(token_events):,} loans")
        print(f"  Total volume: ${sum(amounts):,.0f}")
        print(f"  Avg loan: ${sum(amounts)/len(amounts):,.0f}")
        print(f"  Max loan: ${max(amounts):,.0f}")
        if gas_list:
            print(f"  Avg gas: {sum(gas_list)/len(gas_list):,.0f}")
        print()


if __name__ == "__main__":
    asyncio.run(main())
