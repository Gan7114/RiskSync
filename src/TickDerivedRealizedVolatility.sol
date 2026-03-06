// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV3PoolTDRV {
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
}

/// @title TickDerivedRealizedVolatility
/// @notice Computes on-chain realized volatility directly from Uniswap V3 tick
///         cumulative observations — without relying on round-to-round price comparison.
///
/// @dev ── THE NOVEL INSIGHT ──────────────────────────────────────────────────────
///
///      Existing DeFi protocols measure "volatility" by comparing the latest Chainlink
///      round against the previous round (N vs N-1). This has three critical problems:
///
///        1. Single data point: one period is not volatility, it's just a move.
///        2. Manipulable baseline: an attacker can influence what "previous round" is.
///        3. Stale signal: Chainlink updates infrequently (heartbeat + deviation).
///
///      This contract computes REALIZED VOLATILITY using Uniswap V3's tick observation
///      ring buffer — a continuous, append-only, on-chain time series.
///
///      ── THE MATH ─────────────────────────────────────────────────────────────────
///
///      Uniswap V3 stores: tickCumulative = Σ(currentTick × Δtime) for all seconds.
///
///      A Uniswap V3 tick is the base-1.0001 logarithm of price:
///        tick = log_{1.0001}(price)
///        → 1 tick ≈ 0.01% = 1 basis point price change
///
///      Time-weighted average tick over interval [t₀, t₁]:
///        avgTick[i] = (tickCumulative[t₁] - tickCumulative[t₀]) / (t₁ - t₀)
///
///      This avgTick IS NOT a log return — it is an average log-LEVEL.
///      The log RETURN between consecutive intervals is:
///        logReturn[i] = avgTick[i] - avgTick[i-1]
///
///      This is the correct quantity for realized variance.
///      Using levels (avgTick) instead of returns produces absurd numbers:
///      for ETH near tick 80000, variance of levels ≈ 6.4×10⁹, annualizedVol ≈ 750,000%
///      The correct realized variance uses DIFFERENCES between consecutive levels.
///
///      Realized variance over (N-1) log returns from N avg ticks:
///        variance = Σ(logReturn[i]²) / (N-1)   [units: bps²]
///
///      Annualized realized volatility:
///        annualizedVar = variance × (SECONDS_PER_YEAR / intervalSeconds)
///        annualizedVol = sqrt(annualizedVar)   [units: bps]
///        e.g., 10000 bps = 100% annualized volatility
///
///      Example verification (80% vol asset, 1-hour intervals):
///        Expected 1-hour std dev ≈ 80% × sqrt(1/8760) ≈ 0.855% ≈ 85 ticks/hour
///        If logReturns alternate ±85 ticks: variance = 85² = 7225 bps²/interval
///        annualizedVar = 7225 × 8760 = 63,291,000
///        annualizedVol = sqrt(63,291,000) ≈ 7956 bps ≈ 79.6% ✓
///
///      ── WHY THIS IS MANIPULATION-RESISTANT ──────────────────────────────────────
///
///      tickCumulative is a running sum accumulated every second by the Uniswap V3
///      observation system. To manipulate the realized volatility computed here:
///
///        - An attacker would need to hold the tick at a manipulated level for
///          (numSamples × sampleInterval) seconds — e.g., 24 hours for 24 hourly samples.
///        - The cost of this attack is exactly what ManipulationCostOracle measures.
///        - Short-lived flash loan attacks have negligible impact on the tick cumulative.
///
///      ── WHAT NO EXISTING PROTOCOL DOES ─────────────────────────────────────────
///
///      Gauntlet and Chaos Labs compute realized volatility off-chain from historical data.
///      Protocols use static risk parameters (LTV = 75%) set quarterly by governance.
///
///      This contract makes realized volatility queryable on-chain, in real time,
///      so protocols can use it to DYNAMICALLY set LTV:
///        - Low vol period → higher LTV allowed (capital efficient)
///        - High vol period → lower LTV enforced (safer)
///
///      This is the "volatility-responsive LTV" primitive that DeFi has been missing.
///
/// @dev ── IMPORTANT CAVEATS ───────────────────────────────────────────────────────
///      This computes interval-realized volatility (TWAP-interval returns), not
///      tick-by-tick high-frequency volatility. For a 1-hour sample interval, it
///      measures hourly realized vol, which is then annualized. This is appropriate
///      for lending protocol risk management (loan health is evaluated hourly, not
///      per-block). For per-block granularity, a separate indexing solution is needed.
///
///      numSamples >= 3 is enforced so we have at least 2 log returns for variance.
contract TickDerivedRealizedVolatility {

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidConfig();
    error InvalidPool();
    error TooManySamples();
    error TooFewSamples();
    error SampleIntervalTooShort();
    error InsufficientObservationHistory();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @notice Maximum number of samples to prevent unbounded gas usage.
    ///         48 samples at 1-hour intervals = 48 hours of history.
    uint8 public constant MAX_SAMPLES = 48;

    /// @notice Minimum samples: need at least 3 tick snapshots for 2 log returns.
    ///         Variance requires at least 2 data points.
    uint8 public constant MIN_SAMPLES = 3;

    /// @notice Minimum interval between samples in seconds.
    uint32 public constant MIN_SAMPLE_INTERVAL = 300; // 5 minutes

    /// @notice Maximum annualized vol in bps (1,000,000 = 10,000%) — safety cap.
    uint256 public constant MAX_VOL_BPS = 1_000_000;

    // ─── Immutables ───────────────────────────────────────────────────────────

    IUniswapV3PoolTDRV public immutable pool;

    /// @notice Seconds between each observation sample.
    uint32 public immutable sampleInterval;

    /// @notice Number of sample intervals (history depth = numSamples × sampleInterval).
    ///         Must be >= MIN_SAMPLES (3) so we compute at least 2 log returns.
    uint8 public immutable numSamples;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _pool           Uniswap V3 pool with sufficient observation cardinality.
    /// @param _sampleInterval Seconds between samples (e.g., 3600 = 1 hour).
    /// @param _numSamples     Number of intervals to average over (e.g., 24 = 24 hours).
    ///                        Must be >= 3 to compute at least 2 log returns.
    constructor(address _pool, uint32 _sampleInterval, uint8 _numSamples) {
        if (_pool == address(0)) revert InvalidConfig();
        if (_sampleInterval < MIN_SAMPLE_INTERVAL) revert SampleIntervalTooShort();
        if (_numSamples < MIN_SAMPLES) revert TooFewSamples();
        if (_numSamples > MAX_SAMPLES) revert TooManySamples();

        pool = IUniswapV3PoolTDRV(_pool);
        sampleInterval = _sampleInterval;
        numSamples = _numSamples;

        // Validate pool has sufficient observation history.
        uint32 requiredHistory = uint32(_numSamples) * _sampleInterval;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = requiredHistory;
        secondsAgos[1] = 0;
        try pool.observe(secondsAgos) {
            // success
        } catch {
            revert InsufficientObservationHistory();
        }
    }

    // ─── Primary Interface ────────────────────────────────────────────────────

    /// @notice Returns annualized realized volatility in basis points.
    ///
    /// @dev Computation:
    ///        1. Fetch (numSamples + 1) observation points from the pool.
    ///        2. For each of N intervals: avgTick[i] = ΔtickCumulative / sampleInterval
    ///           (this is the time-weighted average log-LEVEL for interval i)
    ///        3. Compute (N-1) log RETURNS: logReturn[i] = avgTick[i] - avgTick[i-1]
    ///           (differences between consecutive avg ticks = actual price movements)
    ///        4. realizedVariance = Σ(logReturn[i]²) / (N-1)   [bps²]
    ///        5. annualizedVariance = realizedVariance × SECONDS_PER_YEAR / sampleInterval
    ///        6. annualizedVol = sqrt(annualizedVariance)        [bps]
    ///
    ///      Why N-1 returns from N avg ticks?
    ///        We fetch (numSamples+1) tick snapshots, giving numSamples avg ticks.
    ///        Consecutive differences give (numSamples-1) log returns.
    ///        This is standard realized variance estimation.
    ///
    ///      Example interpretation:
    ///        annualizedVolBps = 10000 → 100% annualized vol (very high, crypto norm)
    ///        annualizedVolBps = 5000  → 50% annualized vol (typical for BTC/ETH)
    ///        annualizedVolBps = 500   → 5% annualized vol (stable, stablecoin-like)
    ///
    /// @return annualizedVolBps Annualized realized volatility in basis points.
    function getRealizedVolatility() external view returns (uint256 annualizedVolBps) {
        return getRealizedVolatilityForPool(address(pool), sampleInterval, numSamples);
    }

    /// @notice Returns annualized realized volatility in basis points for ANY arbitrary pool
    ///         using custom interval and sample count.
    /// @param _pool          Address of the Uniswap V3 pool to analyze.
    /// @param interval       Seconds between each observation sample.
    /// @param nSamples       Number of intervals to average over.
    function getRealizedVolatilityForPool(address _pool, uint32 interval, uint8 nSamples) public view returns (uint256 annualizedVolBps) {
        if (_pool == address(0)) revert InvalidConfig();
        if (interval < MIN_SAMPLE_INTERVAL) revert SampleIntervalTooShort();
        if (nSamples < MIN_SAMPLES) revert TooFewSamples();
        if (nSamples > MAX_SAMPLES) revert TooManySamples();

        IUniswapV3PoolTDRV targetPool = IUniswapV3PoolTDRV(_pool);

        uint32 n = uint32(nSamples);

        // Fetch (n+1) tick snapshots → n avg ticks → (n-1) log returns.
        // secondsAgos: [n*interval, (n-1)*interval, ..., interval, 0]
        uint32[] memory secondsAgos = new uint32[](n + 1);
        for (uint32 i = 0; i <= n; ) {
            secondsAgos[i] = (n - i) * interval;
            unchecked { ++i; }
        }

        int56[] memory tickCumulatives;
        try targetPool.observe(secondsAgos) returns (int56[] memory tcs, uint160[] memory) {
            tickCumulatives = tcs;
        } catch {
            revert InsufficientObservationHistory();
        }

        // Step 1: Compute N avg ticks from (N+1) cumulative snapshots.
        //         avgTick[i] = (tickCumulatives[i+1] - tickCumulatives[i]) / interval
        //         Note: tickCumulatives[i] corresponds to secondsAgo = (n-i)*interval
        //         tickCumulatives[i+1] corresponds to secondsAgo = (n-i-1)*interval
        //         So avgTick[i] is the TWAP tick from (n-i)*interval to (n-i-1)*interval ago.
        //         avgTick[n-1] is the most recent interval.
        int256[] memory avgTicks = new int256[](n);
        for (uint32 i = 0; i < n; ) {
            int56 rawDelta = tickCumulatives[i + 1] - tickCumulatives[i];
            avgTicks[i] = int256(rawDelta) / int256(uint256(interval));
            unchecked { ++i; }
        }

        // Step 2: Compute (N-1) log returns as differences between consecutive avg ticks.
        //         logReturn[i] = avgTick[i+1] - avgTick[i]
        //         This is the actual price movement between interval i and i+1.
        //         Using differences (returns) not levels is essential: avg ticks for ETH
        //         hover around 80000, so squaring levels gives ~6.4×10⁹ — meaningless.
        //         Differences are the actual per-interval volatility, typically ±10-200 ticks.
        uint256 numReturns = uint256(n) - 1; // always >= 2 because numSamples >= 3
        uint256 sumSquaredReturns = 0;

        for (uint256 i = 0; i < numReturns; ) {
            int256 logReturn = avgTicks[i + 1] - avgTicks[i];

            // logReturn is bounded: max tick diff per interval is MAX_TICK = 887272
            // logReturn² ≤ 887272² ≈ 7.87×10¹¹ (fits comfortably in uint256)
            // sumSquaredReturns over MAX_SAMPLES=48 ≤ 47 × 7.87×10¹¹ ≈ 3.70×10¹³ (safe)
            uint256 sqReturn;
            unchecked {
                int256 absReturn = logReturn < 0 ? -logReturn : logReturn;
                sqReturn = uint256(absReturn) * uint256(absReturn);
            }
            sumSquaredReturns += sqReturn;

            unchecked { ++i; }
        }

        // Step 3: realizedVariance = sumSquaredReturns / (N-1)  [bps² per interval]
        uint256 realizedVariance = sumSquaredReturns / numReturns;

        // Step 4: annualizedVariance = realizedVariance × SECONDS_PER_YEAR / sampleInterval
        // Scale: for realizedVariance = 7225 (85² = typical ETH hourly), interval = 3600:
        //   annualizedVariance = 7225 × 31536000 / 3600 = 63,291,000
        //   annualizedVol = sqrt(63,291,000) ≈ 7956 bps ≈ 79.6% (correct for ~80% vol asset)
        uint256 annualizedVariance = Math.mulDiv(realizedVariance, SECONDS_PER_YEAR, interval);

        // Step 5: annualizedVol = sqrt(annualizedVariance) using OZ Math.sqrt (Babylonian method)
        annualizedVolBps = Math.sqrt(annualizedVariance);

        // Safety cap to prevent extreme values from misleading consumers.
        if (annualizedVolBps > MAX_VOL_BPS) annualizedVolBps = MAX_VOL_BPS;
    }

    /// @notice Returns realized volatility mapped to a 0-100 risk score.
    ///
    /// @param lowVolThresholdBps  Vol below this maps to score 0 (e.g., 2000 = 20%).
    /// @param highVolThresholdBps Vol above this maps to score 100 (e.g., 15000 = 150%).
    ///
    /// @return volScore 0 = calm market, 100 = extreme volatility.
    function getVolatilityScore(
        uint256 lowVolThresholdBps,
        uint256 highVolThresholdBps
    ) external view returns (uint256 volScore) {
        return getVolatilityScoreForPool(address(pool), sampleInterval, numSamples, lowVolThresholdBps, highVolThresholdBps);
    }

    function getVolatilityScoreForPool(
        address _pool,
        uint32 interval,
        uint8 nSamples,
        uint256 lowVolThresholdBps,
        uint256 highVolThresholdBps
    ) public view returns (uint256 volScore) {
        if (lowVolThresholdBps >= highVolThresholdBps) revert InvalidConfig();

        uint256 vol = this.getRealizedVolatilityForPool(_pool, interval, nSamples);

        if (vol <= lowVolThresholdBps)  return 0;
        if (vol >= highVolThresholdBps) return 100;

        return Math.mulDiv(
            vol - lowVolThresholdBps,
            100,
            highVolThresholdBps - lowVolThresholdBps
        );
    }

    /// @notice Returns raw per-interval avg ticks AND log returns used in the vol calculation.
    /// @dev    Useful for debugging and off-chain validation of on-chain results.
    /// @return avgTicks   Time-weighted average ticks for each sample interval (N values).
    /// @return logReturns Differences between consecutive avg ticks (N-1 values).
    ///                    These are the log returns used for realized variance.
    function getRawTickDeltas()
        external
        view
        returns (int256[] memory avgTicks, int256[] memory logReturns)
    {
        return getRawTickDeltasForPool(address(pool), sampleInterval, numSamples);
    }

    function getRawTickDeltasForPool(address _pool, uint32 interval, uint8 nSamples)
        public
        view
        returns (int256[] memory avgTicks, int256[] memory logReturns)
    {
        if (_pool == address(0)) revert InvalidConfig();
        IUniswapV3PoolTDRV targetPool = IUniswapV3PoolTDRV(_pool);

        uint32 n = uint32(nSamples);

        uint32[] memory secondsAgos = new uint32[](n + 1);
        for (uint32 i = 0; i <= n; ) {
            secondsAgos[i] = (n - i) * interval;
            unchecked { ++i; }
        }

        int56[] memory tickCumulatives;
        try targetPool.observe(secondsAgos) returns (int56[] memory tcs, uint160[] memory) {
            tickCumulatives = tcs;
        } catch {
            revert InsufficientObservationHistory();
        }

        avgTicks = new int256[](n);
        for (uint32 i = 0; i < n; ) {
            int56 rawDelta = tickCumulatives[i + 1] - tickCumulatives[i];
            avgTicks[i] = int256(rawDelta) / int256(uint256(interval));
            unchecked { ++i; }
        }

        uint256 numRet = uint256(n) - 1;
        logReturns = new int256[](numRet);
        for (uint256 i = 0; i < numRet; ) {
            logReturns[i] = avgTicks[i + 1] - avgTicks[i];
            unchecked { ++i; }
        }
    }

    /// @notice Total observation window in seconds: numSamples × sampleInterval.
    function observationWindow() external view returns (uint256) {
        return uint256(numSamples) * uint256(sampleInterval);
    }

    // ─── Volatility Regime ────────────────────────────────────────────────────

    /// @notice Five-rung volatility regime ladder.
    ///         Used by circuit breakers and governance as a simple categorical signal.
    enum VolatilityRegime {
        CALM,     // < 10%   annualized — stablecoin-like, safe for max LTV
        NORMAL,   // 10-30%  — typical low-vol crypto period
        ELEVATED, // 30-60%  — heightened activity, LTV should tighten
        STRESS,   // 60-150% — high-volatility crypto event
        EXTREME   // > 150%  — crisis / black-swan event
    }

    uint256 private constant REGIME_CALM_MAX     =  1_000; //  10%
    uint256 private constant REGIME_NORMAL_MAX   =  3_000; //  30%
    uint256 private constant REGIME_ELEVATED_MAX =  6_000; //  60%
    uint256 private constant REGIME_STRESS_MAX   = 15_000; // 150%

    /// @notice Returns the current volatility regime based on realized vol.
    function getVolatilityRegime() external view returns (VolatilityRegime) {
        return getVolatilityRegimeForPool(address(pool), sampleInterval, numSamples);
    }

    function getVolatilityRegimeForPool(address _pool, uint32 interval, uint8 nSamples) public view returns (VolatilityRegime) {
        uint256 vol = this.getRealizedVolatilityForPool(_pool, interval, nSamples);
        if (vol <= REGIME_CALM_MAX)     return VolatilityRegime.CALM;
        if (vol <= REGIME_NORMAL_MAX)   return VolatilityRegime.NORMAL;
        if (vol <= REGIME_ELEVATED_MAX) return VolatilityRegime.ELEVATED;
        if (vol <= REGIME_STRESS_MAX)   return VolatilityRegime.STRESS;
        return VolatilityRegime.EXTREME;
    }

    // ─── EWMA Volatility ──────────────────────────────────────────────────────

    /// @notice Computes Exponentially Weighted Moving Average (EWMA) realized volatility.
    ///
    /// @dev    EWMA variance formula (RiskMetrics / J.P. Morgan standard):
    ///           ewmaVar_0 = r_0²
    ///           ewmaVar_i = λ × ewmaVar_{i-1} + (1-λ) × r_i²
    ///         where r_i is the i-th log return (tick difference) and λ is the decay factor.
    ///
    ///         Common λ values:
    ///           λ = 0.94 (9_400 BPS) — RiskMetrics daily, responsive to recent moves
    ///           λ = 0.97 (9_700 BPS) — RiskMetrics monthly, slower to adapt
    ///           λ = 0.90 (9_000 BPS) — more reactive, good for intraday monitoring
    ///
    ///         EWMA overweights recent returns vs. simple realized variance.
    ///         This makes it more responsive during fast-moving markets.
    ///
    /// @param lambdaBps  Decay factor in BPS (1-9999). e.g., 9400 = 0.94.
    /// @return ewmaVolBps Annualized EWMA realized vol in basis points.
    function getVolatilityEWMA(uint256 lambdaBps)
        external
        view
        returns (uint256 ewmaVolBps)
    {
        return getVolatilityEWMAForPool(address(pool), sampleInterval, numSamples, lambdaBps);
    }

    function getVolatilityEWMAForPool(address _pool, uint32 interval, uint8 nSamples, uint256 lambdaBps)
        public
        view
        returns (uint256 ewmaVolBps)
    {
        if (lambdaBps == 0 || lambdaBps >= 10_000) revert InvalidConfig();
        if (_pool == address(0)) revert InvalidConfig();

        IUniswapV3PoolTDRV targetPool = IUniswapV3PoolTDRV(_pool);
        uint32 n = uint32(nSamples);
        uint256 BPS_SCALE = 10_000;

        uint32[] memory secondsAgos = new uint32[](n + 1);
        for (uint32 i = 0; i <= n; ) {
            secondsAgos[i] = (n - i) * interval;
            unchecked { ++i; }
        }

        int56[] memory tickCumulatives;
        try targetPool.observe(secondsAgos) returns (int56[] memory tcs, uint160[] memory) {
            tickCumulatives = tcs;
        } catch {
            revert InsufficientObservationHistory();
        }

        // Compute N avg ticks.
        int256[] memory avgTicks = new int256[](n);
        for (uint32 i = 0; i < n; ) {
            int56 rawDelta = tickCumulatives[i + 1] - tickCumulatives[i];
            avgTicks[i] = int256(rawDelta) / int256(uint256(interval));
            unchecked { ++i; }
        }

        // EWMA over (N-1) log returns.
        uint256 numReturns = uint256(n) - 1;
        uint256 ewmaVar = 0;

        for (uint256 i = 0; i < numReturns; ) {
            int256 logReturn = avgTicks[i + 1] - avgTicks[i];
            uint256 sqReturn;
            unchecked {
                int256 absR = logReturn < 0 ? -logReturn : logReturn;
                sqReturn = uint256(absR) * uint256(absR);
            }

            if (i == 0) {
                ewmaVar = sqReturn;
            } else {
                // ewmaVar = λ × ewmaVar + (1-λ) × sqReturn
                ewmaVar = (lambdaBps * ewmaVar + (BPS_SCALE - lambdaBps) * sqReturn) / BPS_SCALE;
            }
            unchecked { ++i; }
        }

        // Annualize: ewmaAnnualVar = ewmaVar × SECONDS_PER_YEAR / sampleInterval
        uint256 annualizedVar = Math.mulDiv(ewmaVar, SECONDS_PER_YEAR, interval);
        ewmaVolBps = Math.sqrt(annualizedVar);
        if (ewmaVolBps > MAX_VOL_BPS) ewmaVolBps = MAX_VOL_BPS;
    }

    // ─── Flexible Window Query ────────────────────────────────────────────────

    /// @notice Computes realized volatility over an arbitrary window and sample count.
    /// @dev    Uses the same algorithm as getRealizedVolatility() but with caller-specified
    ///         window parameters.  Gracefully returns (0, false) if the pool lacks sufficient
    ///         observation history for the requested window.
    ///
    ///         Examples:
    ///           getVolatilityOverWindow(3600, 24)    → 1-hour intervals, 24h window (same as default)
    ///           getVolatilityOverWindow(86400, 7)    → 1-day intervals,  7d  window
    ///           getVolatilityOverWindow(900, 48)     → 15-min intervals, 12h window
    ///
    /// @param  windowSeconds  Total observation window in seconds.
    /// @param  nSamples       Number of sample intervals (3-MAX_SAMPLES).
    /// @return annualizedVolBps Annualized realized vol in BPS (0 if data unavailable).
    /// @return success          False if pool.observe() reverted (insufficient history).
    function getVolatilityOverWindow(uint32 windowSeconds, uint8 nSamples)
        external
        view
        returns (uint256 annualizedVolBps, bool success)
    {
        return getVolatilityOverWindowForPool(address(pool), windowSeconds, nSamples);
    }

    function getVolatilityOverWindowForPool(address _pool, uint32 windowSeconds, uint8 nSamples)
        public
        view
        returns (uint256 annualizedVolBps, bool success)
    {
        if (_pool == address(0)) revert InvalidConfig();
        if (nSamples < MIN_SAMPLES || nSamples > MAX_SAMPLES) revert InvalidConfig();
        uint32 interval = windowSeconds / uint32(nSamples);
        if (interval < MIN_SAMPLE_INTERVAL) revert SampleIntervalTooShort();

        uint32[] memory secondsAgos = new uint32[](uint32(nSamples) + 1);
        for (uint32 i = 0; i <= uint32(nSamples); ) {
            secondsAgos[i] = windowSeconds - i * interval;
            unchecked { ++i; }
        }

        int56[] memory tickCumulatives;
        try IUniswapV3PoolTDRV(_pool).observe(secondsAgos) returns (int56[] memory tcs, uint160[] memory) {
            tickCumulatives = tcs;
        } catch {
            return (0, false);
        }

        uint32 n = uint32(nSamples);
        int256[] memory avgTicks = new int256[](n);
        for (uint32 i = 0; i < n; ) {
            int56 rawDelta = tickCumulatives[i + 1] - tickCumulatives[i];
            avgTicks[i] = int256(rawDelta) / int256(uint256(interval));
            unchecked { ++i; }
        }

        uint256 numReturns = uint256(n) - 1;
        uint256 sumSq = 0;
        for (uint256 i = 0; i < numReturns; ) {
            int256 logReturn = avgTicks[i + 1] - avgTicks[i];
            uint256 sqReturn;
            unchecked {
                int256 absR = logReturn < 0 ? -logReturn : logReturn;
                sqReturn = uint256(absR) * uint256(absR);
            }
            sumSq += sqReturn;
            unchecked { ++i; }
        }

        uint256 realizedVariance = sumSq / numReturns;
        uint256 annualizedVariance = Math.mulDiv(realizedVariance, SECONDS_PER_YEAR, interval);
        annualizedVolBps = Math.sqrt(annualizedVariance);
        if (annualizedVolBps > MAX_VOL_BPS) annualizedVolBps = MAX_VOL_BPS;
        success = true;
    }
}
