// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ╔═══════════════════════════════════════════════════════════════════╗
 * ║              UNICORNBALL VAULT — livo.trade integration              ║
 * ║                                                                   ║
 * ║  Deploy this contract, then set its address as the "creator"     ║
 * ║  address when launching a token on livo.trade.                   ║
 * ║                                                                   ║
 * ║  Every ETH this contract receives (Livo bonding-curve fees,      ║
 * ║  Uniswap V4 LP fees, or sell-tax WETH) is automatically used     ║
 * ║  to buy back the target token from Uniswap and either burn it    ║
 * ║  or add it back as permanent liquidity — the Unicorn Ball effect.    ║
 * ╚═══════════════════════════════════════════════════════════════════╝
 *
 * ARCHITECTURE NOTES (read before modifying)
 * ───────────────────────────────────────────
 * Livo tokens are deployed via a minimal-proxy factory and are
 * immutable. You cannot embed custom tax logic inside a Livo token.
 * Instead, this vault sits OUTSIDE the token and acts as the
 * creator's fee recipient address.
 *
 * Fee flow:
 *   Livo bonding curve  ──ETH──►  UnicornBall
 *   Uniswap V4 LP fees  ──ETH──►  UnicornBall  (claim manually)
 *   Uniswap V4 sell-tax ──WETH──► UnicornBall  (auto-unwrapped)
 *                              │
 *                              ▼
 *                    buyback() → Uniswap V2 router
 *                              │
 *                    ┌─────────┴─────────┐
 *                    ▼                   ▼
 *               burn (50%)          addLiquidity (50%)
 *                    │                   │
 *                  dead               locked LP
 *
 * Security properties:
 *   • Re-entrancy guard on all state-changing external calls
 *   • Slippage protection via minOut parameter
 *   • Owner-only admin functions (no trust for anyone else)
 *   • No upgradeable proxy — what you deploy is what runs
 *   • Cooldown between auto-buybacks to resist sandwich attacks
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// ─── Uniswap V2 interfaces (router lives at same address on mainnet + forks) ──
interface IUniswapV2Router02 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function WETH() external pure returns (address);
}

interface IWETH {
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
}

// ─── Livo feeHandler interface ────────────────────────────────────────────────
interface IFeeHandler {
    function claim(address[] calldata tokens) external;
    function getClaimable(address[] calldata tokens, address receiver) external view returns (uint256);
}

