# Security

## Audit Status

**NOT AUDITED** - Use at your own risk.

## Security Contact

Report vulnerabilities to: security@liq.protocol

## Known Security Considerations

### 1. No Callback Return Check

**Design Decision**: The ERC-3156 callback return value is not verified.

**Rationale**: The balance check after callback is sufficient security. If the borrower doesn't repay, the transaction reverts regardless of what they return.

**Risk**: None. This is a gas optimization, not a security compromise.

### 2. USDC Hardcoded

**Design Decision**: Only USDC (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) is supported.

**Implication**: 
- Token parameter in `flashLoan` is ignored
- If USDC is paused/blacklisted, loans will fail
- No risk of token confusion attacks

### 3. Pool Balance Tracking

**Design Decision**: `poolBalance` is tracked in storage instead of calling `balanceOf()` before each loan.

**Invariant**: `poolBalance` must always equal actual USDC balance.

**Maintained by**:
- `deposit()`: poolBalance += amount
- `withdraw()`: poolBalance -= amount
- Flash loan: verified via `balanceOf() >= poolBalance` after callback

**Risk**: If someone sends USDC directly to contract (not via deposit), poolBalance will be less than actual balance. This is safe - it just means extra USDC is locked until owner withdraws.

### 4. No Reentrancy Guard

**Design Decision**: No explicit reentrancy protection.

**Rationale**: The balance check is atomic. Any reentrancy that doesn't repay will fail the check.

**Scenario**: Attacker reenters during callback:
1. First loan: 1000 USDC sent out, expectedBal = 1000
2. Reentrant loan: Another 1000 sent out, but poolBalance still 1000
3. After callbacks: balance must be >= 1000
4. If attacker has 1000, first loan passes; if not, both revert

### 5. Owner Privileges

The owner can:
- Withdraw all USDC via `withdraw()`
- Rescue ETH via `rescueETH()`
- Transfer ownership

**Risk**: Centralization. Owner could rug depositors.

**Mitigation**: In production, consider:
- Multisig owner
- Timelock on withdrawals
- Or: single owner with no external deposits

### 6. Integer Overflow

**Design Decision**: No explicit overflow checks in Yul.

**Safe because**:
- Solidity 0.8.20 handles overflow in Solidity parts
- Yul arithmetic: `add`, `sub`, `mul`, `div` are unchecked
- `poolBalance` can't realistically overflow (USDC has 6 decimals, max ~79B tokens fits in uint96)
- `sub(poolBalance, amount)` in withdraw: owner-only, assumed to not withdraw more than available

### 7. Flash Loan Receiver Trust

**Assumption**: The receiver contract is trusted by whoever calls `flashLoan`.

**The contract does NOT protect against**:
- Malicious receiver stealing funds (receiver is chosen by caller)
- Receiver reverting (caller's problem)

**The contract DOES ensure**:
- Funds are returned regardless of what receiver does
- Transaction reverts if not repaid

## Invariants

1. `USDC.balanceOf(this) >= poolBalance` (always, after any tx)
2. `poolBalance` only changes via deposit/withdraw
3. Flash loans are atomic (repaid or reverted)

## Attack Vectors Considered

| Attack | Mitigation |
|--------|------------|
| Flash loan not repaid | Balance check reverts tx |
| Reentrancy | Balance check is atomic |
| Integer overflow | Practically impossible for USDC amounts |
| Token confusion | Only USDC hardcoded |
| Callback manipulation | Callback return ignored |
| Frontrunning | Not applicable (no price oracles) |
| Griefing | Reverts are cheap for attacker too |

## Recommendations for Auditors

1. Verify Yul assembly is correct for each function selector
2. Check storage slot assignments (0 = owner, 1 = poolBalance)
3. Verify USDC address is correct mainnet address
4. Confirm balance check logic prevents theft
5. Review gas optimizations don't introduce vulnerabilities
