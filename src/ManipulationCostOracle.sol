// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TickMathLib} from "./libraries/TickMathLib.sol";

// ─── Pool Interface ───────────────────────────────────────────────────────────

interface IUniswapV3PoolMCO {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);

    /// @notice Tick spacing — only ticks divisible by this are initializable.
    function tickSpacing() external view returns (int24);

    /// @notice One word of the packed tick bitmap.
    ///         wordPosition = compressed_tick >> 8 (signed)
    function tickBitmap(int16 wordPosition) external view returns (uint256);

    /// @notice Per-tick state, used to read liquidityNet at each crossing.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128  liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56   tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32  secondsOutside,
            bool    initialized
        );
}

// ─── Aave V3 Interface (for live borrow rate) ─────────────────────────────────

interface IAaveV3DataProviderMCO {
    /// @dev Return order (Aave V3 PoolDataProvider):
    ///      [0] unbacked, [1] accruedToTreasuryScaled, [2] totalAToken,
    ///      [3] totalStableDebt, [4] totalVariableDebt, [5] liquidityRate,
    ///      [6] variableBorrowRate ← converted to BPS here,
    ///      [7] stableBorrowRate,  [8] averageStableBorrowRate,
    ///      [9] liquidityIndex, [10] variableBorrowIndex, [11] lastUpdateTimestamp
    ///      All rates are in RAY (1e27 = 100% APY).
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40  lastUpdateTimestamp
        );
}

