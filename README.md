# Provably Fair VRF Multi-Round Lottery Protocol

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?style=flat-square&logo=solidity)
![Security](https://img.shields.io/badge/Security-Pull_Payments-blueviolet?style=flat-square)
![Coverage](https://img.shields.io/badge/Coverage-97.79%25-brightgreen?style=flat-square)

A secure, gas-optimized multi-round lottery protocol featuring provably fair winner selection powered by Chainlink VRF V2.5. The architecture is designed to eliminate critical system-wide Denial of Service (DoS) vectors, enforce strict reentrancy protections, and pack EVM storage contiguously for maximum gas efficiency.

## 🏗 Architecture & Security Features

### 1. Mitigating VRF Callback DoS: Pull-over-Push Payments
- **Context:** Standard reward distribution patterns push Ether rewards directly to winners inside a loop. If a winner is an un-payable contract or explicitly reverts during reception, the entire Chainlink VRF callback reverts. Because this callback is executed by the external coordinator, a single failed transfer permanently locks the entire round, freezing all player funds.
- **Implementation:** The `Lottery` contract adopts the **Pull-over-Push** architecture. The Chainlink `fulfillRandomWords` callback only calculates payouts and credits them to an internal ledger (`s_claimablePrizes`). Winners must manually claim their earnings using the external `claimPrize()` function, ensuring that failure in one transaction never cascades to block the protocol.

### 2. EVM Storage Slot Packing (Gas Optimization)
- **Context:** EVM storage writes (`SSTORE`) are extremely expensive (up to 20,000 gas per slot). Placing variables arbitrarily across a struct results in fragmented slots and redundant storage allocation.
- **Implementation:** The core `Round` structure is packed contiguously to minimize slot usage:
  ```solidity
  struct Round {
      RoundState state;       // uint8  (1 byte)
      bool refunded;          // bool   (1 byte)
      uint16 protocolFeeBps;  // uint16 (2 bytes)
      // CONTIGUOUS SLOT 1: Packs state, refunded, and protocolFeeBps together
      uint256 startTime;      // uint256 (32 bytes)
      uint256 endTime;        // uint256 (32 bytes)
      ...
  }
  ```
  This contiguous layout packs state flags directly into a single 32-byte storage slot, reducing gas usage during initialization and state transitions.

### 3. Loop Optimizations & Memory Caching
- **Memory Caching:** Critical read operations in `buyTickets()` cache storage parameters like `ticketPrice` and `maxTicketsPerPlayer` to memory variables, preventing multiple redundant `SLOAD` operations (saving 100+ gas per read).
- **Unchecked Iterations:** Loop index increments in `buyTickets()` and winner selections are wrapped in `unchecked` blocks since they are bounded by mathematical constraints and cannot overflow, maximizing gas savings.

### 4. Defense in Depth: Reentrancy Guard
- **Context:** External value transfers (Ether payouts and player refunds) expose the contract to potential callback reentrancy attacks.
- **Implementation:** The contract inherits OpenZeppelin's standard `ReentrancyGuard` module. All external state-changing withdrawal entry points (`claimPrize`, `claimRefund`, and `withdrawFees`) are protected with the `nonReentrant` modifier, enforcing strict checks-effects-interactions (CEI) semantics.

---

## 🧪 Testing & Quality Assurance

The test suite is built using **Foundry**, asserting functional invariants, cryptographic randomness, edge-case conditions, and mathematical accuracy with **97.79% line coverage**.

It features:
- **State Invariants:** Validates config setups, sequential multi-round transitions, fee accumulations, and access control.
- **Fuzzing Tests:** Leverages Foundry's fuzzing engine to subject ticket purchases to millions of boundary constraints.
- **Random Determinism Mocking:** Recreates Chainlink VRF mocks to test single-winner, multi-winner, and edge-case player pool sizes.
- **Pull-Payments Testing:** Validates robust prize claiming, multiple win accumulations, and negative withdrawal cases.

To execute the test suite:
```bash
forge test
```

To run code coverage analysis:
```bash
forge coverage
```

**Coverage Report:**
```text
╭-----------------+------------------+------------------+----------------+----------------╮
| File            | % Lines          | % Statements     | % Branches     | % Funcs        |
+=========================================================================================+
| src/Lottery.sol | 97.79% (177/181) | 97.54% (198/203) | 91.43% (32/35) | 92.31% (24/26) |
|-----------------+------------------+------------------+----------------+----------------|
| Total           | 97.79% (177/181) | 97.54% (198/203) | 91.43% (32/35) | 92.31% (24/26) |
╰-----------------+------------------+------------------+----------------+----------------╯
```
