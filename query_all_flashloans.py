#!/usr/bin/env python3
"""
Query ALL Balancer V2 FlashLoan events using Envio HyperSync.
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

STABLECOINS = {
    "0x000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
    "0x000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7": "USDT",
    "0x0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f": "DAI",
    "0x000000000000000000000000853d955acef822db058eb8505911ed77f175b99e": "FRAX",
    "0x0000000000000000000000005f98805a4e8be255a32880fdec7f6728c6568ba0": "LUSD",
    "0x000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": "WETH",
    "0x0000000000000000000000002260fac5e5542a773aa44fbcfedf7c193bc2c599": "WBTC",
}


async def query_flashloans(from_block: int, to_block: int | None = None):
    """Query ALL FlashLoan events from Balancer Vault."""
    
    api_token = os.environ.get("ENVIO_API_KEY") or os.environ.get("ENVIO_API_TOKEN")
    if not api_token:
        print("[WARN] No ENVIO_API_KEY found, using unauthenticated (rate limited)")
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
                topics=[
                    [FLASHLOAN_TOPIC],
                ],
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
    
    print(f"Querying FlashLoan events from block {from_block}...")
    if to_block:
        print(f"  to block {to_block}")
    
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
        
        print(f"  Fetched {len(all_logs)} events so far (at block {res.next_block})...")
        
        if res.next_block >= (to_block or res.archive_height):
            break
        
        query.from_block = res.next_block
    
    return all_logs, all_txs


def decode_flashloan_log(log, txs):
    """Decode a FlashLoan event log."""
    token_topic = log.topics[2] if len(log.topics) > 2 else None
    token_name = STABLECOINS.get(token_topic, token_topic[:20] + "..." if token_topic else "Unknown")
    
    amount = 0
    fee = 0
    if log.data and len(log.data) >= 66:
        amount = int(log.data[2:66], 16)
        if len(log.data) >= 130:
            fee = int(log.data[66:130], 16)
    
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
        "token_topic": token_topic,
        "amount": amount,
        "fee": fee,
        "gas_used": gas_used,
        "gas_price_gwei": gas_price / 1e9 if gas_price else 0,
    }


async def main():
    from_block = 20000000
    to_block = 20050000
    
    logs, txs = await query_flashloans(from_block, to_block)
    
    print(f"\n{'='*80}")
    print(f"Found {len(logs)} FlashLoan events")
    print(f"{'='*80}\n")
    
    if not logs:
        print("No flash loans found.")
        return
    
    unique_txs = set()
    stablecoin_events = []
    
    for log in logs:
        decoded = decode_flashloan_log(log, txs)
        if decoded["token"] in ["USDC", "USDT", "DAI", "FRAX", "LUSD"]:
            stablecoin_events.append(decoded)
            unique_txs.add(decoded["tx_hash"])
    
    print(f"Stablecoin flash loans: {len(stablecoin_events)} events in {len(unique_txs)} unique TXs")
    print()
    
    with open("balancer_stablecoin_flashloans.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["tx_hash", "block", "token", "amount", "fee", "gas_used", "gas_price_gwei"])
        writer.writeheader()
        for event in stablecoin_events:
            writer.writerow({
                "tx_hash": event["tx_hash"],
                "block": event["block"],
                "token": event["token"],
                "amount": event["amount"],
                "fee": event["fee"],
                "gas_used": event["gas_used"],
                "gas_price_gwei": event["gas_price_gwei"],
            })
    
    print(f"Saved to balancer_stablecoin_flashloans.csv")
    print()
    
    print("Sample stablecoin flash loan TXs:")
    print("-" * 80)
    seen = set()
    for event in stablecoin_events[:20]:
        if event["tx_hash"] not in seen:
            seen.add(event["tx_hash"])
            decimals = 6 if event["token"] in ["USDC", "USDT"] else 18
            amount_fmt = event["amount"] / (10 ** decimals)
            print(f"TX: {event['tx_hash']}")
            print(f"   Block: {event['block']}, Token: {event['token']}")
            print(f"   Amount: {amount_fmt:,.2f} {event['token']}")
            print(f"   Gas Used: {event['gas_used']:,}")
            print()


if __name__ == "__main__":
    asyncio.run(main())