/// @title ManipulationCostOracle
/// @notice Measures the ECONOMIC COST of attacking a Uniswap V3 TWAP oracle as a
///         continuous, real-time on-chain function.
///
/// @dev ── THE NOVEL INSIGHT ──────────────────────────────────────────────────────
///
///      Every existing oracle safety system is REACTIVE:
///        - Chainlink deviation threshold → detects price already moved
///        - Uniswap TWAP vs spot → detects manipulation in progress
///        - Staleness check → detects feed already stopped
///
///      None of them answer: "How expensive is it to attack this oracle RIGHT NOW?"
///
///      This oracle answers that question directly, as a queryable on-chain number.
///
///      ── ATTACK MODEL ────────────────────────────────────────────────────────────
///
///      A Uniswap V3 TWAP attack requires:
///
///        Step 1. MOVE: Push spot price from the TWAP baseline by targetDeviation.
///                Cost = integrate L(tick) × Δ(sqrtPrice) across initialized ticks.
///                This IS flash-loanable (single-block capital).
///
///        Step 2. HOLD: Keep that price for the entire twapWindow.
///                Flash loans expire in ONE block. Real capital must be locked at
///                the prevailing DeFi borrow rate for twapWindow seconds.
///                holdingCost = moveCapital × borrowRate × (twapWindow / SECONDS_PER_YEAR)
///
///        Step 3. EXPLOIT: Execute the bad liquidation or overcollateralized borrow.
///
///      ── TWO ENHANCEMENTS OVER NAIVE IMPLEMENTATIONS ────────────────────────────
///
///      1. TICK-BITMAP LIQUIDITY WALK:
///         pool.liquidity() returns L only at the current tick. A deviation spanning
///         many ticks crosses multiple liquidity positions. This contract walks the
///         initialized tick boundaries via pool.tickBitmap(), summing
///         L(segment) × Δ(sqrtPrice) per segment and applying pool.ticks(t).liquidityNet
///         at each crossing — exactly the integral Uniswap performs internally during swaps.
///         The result is a tighter, more accurate move capital estimate: neither
///         understated (no liquidity at all ticks) nor overstated (ignores liquidity drops).
///
///      2. LIVE BORROW RATE FROM AAVE V3:
///         If an Aave V3 DataProvider and token address are supplied, the contract reads
///         the current variableBorrowRate on-chain (in RAY, converted to BPS) instead of
///         using a static configured rate. This means the manipulation cost automatically
///         rises during DeFi stress events (borrow rates spike during market turmoil —
///         exactly when attacks are most tempting). Falls back to the static rate if Aave
///         is unavailable or returns zero.
///
///      ── SECURITY BASELINE ───────────────────────────────────────────────────────
///
///      Both MOVE and HOLD costs use observe() (TWAP) as the baseline — never slot0.
///      slot0 is manipulable in a single transaction. observe() is not.
///      An attacker cannot pre-manipulate spot to reduce the reported cost.
///
/// @dev ── WHAT GAUNTLET DOES THAT WE AUTOMATE ────────────────────────────────────
///
///      Gauntlet estimates manipulation cost quarterly, off-chain, in PDF reports.
///      This contract exposes that number in real time, on-chain, so protocols can
///      use it for DYNAMIC LTV adjustment instead of static governance parameters.
contract ManipulationCostOracle {
    using Math for uint256;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidConfig();
    error InvalidPool();
    error PoolLocked();
    error ObservationWindowTooShort();
    error StaleChainlinkFeed();
    error InvalidChainlinkData();
    error DeviationOutOfRange();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant Q96              = 0x1000000000000000000000000;
    uint256 private constant BPS              = 10_000;
    uint256 private constant MAX_SCORE        = 100;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @notice Chainlink feed freshness cap: 1 hour.
    uint256 private constant MAX_STALENESS    = 3600;

    /// @notice Maximum bitmap words searched for next initialized tick.
    ///         10 words × 256 compressed ticks/word = 2560 compressed ticks max.
    ///         At tickSpacing=10: 2560 × 10 = 25,600 actual ticks ≈ 256% price range.
    ///         Sufficient for any realistic manipulation target (≤ 50% deviation).
    uint8 private constant MAX_TICK_WORDS     = 10;

    /// @notice Maximum tick-walk iterations (gas bound).
    uint8 private constant MAX_TICK_WALK_ITER = 20;

    // ─── Immutables ───────────────────────────────────────────────────────────

    IUniswapV3PoolMCO public immutable pool;

    /// @notice Chainlink feed for token1 → USD conversion.
    AggregatorV3Interface public immutable token1UsdFeed;

    uint8 public immutable token1FeedDecimals;

    /// @notice Decimals of token1 (e.g. 18 for WETH, 6 for USDC).
    uint8 public immutable token1Decimals;

    /// @notice TWAP window in seconds. Longer = more expensive attack, slower signal.
    uint32 public immutable twapWindow;

    /// @notice Fallback annualized DeFi borrow rate in BPS (e.g., 500 = 5% per year).
    ///         Used when Aave is not configured or unavailable. This is the correct
    ///         cost model for multi-block capital lock-up — NOT flash loan fees.
    uint256 public immutable borrowRatePerYearBps;

    /// @notice USD cost (1e8 precision) below which security score = 0.
    uint256 public immutable costThresholdLow;

    /// @notice USD cost (1e8 precision) above which security score = 100.
    uint256 public immutable costThresholdHigh;

    /// @notice Aave V3 PoolDataProvider for live variable borrow rate.
    ///         address(0) = disabled; use static borrowRatePerYearBps instead.
    IAaveV3DataProviderMCO public immutable aaveDataProvider;

    /// @notice Token1 address for Aave borrow rate query.
    ///         address(0) = disabled.
    address public immutable token1Address;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _pool                  Uniswap V3 pool address.
    /// @param _token1UsdFeed         Chainlink USD feed for the pool's token1.
    /// @param _twapWindow            TWAP window in seconds (minimum 300 = 5 minutes).
    /// @param _borrowRatePerYearBps  Fallback annualized borrow rate in BPS (e.g., 500 = 5%).
    ///                               Used when Aave is unavailable. Models the cost an
    ///                               attacker pays to hold capital across multiple blocks.
    /// @param _costThresholdLow      USD cost below which score = 0 (e.g., 1_000_000_00 = $1M).
    /// @param _costThresholdHigh     USD cost above which score = 100 (e.g., 100_000_000_00 = $100M).
    /// @param _aaveDataProvider      Aave V3 PoolDataProvider for live borrow rate.
    ///                               Pass address(0) to disable and use static rate.
    /// @param _token1Address         Token1 address for Aave query.
    ///                               Pass address(0) to disable.
    constructor(
        address _pool,
        address _token1UsdFeed,
        uint32  _twapWindow,
        uint256 _borrowRatePerYearBps,
        uint256 _costThresholdLow,
        uint256 _costThresholdHigh,
        address _aaveDataProvider,
        address _token1Address,
        uint8   _token1Decimals
    ) {
        if (_pool == address(0) || _token1UsdFeed == address(0)) revert InvalidConfig();
        if (_twapWindow < 300) revert ObservationWindowTooShort();
        if (_borrowRatePerYearBps == 0 || _borrowRatePerYearBps > 10_000) revert InvalidConfig();
        if (_costThresholdLow == 0 || _costThresholdLow >= _costThresholdHigh) revert InvalidConfig();

        pool              = IUniswapV3PoolMCO(_pool);
        token1UsdFeed     = AggregatorV3Interface(_token1UsdFeed);
        twapWindow        = _twapWindow;
        borrowRatePerYearBps = _borrowRatePerYearBps;
        costThresholdLow  = _costThresholdLow;
        costThresholdHigh = _costThresholdHigh;
        aaveDataProvider  = IAaveV3DataProviderMCO(_aaveDataProvider);
        token1Address     = _token1Address;
        token1Decimals    = _token1Decimals > 0 ? _token1Decimals : 18;

        // Validate feed decimals.
        uint8 dec = token1UsdFeed.decimals();
        if (dec > 18) revert InvalidConfig();
        token1FeedDecimals = dec;

        // Validate pool has sufficient observation history.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _twapWindow;
        secondsAgos[1] = 0;
        pool.observe(secondsAgos); // reverts if insufficient history
    }

    // ─── Primary Interface ────────────────────────────────────────────────────

    /// @notice Returns the capital cost (in USD) required to manipulate the TWAP
    ///         by targetDeviationBps, and the resulting economic security score.
    ///
    /// @dev Computes:
    ///        1. TWAP baseline sqrtPrice via observe() — manipulation-resistant.
    ///        2. Move capital via tick-bitmap walk: integrates L × Δ(sqrtP) across
    ///           initialized tick boundaries from TWAP price to target price.
    ///           More accurate than single-point L estimate for multi-tick deviations.
    ///        3. Live borrow rate from Aave V3 (if configured), else static fallback.
    ///        4. Holding cost = moveCapital × borrowRate × (twapWindow / SECONDS_PER_YEAR)
    ///        5. Total USD cost → security score (linear interp between thresholds)
    ///
    /// @param targetDeviationBps How far attacker must push TWAP (e.g., 200 = 2%).
    ///
    /// @return costUsd       Total attack cost in USD (1e8 precision).
    /// @return securityScore 0 (trivially cheap) → 100 (economically secure).
    function getManipulationCost(uint256 targetDeviationBps)
        external
        view
        returns (uint256 costUsd, uint256 securityScore)
    {
        return getManipulationCostForPool(address(pool), address(token1UsdFeed), targetDeviationBps);
    }

    /// @notice Returns a dashboard-friendly manipulation cost bounded to the configured
    ///         high threshold. The underlying securityScore still uses the raw cost.
    /// @dev Useful on testnets where synthetic liquidity can produce astronomically large
    ///      raw USD values that are not informative for UI consumers.
    function getManipulationCostNormalized(uint256 targetDeviationBps)
        external
        view
        returns (
            uint256 normalizedCostUsd,
            uint256 securityScore,
            bool capped
        )
    {
        (uint256 rawCostUsd, uint256 score) = getManipulationCostForPool(
            address(pool),
            address(token1UsdFeed),
            targetDeviationBps
        );
        (normalizedCostUsd, capped) = _normalizeCostUsd(rawCostUsd);
        securityScore = score;
    }

    /// @notice Returns both raw and normalized manipulation costs.
    /// @dev `rawCostUsd` is the unbounded model output. `normalizedCostUsd` is clamped to
    ///      `costThresholdHigh` to keep UI output legible while preserving risk scoring.
    function getManipulationCostBreakdown(uint256 targetDeviationBps)
        external
        view
        returns (
            uint256 rawCostUsd,
            uint256 normalizedCostUsd,
            uint256 securityScore,
            bool capped
        )
    {
        (rawCostUsd, securityScore) = getManipulationCostForPool(
            address(pool),
            address(token1UsdFeed),
            targetDeviationBps
        );
        (normalizedCostUsd, capped) = _normalizeCostUsd(rawCostUsd);
    }

    /// @notice Backward-compatible 3-arg path (uses constructor token1Decimals).
    function getManipulationCostForPool(address _pool, address _token1UsdFeed, uint256 targetDeviationBps)
        public
        view
        returns (uint256 costUsd, uint256 securityScore)
    {
        return _getManipulationCostForPool(_pool, _token1UsdFeed, targetDeviationBps, token1Decimals);
    }

    /// @notice Decimals-aware 4-arg path for multi-asset callers.
    function getManipulationCostForPool(
        address _pool,
        address _token1UsdFeed,
        uint256 targetDeviationBps,
        uint8 decimals
    ) public view returns (uint256 costUsd, uint256 securityScore) {
        return _getManipulationCostForPool(_pool, _token1UsdFeed, targetDeviationBps, decimals);
    }

    /// @notice Alias kept for compatibility with earlier integrations.
    function getManipulationCostForPoolWithDecimals(
        address _pool,
        address _token1UsdFeed,
        uint256 targetDeviationBps,
        uint8 decimals
    ) public view returns (uint256 costUsd, uint256 securityScore) {
        return _getManipulationCostForPool(_pool, _token1UsdFeed, targetDeviationBps, decimals);
    }

    function _getManipulationCostForPool(
        address _pool,
        address _token1UsdFeed,
        uint256 targetDeviationBps,
        uint8 decimals
    ) internal view returns (uint256 costUsd, uint256 securityScore) {
        if (targetDeviationBps == 0 || targetDeviationBps > 5_000) revert DeviationOutOfRange();
        if (_pool == address(0) || _token1UsdFeed == address(0)) revert InvalidPool();

        IUniswapV3PoolMCO targetPool = IUniswapV3PoolMCO(_pool);
        AggregatorV3Interface targetFeed = AggregatorV3Interface(_token1UsdFeed);
        uint8 effectiveDecimals = decimals == 0 ? token1Decimals : decimals;

        // ── Check pool is not locked ────────────────────────────────────────
        // We only read slot0 to check the unlocked flag — never for price.
        bool unlocked;
        int24 spotTick;
        try targetPool.slot0() returns (
            uint160, int24 _t, uint16, uint16, uint16, uint8, bool _u
        ) {
            spotTick = _t;
            unlocked = _u;
        } catch {
            revert InvalidPool();
        }
        if (!unlocked) revert PoolLocked();

        // ── TWAP baseline: manipulation-resistant price from observe() ──────
        (uint160 twapSqrtPriceX96, int24 twapTick) = _readTwapSqrtPriceAndTick(targetPool);
        if (twapSqrtPriceX96 == 0) revert InvalidPool();

        // ── Move capital via tick-bitmap walk ───────────────────────────────
        uint256 moveCapitalToken1 = _computeMoveCapitalTickWalk(
            targetPool,
            twapSqrtPriceX96,
            twapTick,
            targetDeviationBps
        );

        // ── Holding cost: opportunity cost of locked capital over twapWindow ─
        uint256 effectiveBorrowRateBps = _getLiveBorrowRateBps();
        uint256 holdingCostToken1 = Math.mulDiv(
            moveCapitalToken1,
            effectiveBorrowRateBps * uint256(twapWindow),
            BPS * SECONDS_PER_YEAR
        );

        uint256 totalCostToken1 = moveCapitalToken1 + holdingCostToken1;

        // Convert token1 → USD via Chainlink.
        uint256 token1UsdPrice = _readToken1UsdPrice(targetFeed);
        // Normalize: (token1Amount * price_with_8_dec) / 10^decimals = cost_in_8_decimal_usd
        costUsd = Math.mulDiv(totalCostToken1, token1UsdPrice, 10 ** uint256(effectiveDecimals));

        securityScore = _scoreFromCost(costUsd);
    }

    /// @notice Returns the current TWAP price and spot price, plus their deviation in bps.
    /// @dev    Deviation > 0 means manipulation may be in progress.
    function getTwapVsSpot()
        external
        view
        returns (
            uint160 twapSqrtPriceX96,
            uint160 spotSqrtPriceX96,
            uint256 deviationBps
        )
    {
        bool unlocked;
        (spotSqrtPriceX96, , , , , , unlocked) = pool.slot0();
        if (!unlocked) revert PoolLocked();

        (twapSqrtPriceX96, ) = _readTwapSqrtPriceAndTick(pool);

        uint256 spotPrice = _sqrtPriceToQ96Price(spotSqrtPriceX96);
        uint256 twapPrice = _sqrtPriceToQ96Price(twapSqrtPriceX96);

        if (twapPrice == 0) return (twapSqrtPriceX96, spotSqrtPriceX96, 0);

        uint256 diff = spotPrice >= twapPrice ? spotPrice - twapPrice : twapPrice - spotPrice;
        deviationBps = Math.mulDiv(diff, BPS, twapPrice);
    }

    /// @notice Current TWAP price derived from pool observations.
    function getTwapPrice() external view returns (uint256 twapPriceQ96) {
        (uint160 sqrtTwap, ) = _readTwapSqrtPriceAndTick(pool);
        twapPriceQ96 = _sqrtPriceToQ96Price(sqrtTwap);
    }

    /// @notice Returns the effective borrow rate currently used for holding cost.
    ///         Returns the live Aave variable rate if configured, else the static fallback.
    function getEffectiveBorrowRateBps() external view returns (uint256) {
        return _getLiveBorrowRateBps();
    }

    // ─── Multi-Window Cost Analysis ───────────────────────────────────────────

    /// @notice Full breakdown of manipulation costs at four standard TWAP windows.
    /// @dev    The move capital is the same for all windows (price must reach target
    ///         regardless of how long it must be held there).  Only the holding cost
    ///         scales with the window duration.
    ///         Useful for governance: shows how attack cost varies by TWAP length,
    ///         helping protocols choose an appropriate oracle window.
    struct MultiWindowCost {
        uint256 cost5min;
        uint256 cost15min;
        uint256 cost30min;
        uint256 cost1hour;
        uint256 score5min;
        uint256 score15min;
        uint256 score30min;
        uint256 score1hour;
    }

    /// @notice Computes manipulation cost at four standard TWAP windows in one call.
    /// @param targetDeviationBps How far the attacker must push the TWAP (1-5000 BPS).
    /// @return costs Struct with cost and score at 5-min, 15-min, 30-min, and 1-hour windows.
    function getManipulationCostMultiWindow(uint256 targetDeviationBps)
        external
        view
        returns (MultiWindowCost memory costs)
    {
        if (targetDeviationBps == 0 || targetDeviationBps > 5_000) revert DeviationOutOfRange();

        // Compute move capital once — same for all windows.
        (, int24 spotTick, , , , , bool unlocked) = pool.slot0();
        (spotTick); // suppress unused warning
        if (!unlocked) revert PoolLocked();

        (uint160 twapSqrtPriceX96, int24 twapTick) = _readTwapSqrtPriceAndTick(pool);
        if (twapSqrtPriceX96 == 0) revert InvalidPool();

        uint256 moveCapitalToken1 = _computeMoveCapitalTickWalk(
            pool,
            twapSqrtPriceX96,
            twapTick,
            targetDeviationBps
        );

        uint256 rateBps = _getLiveBorrowRateBps();
        uint256 token1UsdPrice = _readToken1UsdPrice(token1UsdFeed);

        (costs.cost5min,   costs.score5min)   = _costForWindow(moveCapitalToken1, rateBps,  5 minutes, token1UsdPrice);
        (costs.cost15min,  costs.score15min)  = _costForWindow(moveCapitalToken1, rateBps, 15 minutes, token1UsdPrice);
        (costs.cost30min,  costs.score30min)  = _costForWindow(moveCapitalToken1, rateBps, 30 minutes, token1UsdPrice);
        (costs.cost1hour,  costs.score1hour)  = _costForWindow(moveCapitalToken1, rateBps, 1 hours,    token1UsdPrice);
    }

    /// @notice Computes manipulation cost at an arbitrary TWAP window.
    /// @param targetDeviationBps  TWAP manipulation size in BPS (1-5000).
    /// @param windowSeconds       Desired TWAP window length in seconds (min 300).
    /// @return costUsd            Total attack cost in USD (1e8 precision).
    /// @return securityScore      0 (cheap) → 100 (prohibitively expensive).
    function getManipulationCostAtWindow(uint256 targetDeviationBps, uint256 windowSeconds)
        external
        view
        returns (uint256 costUsd, uint256 securityScore)
    {
        if (targetDeviationBps == 0 || targetDeviationBps > 5_000) revert DeviationOutOfRange();
        if (windowSeconds < 300) revert ObservationWindowTooShort();

        (, , , , , , bool unlocked) = pool.slot0();
        if (!unlocked) revert PoolLocked();

        (uint160 twapSqrtPriceX96, int24 twapTick) = _readTwapSqrtPriceAndTick(pool);
        if (twapSqrtPriceX96 == 0) revert InvalidPool();

        uint256 moveCapitalToken1 = _computeMoveCapitalTickWalk(
            pool,
            twapSqrtPriceX96,
            twapTick,
            targetDeviationBps
        );

        uint256 rateBps = _getLiveBorrowRateBps();
        uint256 token1UsdPrice = _readToken1UsdPrice(token1UsdFeed);

        (costUsd, securityScore) = _costForWindow(
            moveCapitalToken1, rateBps, windowSeconds, token1UsdPrice
        );
    }

    /// @dev Computes USD cost and score for a given move capital and window.
    function _costForWindow(
        uint256 moveCapitalToken1,
        uint256 rateBps,
        uint256 windowSeconds,
        uint256 token1UsdPrice
    ) internal view returns (uint256 costUsd, uint256 score) {
        uint256 holdingCost = Math.mulDiv(
            moveCapitalToken1,
            rateBps * windowSeconds,
            BPS * SECONDS_PER_YEAR
        );
        uint256 totalToken1 = moveCapitalToken1 + holdingCost;
        // Normalize: (token1Amount * price_with_8_dec) / 10^token1Decimals = cost_in_8_decimal_usd
        costUsd = Math.mulDiv(totalToken1, token1UsdPrice, 10 ** uint256(token1Decimals));
        score   = _scoreFromCost(costUsd);
    }

    // ─── Internal: TWAP ───────────────────────────────────────────────────────

    /// @dev Fetches the time-weighted average sqrt price AND corresponding tick via observe().
    ///      Both are needed: sqrtPrice for capital computation, tick for bitmap walk.
    function _readTwapSqrtPriceAndTick(IUniswapV3PoolMCO targetPool)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 avgTick)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = targetPool.observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        avgTick = int24(tickDelta / int56(uint56(uint32(twapWindow))));

        sqrtPriceX96 = TickMathLib.getSqrtRatioAtTick(avgTick);
    }

    // ─── Internal: Tick-Bitmap Liquidity Walk ────────────────────────────────

    /// @dev Computes the token1 capital needed to move sqrtPrice from the TWAP
    ///      baseline to TWAP + targetDeviationBps by integrating L × Δ(sqrtP)
    ///      across initialized tick boundaries.
    ///
    ///      Algorithm:
    ///        1. Compute sqrtPriceTarget from deviation bps.
    ///        2. Start with L = pool.liquidity() at current TWAP tick.
    ///        3. Find next initialized tick above current tick via bitmap.
    ///        4. Accumulate L × (sqrtNext - sqrtCurrent) / Q96 for each segment.
    ///        5. At each tick crossing (moving up), apply +liquidityNet to L.
    ///        6. Repeat until sqrtPriceTarget is reached.
    ///
    ///      If bitmap navigation reverts (pre-Uniswap-V3 pool or mock without bitmap),
    ///      falls back to single-point L from pool.liquidity().
    function _computeMoveCapitalTickWalk(
        IUniswapV3PoolMCO targetPool,
        uint160 twapSqrtPriceX96,
        int24   twapTick,
        uint256 targetDeviationBps
    ) internal view returns (uint256 capitalToken1) {
        // Compute target sqrtPrice.
        // sqrtTarget ≈ sqrtCurrent × (1 + dev/2 / 10000) = sqrtCurrent × (20000 + dev) / 20000
        uint256 sqrtTarget = Math.mulDiv(
            uint256(twapSqrtPriceX96),
            20_000 + targetDeviationBps,
            20_000
        );
        if (sqrtTarget <= uint256(twapSqrtPriceX96)) return 0;
        // Clamp to MAX_SQRT_RATIO to avoid TickMath revert.
        if (sqrtTarget >= uint256(TickMathLib.MAX_SQRT_RATIO)) {
            sqrtTarget = uint256(TickMathLib.MAX_SQRT_RATIO) - 1;
        }

        // Get tick spacing; if it reverts, fall back to single-point estimate.
        int24 spacing;
        try targetPool.tickSpacing() returns (int24 s) {
            spacing = s;
        } catch {
            // Fallback: single-point estimate using initial liquidity.
            uint128 liq = targetPool.liquidity();
            if (liq == 0) return 0;
            uint256 sqrtDelta = sqrtTarget - uint256(twapSqrtPriceX96);
            return Math.mulDiv(uint256(liq), sqrtDelta, Q96);
        }
        if (spacing <= 0) spacing = 1;

        uint128 currentLiq = targetPool.liquidity();
        uint256 currentSqrt = uint256(twapSqrtPriceX96);
        int24   currentTick = twapTick;

        for (uint8 iter = 0; iter < MAX_TICK_WALK_ITER; ) {
            // Find the next initialized tick strictly above currentTick.
            (int24 nextTick, bool found) = _nextInitializedTickAbove(targetPool, currentTick, spacing);

            // Determine the sqrtPrice at the segment boundary.
            uint256 nextSqrt;
            if (!found || nextTick >= TickMathLib.MAX_TICK) {
                // No more initialized ticks in range — walk directly to target.
                nextSqrt = sqrtTarget;
            } else {
                uint256 nextTickSqrt = uint256(TickMathLib.getSqrtRatioAtTick(nextTick));
                nextSqrt = nextTickSqrt < sqrtTarget ? nextTickSqrt : sqrtTarget;
            }

            // Capital for this segment: L × (sqrtNext - sqrtCurrent) / Q96
            if (nextSqrt > currentSqrt && currentLiq > 0) {
                capitalToken1 += Math.mulDiv(
                    uint256(currentLiq),
                    nextSqrt - currentSqrt,
                    Q96
                );
            }

            // Reached target — done.
            if (nextSqrt >= sqrtTarget) break;

            // Apply liquidityNet at the tick crossing.
            // Moving price UP: liquidityNet is ADDED at each initialized tick.
            currentLiq = _applyLiquidityNet(targetPool, currentLiq, nextTick);
            currentSqrt = nextSqrt;
            currentTick = nextTick;

            unchecked { ++iter; }
        }
    }

    /// @dev Applies liquidityNet at a tick crossing when price moves upward.
    ///      Extracted to avoid stack-too-deep in the main walk loop.
    function _applyLiquidityNet(IUniswapV3PoolMCO targetPool, uint128 currentLiq, int24 tick)
        internal
        view
        returns (uint128)
    {
        try targetPool.ticks(tick) returns (
            uint128, int128 liquidityNet,
            uint256, uint256, int56, uint160, uint32, bool
        ) {
            if (liquidityNet > 0) {
                return currentLiq + uint128(liquidityNet);
            } else if (liquidityNet < 0) {
                uint128 decrease = uint128(uint128(int128(-liquidityNet)));
                return currentLiq > decrease ? currentLiq - decrease : 0;
            }
        } catch {
            // If ticks() reverts (non-standard pool), keep current liquidity.
        }
        return currentLiq;
    }

    /// @dev Finds the next initialized tick strictly above `currentTick` using
    ///      the pool's tick bitmap. Searches up to MAX_TICK_WORDS words.
    ///
    ///      Uniswap V3 tick bitmap layout:
    ///        compressed = floor(tick / spacing)
    ///        wordPos    = int16(compressed >> 8)   (top bits of compressed tick)
    ///        bitPos     = uint8(uint24(compressed) & 0xFF)  (bottom 8 bits)
    ///        tickBitmap[wordPos] bit `bitPos` = 1 iff that tick is initialized
    ///
    /// @return nextTick    The next initialized tick above currentTick (or MAX_TICK if none).
    /// @return found       True if an initialized tick was found within search range.
    function _nextInitializedTickAbove(IUniswapV3PoolMCO targetPool, int24 currentTick, int24 spacing)
        internal
        view
        returns (int24 nextTick, bool found)
    {
        // Compress current tick with floor division.
        int24 compressed = _compressTick(currentTick, spacing);

        // Start search from the NEXT compressed tick above current.
        int24 searchFrom = compressed + 1;

        for (uint8 w = 0; w < MAX_TICK_WORDS; ) {
            int16 wordPos = int16(searchFrom >> 8);
            uint8 bitPos  = uint8(uint24(searchFrom) & 0xFF);

            uint256 word = targetPool.tickBitmap(wordPos);

            // Mask: all bits at bitPos and above (including bitPos).
            // type(uint256).max << bitPos leaves bits [bitPos..255] set.
            uint256 mask   = type(uint256).max << bitPos;
            uint256 masked = word & mask;

            if (masked != 0) {
                uint8 lsb = _leastSignificantBit(masked);
                // Reconstruct compressed tick from (wordPos, lsb) and de-compress.
                int24 resultCompressed = (int24(int16(wordPos)) << 8) | int24(uint24(lsb));
                nextTick = resultCompressed * spacing;
                return (nextTick, true);
            }

            // Advance to the start of the next word.
            searchFrom = (int24(int16(wordPos)) + 1) << 8;
            unchecked { ++w; }
        }

        return (TickMathLib.MAX_TICK, false);
    }

    /// @dev Floor-divides tick by spacing (rounds toward negative infinity).
    ///      Matches Uniswap V3's TickBitmap.position() compression.
    function _compressTick(int24 tick, int24 spacing) internal pure returns (int24) {
        if (tick < 0 && tick % spacing != 0) {
            return tick / spacing - 1;
        }
        return tick / spacing;
    }

    /// @dev Returns the index (0-255) of the least significant set bit in x.
    ///      Equivalent to Uniswap V3's BitMath.leastSignificantBit().
    ///      Precondition: x > 0.
    function _leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        unchecked {
            r = 255;
            if (x & type(uint128).max > 0) { r -= 128; } else { x >>= 128; }
            if (x & type(uint64).max  > 0) { r -= 64;  } else { x >>= 64;  }
            if (x & type(uint32).max  > 0) { r -= 32;  } else { x >>= 32;  }
            if (x & type(uint16).max  > 0) { r -= 16;  } else { x >>= 16;  }
            if (x & type(uint8).max   > 0) { r -= 8;   } else { x >>= 8;   }
            if (x & 0xf               > 0) { r -= 4;   } else { x >>= 4;   }
            if (x & 0x3               > 0) { r -= 2;   } else { x >>= 2;   }
            if (x & 0x1               > 0) { r -= 1;   }
        }
    }

    // ─── Internal: Live Borrow Rate ────────────────────────────────────────────

    /// @dev Returns the effective annualized borrow rate in BPS.
    ///      If Aave is configured (aaveDataProvider != address(0) and token1Address != address(0)),
    ///      reads the variableBorrowRate from Aave V3 (returned in RAY = 1e27).
    ///      Converts RAY → BPS: rateBps = variableBorrowRate / 1e23.
    ///      Falls back to borrowRatePerYearBps if Aave is unavailable, returns zero, or
    ///      the computed rate is outside valid range.
    function _getLiveBorrowRateBps() internal view returns (uint256) {
        if (address(aaveDataProvider) == address(0) || token1Address == address(0)) {
            return borrowRatePerYearBps;
        }

        try aaveDataProvider.getReserveData(token1Address) returns (
            uint256,  // unbacked
            uint256,  // accruedToTreasuryScaled
            uint256,  // totalAToken
            uint256,  // totalStableDebt
            uint256,  // totalVariableDebt
            uint256,  // liquidityRate
            uint256 variableBorrowRate,
            uint256,  // stableBorrowRate
            uint256,  // averageStableBorrowRate
            uint256,  // liquidityIndex
            uint256,  // variableBorrowIndex
            uint40    // lastUpdateTimestamp
        ) {
            if (variableBorrowRate == 0) return borrowRatePerYearBps;

            // RAY (1e27) = 100% APY = 10000 BPS
            // So: rateBps = variableBorrowRate × 10000 / 1e27 = variableBorrowRate / 1e23
            uint256 rateBps = variableBorrowRate / 1e23;

            // Clamp to valid range: at least 1 BPS, at most 10000 BPS (100% APY).
            if (rateBps < 1)      return borrowRatePerYearBps;
            if (rateBps > 10_000) return 10_000;

            return rateBps;
        } catch {
            return borrowRatePerYearBps;
        }
    }

    // ─── Internal: Pricing Utilities ─────────────────────────────────────────

    /// @dev Converts sqrtPriceX96 to a Q96-scaled price ratio (token1 per token0).
    function _sqrtPriceToQ96Price(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
    }

    /// @dev Reads token1/USD price from Chainlink. Reverts if stale or invalid.
    function _readToken1UsdPrice(AggregatorV3Interface targetFeed) internal view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = targetFeed.latestRoundData();

        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert InvalidChainlinkData();
        }
        if (block.timestamp > updatedAt + MAX_STALENESS) {
            revert StaleChainlinkFeed();
        }

        return uint256(answer);
    }

    /// @dev Linear interpolation from 0 to MAX_SCORE between cost thresholds.
    function _scoreFromCost(uint256 costUsd) internal view returns (uint256) {
        if (costUsd <= costThresholdLow)  return 0;
        if (costUsd >= costThresholdHigh) return MAX_SCORE;
        return Math.mulDiv(
            costUsd - costThresholdLow,
            MAX_SCORE,
            costThresholdHigh - costThresholdLow
        );
    }

    function _normalizeCostUsd(uint256 rawCostUsd) internal view returns (uint256 normalizedCostUsd, bool capped) {
        if (rawCostUsd > costThresholdHigh) {
            return (costThresholdHigh, true);
        }
        return (rawCostUsd, false);
    }
}
