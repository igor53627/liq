#!/usr/bin/env python3
"""
Query Balancer V2 FlashLoan events for stablecoins using Envio HyperSync.

Requires: pip install hypersync
"""
from __future__ import annotations
import hypersync
import asyncio
import os
from typing import Optional
from datetime import datetime

BALANCER_VAULT = "0xBA12222222228d8Ba445958a75a0704d566BF2C8"

FLASHLOAN_TOPIC = "0x0d7d75e01ab95780d3cd1c8ec0dd6c2ce19e3a20427eec8bf53283b6fb8e95f0"

STABLECOINS = {
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
    "0xdac17f958d2ee523a2206206994597c13d831ec7": "USDT",
    "0x6b175474e89094c44da98b954eedeac495271d0f": "DAI",
    "0x4fabb145d64652a948d72533023f6e7a623c7c53": "BUSD",
    "0x8e870d67f660d95d5be530380d0ec0bd388289e1": "USDP",
    "0x0000000000085d4780b73119b644ae5ecd22b376": "TUSD",
    "0x853d955acef822db058eb8505911ed77f175b99e": "FRAX",
    "0x5f98805a4e8be255a32880fdec7f6728c6568ba0": "LUSD",
    "0x57ab1ec28d129707052df4df418d58a2d46d5f51": "sUSD",
    "0x1abaea1f7c830bd89acc67ec4af516284b1bc33c": "EURC",
}

STABLECOIN_TOPICS = {
    "0x000000000000000000000000" + addr[2:]: name 
    for addr, name in STABLECOINS.items()
}


async def query_flashloans(from_block: int, to_block: int | None = None):
    """Query FlashLoan events from Balancer Vault."""
    
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
                    [],
                    list(STABLECOIN_TOPICS.keys()),
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
                all_txs[tx.hash] = tx
        
        print(f"  Fetched {len(all_logs)} events so far (at block {res.next_block})...")
        
        if res.next_block >= (to_block or res.archive_height):
            break
        
        query.from_block = res.next_block
    
    return all_logs, all_txs


def decode_flashloan_log(log, txs):
    """Decode a FlashLoan event log."""
    recipient_topic = log.topics[1] if len(log.topics) > 1 else None
    token_topic = log.topics[2] if len(log.topics) > 2 else None
    
    token_name = STABLECOIN_TOPICS.get(token_topic, "Unknown")
    
    amount = 0
    fee = 0
    if log.data and len(log.data) >= 66:
        amount = int(log.data[2:66], 16)
        if len(log.data) >= 130:
            fee = int(log.data[66:130], 16)
    
    tx = txs.get(log.transaction_hash)
    gas_used = int(tx.gas_used, 16) if tx and tx.gas_used else 0
    gas_price = int(tx.gas_price, 16) if tx and tx.gas_price else 0
    
    return {
        "tx_hash": log.transaction_hash,
        "block": log.block_number,
        "token": token_name,
        "token_address": token_topic,
        "amount": amount,
        "fee": fee,
        "gas_used": gas_used,
        "gas_price_gwei": gas_price / 1e9,
        "recipient": recipient_topic,
    }


async def main():
    from_block = 20000000
    to_block = 20100000
    
    logs, txs = await query_flashloans(from_block, to_block)
    
    print(f"\n{'='*80}")
    print(f"Found {len(logs)} stablecoin FlashLoan events")
    print(f"{'='*80}\n")
    
    if not logs:
        print("No stablecoin flash loans found in this range.")
        print("Try querying all FlashLoan events (remove stablecoin filter).")
        return
    
    by_token = {}
    for log in logs:
        decoded = decode_flashloan_log(log, txs)
        token = decoded["token"]
        if token not in by_token:
            by_token[token] = []
        by_token[token].append(decoded)
    
    print("Summary by stablecoin:")
    print("-" * 60)
    for token, events in sorted(by_token.items(), key=lambda x: -len(x[1])):
        total_amount = sum(e["amount"] for e in events)
        avg_gas = sum(e["gas_used"] for e in events) / len(events) if events else 0
        print(f"  {token}: {len(events)} flash loans")
        print(f"    Total volume: {total_amount / 1e6:,.0f} (6 decimals)")
        print(f"    Avg gas used: {avg_gas:,.0f}")
        print()
    
    print("\nSample transactions:")
    print("-" * 60)
    for i, log in enumerate(logs[:10]):
        decoded = decode_flashloan_log(log, txs)
        print(f"{i+1}. TX: {decoded['tx_hash'][:20]}...")
        print(f"   Block: {decoded['block']}")
        print(f"   Token: {decoded['token']}")
        print(f"   Amount: {decoded['amount'] / 1e6:,.2f}")
        print(f"   Gas Used: {decoded['gas_used']:,}")
        print()


if __name__ == "__main__":
    asyncio.run(main())
