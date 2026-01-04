# Security

## Audit Status

**AUDITED** - AuditAgent scan completed January 4, 2026 (Scan ID: 26).

See [audits/](audits/) directory for full reports.

## Security Contact

Report vulnerabilities via [GitHub Issues](https://github.com/igor53627/liq/issues) with the `security` label.

For sensitive disclosures, use [GitHub's private vulnerability reporting](https://github.com/igor53627/liq/security/advisories/new).

## Known Security Considerations

### 1. No Callback Return Check

**Design Decision**: The ERC-3156 callback return value is not verified.

**Rationale**: The balance check after callback is sufficient security. If the borrower doesn't repay, the transaction reverts regardless of what they return.

**Risk**: None. This is a gas optimization, not a security compromise.

### 2. USDC Hardcoded

**Design Decision**: Only USDC (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) is supported.

**Enforcement** (ERC-3156 compliant):
- `flashLoan()`: Reverts if token != USDC
- `flashFee()`: Reverts if token != USDC
- `maxFlashLoan()`: Returns 0 if token != USDC

**Implication**: 
- If USDC is paused/blacklisted, loans will fail
- No risk of token confusion attacks

### 3. Pool Balance Tracking

**Design Decision**: `poolBalance` is tracked in storage instead of calling `balanceOf()` before each loan.

**Invariant**: `poolBalance` should equal actual USDC balance.

**Maintained by**:
- `deposit()`: poolBalance += amount
- `withdraw()`: poolBalance -= amount
- Flash loan: verified via `balanceOf() >= poolBalance` after callback
- Reentrancy guard: prevents deposit/withdraw during callback
- `sync()`: owner can call to set poolBalance = actual balance

**Design Note - Direct Transfers**: The owner deposits USDC via `deposit()`, not by sending USDC directly to the contract. This design saves gas by avoiding an extra balance check. If someone accidentally sends USDC directly, the owner can call `sync()` to claim it. Any excess USDC (from direct transfers) may be extracted via flash loan before `sync()` is called - this is accepted behavior since direct transfers are not the intended deposit method.

### 4. Reentrancy Guard

**Design Decision**: Lightweight reentrancy lock (slot 2) protects poolBalance invariant.

**Protected functions**:
- `flashLoan()`: Sets lock before callback, clears after
- `deposit()`: Blocked during flash loan callback
- `withdraw()`: Blocked during flash loan callback

**Why needed**: Without the guard, a malicious receiver could call `deposit()` during callback with borrowed funds, desyncing `poolBalance` from actual balance. This would permanently brick the pool (DoS) at no cost to attacker.

**Attack prevented**:
1. Attacker borrows 1000 USDC
2. In callback, calls `deposit(1000)` with borrowed funds
3. Without guard: poolBalance becomes 2000, but only 1000 USDC exists
4. With guard: deposit() reverts with LOCKED

### 5. Owner Privileges

The owner can:
- Withdraw all USDC via `withdraw()`
- Sync pool balance via `sync()`
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
2. `poolBalance` only changes via deposit/withdraw (outside of flash loan callback)
3. Flash loans are atomic (repaid or reverted)
4. `locked` is 0 outside of flashLoan execution

## Attack Vectors Considered

| Attack | Mitigation |
|--------|------------|
| Flash loan not repaid | Balance check reverts tx |
| Reentrancy during callback | Reentrancy guard blocks deposit/withdraw |
| poolBalance desync DoS | Reentrancy guard prevents |
| Integer overflow | Practically impossible for USDC amounts |
| Token confusion | Token parameter enforced == USDC |
| Callback manipulation | Callback return ignored |
| Frontrunning | Not applicable (no price oracles) |
| Griefing | Reverts are cheap for attacker too |

## Recommendations for Auditors

1. Verify Yul assembly is correct for each function selector
2. Check storage slot assignments (0 = owner, 1 = poolBalance, 2 = locked)
3. Verify USDC address is correct mainnet address
4. Confirm balance check logic prevents theft
5. Review gas optimizations don't introduce vulnerabilities
6. Verify reentrancy guard properly protects poolBalance invariant
7. Confirm token parameter enforcement is correct in all ERC-3156 functions