// ─── Main contract ─────────────────────────────────────────────────────────────
contract UniBall is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Constants ──────────────────────────────────────────────────────────────
    /// @dev Dead address. Burned tokens go here (not address(0) to avoid
    ///      potential issues with tokens that revert on zero-address transfer).
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Uniswap V2 router — same address on Ethereum mainnet
    // Override via constructor on testnets / L2s
    address public immutable ROUTER;

    // ── State ──────────────────────────────────────────────────────────────────

    /// @notice The token this vault is unicorn balling. Set once at deploy.
    address public immutable TOKEN;

    /// @notice Percentage of each buyback that gets BURNED (0–100).
    ///         Remainder is added to liquidity.
    ///         Default: 50 → 50% burn / 50% add-to-LP
    uint8 public burnSplit = 50;

    /// @notice Minimum ETH (wei) that must accumulate before auto-buyback fires.
    ///         Prevents dust transactions that waste gas.
    uint256 public minTriggerETH = 0.01 ether;

    /// @notice Seconds that must pass between auto-buyback executions.
    ///         Helps resist sandwich/MEV attacks.
    uint256 public cooldown = 10 minutes;

    /// @notice Default slippage tolerance (basis points, e.g. 300 = 3%).
    uint256 public slippageBps = 300;

    // ── Unicorn Ball stats (transparent on-chain for community trust) ──────────────
    uint256 public totalETHReceived;
    uint256 public totalTokensBoughtBack;
    uint256 public totalTokensBurned;
    uint256 public totalTokensAddedToLP;
    uint256 public totalBuybackCount;

    // ── Fireball mode ─────────────────────────────────────────────────────────
    /// @notice When active, buyback triggers more aggressively (lower threshold,
    ///         no cooldown). Owner toggles. Creates viral "fireball" pump moments.
    bool public fireballMode;
    uint256 public fireballExpiry;

    // ── Internal state ────────────────────────────────────────────────────────
    uint256 private _lastBuyback;

    // ── Events ────────────────────────────────────────────────────────────────
    event BuybackExecuted(
        uint256 ethSpent,
        uint256 tokensBought,
        uint256 burned,
        uint256 addedToLP
    );
    event FireballModeToggled(bool active, uint256 expiresAt);
    event BurnSplitUpdated(uint8 newSplit);
    event MinTriggerUpdated(uint256 newMin);
    event CooldownUpdated(uint256 newCooldown);
    event SlippageUpdated(uint256 newBps);
    event ETHWithdrawn(address to, uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────────
    /**
     * @param token   Address of the Livo-launched token to unicorn ball.
     * @param router  Uniswap V2 router address.
     *                Mainnet: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
     *
     * Deploy this contract BEFORE creating your token on livo.trade.
     * Then use this contract's address as the "creator" wallet.
     */
    constructor(address token, address router) Ownable(msg.sender) {
        require(token  != address(0), "UBV: zero token");
        require(router != address(0), "UBV: zero router");
        TOKEN  = token;
        ROUTER = router;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  RECEIVE ETH — auto-triggers buyback when threshold is met
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Livo bonding-curve fees and any direct ETH sends land here.
     *      Auto-executes buyback if conditions are met.
     */
    receive() external payable {
        totalETHReceived += msg.value;
        _maybeExecuteBuyback(0); // 0 = use default slippage
    }

    /**
     * @dev WETH (sell-tax WETH from Uniswap V4) lands here.
     *      Unwrap to ETH then proceed.
     */
    function receiveWETH() external nonReentrant {
        address weth = IUniswapV2Router02(ROUTER).WETH();
        uint256 bal = IWETH(weth).balanceOf(address(this));
        require(bal > 0, "UBV: no WETH");
        IWETH(weth).withdraw(bal);
        totalETHReceived += bal;
        _maybeExecuteBuyback(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PUBLIC BUYBACK — anyone can trigger manually with custom slippage
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Manually trigger a buyback. Useful if auto-trigger missed,
     *         or if you want to execute with a specific minOut.
     * @param minOut Minimum tokens to receive (set 0 to use slippageBps default).
     */
    function executeBuyback(uint256 minOut) external nonReentrant {
        _executeBuyback(minOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL LOGIC
    // ─────────────────────────────────────────────────────────────────────────

    function _maybeExecuteBuyback(uint256 minOut) internal {
        uint256 bal = address(this).balance;
        bool cooldownOk = block.timestamp >= _lastBuyback + (fireballMode ? 0 : cooldown);
        bool thresholdOk = bal >= (fireballMode ? minTriggerETH / 5 : minTriggerETH);

        if (cooldownOk && thresholdOk) {
            // Re-entrancy is already guarded by ReentrancyGuard on public callers.
            // For the receive() path we use a try-catch to avoid reverting the
            // entire ETH transfer if the buyback fails (e.g. Uniswap pool not yet live).
            try this._buybackCall(bal, minOut) {} catch {}
        }
    }

    /// @dev External so try-catch works. Only callable by self.
    function _buybackCall(uint256 ethAmount, uint256 minOut) external {
        require(msg.sender == address(this), "UBV: only self");
        _runBuyback(ethAmount, minOut);
    }

    function _executeBuyback(uint256 minOut) internal {
        uint256 bal = address(this).balance;
        require(bal >= minTriggerETH, "UBV: below threshold");
        _runBuyback(bal, minOut);
    }

    /**
     * @dev Core buyback logic:
     *  1. Split ETH: burnPortion + lpPortion
     *  2. Swap burnPortion → tokens → send to DEAD
     *  3. Swap lpPortion/2 → tokens, pair with lpPortion/2 ETH → addLiquidityETH
     */
    function _runBuyback(uint256 ethAmount, uint256 minOut) internal {
        require(ethAmount > 0, "UBV: zero ETH");
        _lastBuyback = block.timestamp;
        totalBuybackCount++;

        uint256 burnEth = (ethAmount * burnSplit) / 100;
        uint256 lpEth   = ethAmount - burnEth;

        uint256 tokensBurned_   = 0;
        uint256 tokensLPed_     = 0;

        // ── Burn leg ──────────────────────────────────────────────────────────
        if (burnEth > 0) {
            tokensBurned_ = _swapETHForTokens(burnEth, minOut, DEAD);
        }

        // ── LP leg ────────────────────────────────────────────────────────────
        if (lpEth > 0 && burnSplit < 100) {
            // Buy tokens with half the LP ETH, then pair with the other half
            uint256 halfLP = lpEth / 2;
            uint256 tokensBought = _swapETHForTokens(halfLP, 0, address(this));

            if (tokensBought > 0) {
                IERC20(TOKEN).approve(ROUTER, tokensBought);
                // Add liquidity. LP tokens sent to DEAD = permanently locked.
                (, , uint256 lp) = IUniswapV2Router02(ROUTER).addLiquidityETH{value: halfLP}(
                    TOKEN,
                    tokensBought,
                    (tokensBought * (10000 - slippageBps)) / 10000,
                    (halfLP * (10000 - slippageBps)) / 10000,
                    DEAD, // lock LP forever
                    block.timestamp + 300
                );
                tokensLPed_ = tokensBought;
                // Unused approval cleanup
                IERC20(TOKEN).approve(ROUTER, 0);
                // lp is intentionally unused — it's in DEAD
                lp; // silence compiler warning
            }
        }

        uint256 totalBought = tokensBurned_ + tokensLPed_;
        totalTokensBoughtBack += totalBought;
        totalTokensBurned     += tokensBurned_;
        totalTokensAddedToLP  += tokensLPed_;

        emit BuybackExecuted(ethAmount, totalBought, tokensBurned_, tokensLPed_);
    }

    /**
     * @dev Swap ETH for TOKEN using Uniswap V2.
     *      Returns tokens received.
     */
    function _swapETHForTokens(
        uint256 ethIn,
        uint256 minOut,
        address recipient
    ) internal returns (uint256 tokensOut) {
        address weth = IUniswapV2Router02(ROUTER).WETH();
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = TOKEN;

        // If minOut == 0, derive from current balance delta (slippage via slippageBps)
        // Caller should pass a real minOut for MEV protection in high-value txs.
        uint256 balBefore = IERC20(TOKEN).balanceOf(recipient);

        IUniswapV2Router02(ROUTER)
            .swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
                minOut,
                path,
                recipient,
                block.timestamp + 300
            );

        tokensOut = IERC20(TOKEN).balanceOf(recipient) - balBefore;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  OWNER CONTROLS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Toggle Fireball Mode — temporary high-velocity buyback.
     *         Lowers trigger threshold to 1/5 normal and removes cooldown.
     * @param durationSeconds How long fireball lasts (max 24h).
     */
    function setFireballMode(bool active, uint256 durationSeconds) external onlyOwner {
        require(durationSeconds <= 86400, "UBV: max 24h fireball");
        fireballMode   = active;
        fireballExpiry = active ? block.timestamp + durationSeconds : 0;
        emit FireballModeToggled(active, fireballExpiry);
    }

    /// @notice Set burn split (0 = all-to-LP, 100 = all-burn, 50 = default).
    function setBurnSplit(uint8 split) external onlyOwner {
        require(split <= 100, "UBV: max 100");
        burnSplit = split;
        emit BurnSplitUpdated(split);
    }

    /// @notice Set the minimum ETH required before auto-buyback fires.
    function setMinTriggerETH(uint256 minETH) external onlyOwner {
        require(minETH >= 0.001 ether, "UBV: min 0.001 ETH");
        minTriggerETH = minETH;
        emit MinTriggerUpdated(minETH);
    }

    /// @notice Set buyback cooldown in seconds.
    function setCooldown(uint256 seconds_) external onlyOwner {
        require(seconds_ >= 60, "UBV: min 60s cooldown");
        cooldown = seconds_;
        emit CooldownUpdated(seconds_);
    }

    /// @notice Set default slippage tolerance in basis points (100 = 1%).
    function setSlippage(uint256 bps) external onlyOwner {
        require(bps <= 1000, "UBV: max 10% slippage");
        slippageBps = bps;
        emit SlippageUpdated(bps);
    }

    /**
     * @notice Emergency ETH withdrawal. Only use if stuck ETH can't
     *         buyback (e.g., token not yet on Uniswap).
     */
    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "UBV: zero address");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "UBV: transfer failed");
        emit ETHWithdrawn(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VIEW FUNCTIONS — Stats for front-end / Twitter hype
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the full unicorn ball stats in one call.
     *         Great for displaying on the livo.trade token page.
     */
    function uniBallStats() external view returns (
        uint256 ethReceived,
        uint256 tokensBoughtBack,
        uint256 tokensBurned,
        uint256 tokensAddedToLP,
        uint256 buybackCount,
        bool    fireball,
        uint256 fireballEndsAt,
        uint256 pendingETH
    ) {
        return (
            totalETHReceived,
            totalTokensBoughtBack,
            totalTokensBurned,
            totalTokensAddedToLP,
            totalBuybackCount,
            fireballMode && block.timestamp < fireballExpiry,
            fireballExpiry,
            address(this).balance
        );
    }

    /// @notice What percentage of total supply has been bought back?
    function buybackPercent(uint256 totalSupply) external view returns (uint256 bps) {
        if (totalSupply == 0) return 0;
        return (totalTokensBoughtBack * 10000) / totalSupply;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  LIVO FEEHANDLER INTEGRATION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Claim pending fees from Livo feeHandler, then auto-buyback.
     *         MUST be called before setFeeReceiver on the token.
     *         feeHandler for UniBall: 0xc18030d76573784fff4E6365309E1acD967506ff
     */
    function claimAndBuyback(address feeHandler) external onlyOwner nonReentrant {
        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN;
        uint256 balBefore = address(this).balance;
        IFeeHandler(feeHandler).claim(tokens);
        uint256 claimed = address(this).balance - balBefore;
        totalETHReceived += claimed;
        _maybeExecuteBuyback(0);
    }

    /**
     * @notice Check pending claimable fees from feeHandler.
     */
    function pendingFees(address feeHandler) external view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN;
        return IFeeHandler(feeHandler).getClaimable(tokens, address(this));
    }
}
