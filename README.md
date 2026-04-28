# 🦄 UniBall

**100% of trading fees auto-recycled into buybacks. No dev wallet. Built for livo.trade.**

## How it works

1. People trade UNIBALL on livo.trade
2. Livo collects 1% fee on every trade
3. Fees accumulate in Livo's feeHandler contract
4. `claimAndBuyback()` is called on the vault
5. Vault claims ETH and buys UNIBALL from Uniswap
6. 50% of tokens burned forever
7. 50% added as permanent locked liquidity
8. Repeat

The more it trades, the more gets bought back. The more that gets burned, the less supply exists. That's UniBall.

## Contracts

| Contract | Address |
|---|---|
| UNIBALL Token | `0xadb57078553d3fc355a356a6f2e81e3df5851110` |
| UniBall Vault | `0x67958F0fcA0F31EcFCd1715900E088aDe06b8764` |
| Livo feeHandler | `0xc18030d76573784fff4E6365309E1acD967506ff` |

## Key functions

- `claimAndBuyback(feeHandler)` — claims fees and executes buyback
- `pendingFees(feeHandler)` — check how much ETH is waiting to be claimed
- `setFireballMode(true, seconds)` — turbo buyback mode
- `uniBallStats()` — live stats for community transparency

## Built with

- Solidity 0.8.24
- Foundry
- OpenZeppelin
- Uniswap V2
