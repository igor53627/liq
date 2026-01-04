# Audit Responses

This document tracks responses to audit findings that are either false positives, acknowledged design decisions, or out of scope.

## AuditAgent Report - January 4, 2026 (Scan ID: 26)

### False Positives / Scanner Misunderstandings

**Finding #4: Unsafe Return Statement In Yul Block** - FALSE POSITIVE
- The `return(0x00, 0x20)` statements in Yul are intentional and correct
- They are used in deliberate branches with no intended fallthrough
- This is standard Yul pattern for returning values from function selectors

**Finding #12: Unused State Variable** - FALSE POSITIVE
- The `locked` and `USDC` variables are declared for storage layout/ABI purposes
- They are accessed via Yul assembly using slot numbers, not Solidity variable names
- The scanner doesn't recognize Yul-based access patterns

### Acknowledged Design Decisions

**Finding #5: Non-Specific Solidity Pragma Version** - ACKNOWLEDGED
- Using `^0.8.20` is acceptable as Foundry pins the compiler version
- Risk is mitigated by CI testing with specific compiler version

**Finding #6: PUSH0 Opcode Compatibility Issue** - ACKNOWLEDGED
- Contract is deployed only on Ethereum mainnet which supports Shanghai
- L2 deployment is not planned; if needed, would require recompilation

**Finding #9: ERC-3156 non-compliance (callback return value)** - ACKNOWLEDGED
- Intentional gas optimization, documented in SECURITY.md
- Balance check provides equivalent security guarantee
- Documentation updated to clarify "ERC-3156 compatible (except callback return value verification)"

**Finding #10: Permissionless deposit() has no depositor accounting** - ACKNOWLEDGED
- This is the intended design - deposits are effectively donations to the pool
- Owner controls all withdrawals
- Documented in README and SECURITY.md

**Finding #11: High Function Complexity** - ACKNOWLEDGED
- The fallback() function handles multiple selectors in Yul for gas optimization
- Complexity is inherent to the selector-dispatch pattern
- Well-documented and tested

**Finding #13/#14: Missing events for critical operations** - ACKNOWLEDGED (Issue #21 closed)
- Events were intentionally omitted to save gas in the Yul implementation
- This is a core design choice for the gas-optimized flash loan protocol
- Flash loans DO emit a `FlashLoan` event; only admin functions omit events
- Users can track deposits/withdrawals via USDC Transfer events

**Finding #15: No mechanism to rescue non-USDC tokens** - ACKNOWLEDGED
- Contract is USDC-only by design
- Adding rescue function would increase attack surface
- Users should not send non-USDC tokens to the contract

**Finding #8: Missing ERC20 return value checks** - FUTURE VERSION (Issue #20 closed)
- Valid concern for a future redeployment
- Current contract relies on USDC reverting on transfer failure (current behavior)
- Since contract is stateless (poolBalance can be re-synced via `sync()`), redeployment is low-friction
- For next version: add `if iszero(mload(0x00)) { revert(0, 0) }` after ERC20 calls

### Out of Scope (Example/Test Code)

**Finding #1: TestBorrower arbitrary lender injection** - TRACKED AS ISSUE #19
- Real vulnerability but in example/test contract, not production code
- Created issue to harden the example for safety of integrators who may copy it

**Finding #7: Unsafe ERC20 Operation Usage (TestBorrower)** - OUT OF SCOPE
- TestBorrower is example code, not production
- Would be fixed as part of Issue #19

### Acknowledged Design Decisions (Additional)

**Finding #2/#3: Excess USDC extraction via flash loan** - ACKNOWLEDGED (Issue #18 closed)
- The owner deposits USDC via `deposit()`, not by sending USDC directly to the contract
- This design saves gas by avoiding an extra balance check
- In normal operation, there should never be excess USDC (actualBalance > poolBalance)
- If someone accidentally sends USDC directly, the owner can call `sync()` to claim it
- Any excess USDC may be extracted via flash loan before `sync()` is called - this is accepted behavior

### Summary - All Issues Resolved

| Finding | Severity | Issue | Status |
|---------|----------|-------|--------|
| #2/#3: Excess USDC extraction | Medium | [#18](https://github.com/igor53627/liq/issues/18) | Closed - Design decision |
| #1: TestBorrower lender injection | High (example code) | [#19](https://github.com/igor53627/liq/issues/19) | Fixed in PR #22 |
| #8: Missing ERC20 return value checks | Info | [#20](https://github.com/igor53627/liq/issues/20) | Closed - Future version |
| #13/#14: Missing events | Best Practices | [#21](https://github.com/igor53627/liq/issues/21) | Closed - Gas optimization |
