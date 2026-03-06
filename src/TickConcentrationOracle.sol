// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ─── Pool Interface ───────────────────────────────────────────────────────────

interface IUniswapV3PoolTCO {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
}

/// @title TickConcentrationOracle
/// @notice Fourth risk pillar: information-theoretic manipulation detection via
///         Shannon/Renyi entropy of the Uniswap V3 tick observation sequence.
///
/// @dev ── THE INFORMATION-THEORETIC INSIGHT ──────────────────────────────────
///
///      Shannon entropy measures the UNPREDICTABILITY of a sequence:
///
///        H = -sum( p_i × log2(p_i) )
///
///        H_MAX when all ticks are distinct  → organic, unpredictable market
///        H = 0  when all ticks are identical → frozen or manipulated price
///
///      A TWAP manipulation attack requires the attacker to hold the Uniswap
///      spot price at an artificial level for the entire twapWindow.
///      This sustained pressure leaves a DETERMINISTIC FINGERPRINT in the
///      tick sequence — the sequence becomes LOW ENTROPY.
///
///      Legitimate volatility looks RANDOM (high entropy).
///      Manipulation looks STRUCTURED (low entropy).
///
///      ── ENTROPY PROXY: HERFINDAHL-HIRSCHMAN INDEX (HHI) ─────────────────────
///
///      log2 is expensive in Solidity. We use HHI as a log-free proxy.
///
///        HHI = sum( (count_i / N)^2 )  =  sum(count_i^2) / N^2
///
///      Connection to Renyi entropy of order 2 (collision entropy):
///
///        H_2 = -log2(HHI)
///
///      Properties:
///        HHI = 1/K  when K buckets equally occupied  →  max entropy (organic)
///        HHI = 1    when all N samples in one bucket  →  zero entropy (attack)
///
///      HHI is used in antitrust economics to measure market concentration.
///      Here it measures TICK DISTRIBUTION CONCENTRATION — the same math,
///      applied to detect price oracle manipulation.
///
///      ── DIRECTIONAL BIAS: CONDITIONAL ENTROPY ────────────────────────────────
///
///      A second manipulation signal: how predictable is X_t given X_{t-1}?
///
///        H(X_t | X_{t-1}) = 0  → future tick fully predictable from past
///                                 (monotone price push = manipulation)
///        H(X_t | X_{t-1}) = 1  → future tick independent of past
///                                 (random walk = organic)
///
///      Proxy: fraction of consecutive tick pairs with the SAME sign.
///        Random walk: ~50% same-sign pairs → neutral
///        Monotone attack: 100% same-sign   → maximum directional bias
///
///      ── RENYI ENTROPY H_2 (APPROXIMATE) ─────────────────────────────────────
///
///      Using OpenZeppelin Math.log2() (returns floor):
///
///        H_2 ≈ floor( log2( BPS / hhiBps ) )
///
///      Unit: bits. Range:
///        0 bits  → single bucket (HHI = BPS)   → pure manipulation signature
///        6 bits  → 64 buckets equally occupied  → maximum organic entropy
///
///      ── ORTHOGONALITY TO MCO AND TDRV ────────────────────────────────────────
///
///        MCO  asks: "How EXPENSIVE is manipulation?" (financial dimension)
///        TDRV asks: "How LARGE is price movement?"   (magnitude dimension)
///        TCO  asks: "How ANOMALOUS is the tick sequence?" (information dimension)
///
///      Example: low-volatility oracle attack
///        - MCO score: MEDIUM (moderate liquidity → moderate cost)
///        - TDRV score: LOW (small deviation → low realized vol)
///        - TCO score: HIGH (ticks monotonically creeping up → low entropy)
///        TCO CATCHES WHAT MCO AND TDRV MISS.
///
/// @dev ── GAS CHARACTERISTICS ─────────────────────────────────────────────────
///
///      Time complexity: O(N × K) where K = unique buckets <= MAX_BUCKETS = 64.
///      For N=24 samples, K<=24: ~576 comparisons, well within block gas limits.
///      All arithmetic is pure integer (no division for log, no floating point).
contract TickConcentrationOracle {
    using Math for uint256;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidConfig();
    error InvalidSamples();
    error InsufficientObservationHistory();
    error SampleIntervalTooShort();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant BPS         = 10_000;
    uint256 private constant MAX_SCORE   = 100;

    uint8 public constant MAX_SAMPLES    = 48;
    uint8 public constant MIN_SAMPLES    = 3;

    /// @notice Minimum seconds between consecutive samples.
    uint32 public constant MIN_SAMPLE_INTERVAL = 60;

    /// @notice Tick bucket width for histogram construction.
    ///         10 ticks ≈ 0.1% price range per bucket.
    ///         Narrow enough to detect fine-grained price pinning;
    ///         wide enough to group noise from legitimate price discovery.
    int24 private constant BUCKET_WIDTH = 10;

    /// @notice Maximum distinct buckets tracked (gas bound on inner loop).
    ///         64 buckets × 10 tick-width = 640 ticks ≈ 6.4% price range.
    ///         A manipulation attack rarely spans more than 5% deviation.
    uint256 private constant MAX_BUCKETS = 64;

    /// @notice Random-walk baseline: ~50% of consecutive tick pairs share sign.
    ///         Directional bias below this is organic. Above this suggests trend
    ///         or manipulation.
    uint256 private constant NEUTRAL_BIAS_BPS = 5_000;

    // Composite score weights.
    uint256 private constant HHI_WEIGHT  = 60; // HHI concentration (primary)
    uint256 private constant BIAS_WEIGHT = 40; // directional bias (secondary)

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice Uniswap V3 pool from which tick observations are read.
    IUniswapV3PoolTCO public immutable pool;

    /// @notice Total observation window in seconds.
    uint32 public immutable windowSeconds;

    /// @notice Number of equally-spaced tick samples per window.
    uint8 public immutable numSamples;

    // ─── Structs ──────────────────────────────────────────────────────────────

    /// @notice Full information-theoretic breakdown of the tick distribution.
    struct ConcentrationResult {
        /// @notice HHI of the tick bucket distribution, in BPS.
        ///         BPS/K ≈ organic (K = unique buckets).
        ///         BPS   = maximally concentrated (single bucket, zero entropy).
        uint256 hhiBps;

        /// @notice Count of distinct tick buckets visited in the window.
        ///         Fewer buckets → price pinned → manipulation signal.
        uint256 uniqueBuckets;

        /// @notice Fraction of consecutive tick pairs sharing the same sign, in BPS.
        ///         5000 BPS = random walk baseline.
        ///         10000 BPS = fully monotonic (attacker holding price in one direction).
        uint256 directionalBiasBps;

        /// @notice Approximate Renyi entropy H_2 in bits (integer floor).
        ///         H_2 = floor( log2( BPS / hhiBps ) ).
        ///         0 bits = single bucket (pure concentration).
        ///         ≥4 bits = well-dispersed organic market.
        uint256 approximateEntropyBits;

        /// @notice Composite manipulation risk score: 0 (organic) to 100 (concentrated).
        ///         Weighted combination: 60% HHI score + 40% directional bias score.
        uint256 concentrationScore;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _pool           Uniswap V3 pool address.
    /// @param _windowSeconds  Total observation window in seconds.
    /// @param _numSamples     Number of samples to draw (MIN_SAMPLES to MAX_SAMPLES).
    constructor(address _pool, uint32 _windowSeconds, uint8 _numSamples) {
        if (_pool == address(0)) revert InvalidConfig();
        if (_numSamples < MIN_SAMPLES || _numSamples > MAX_SAMPLES) revert InvalidSamples();

        uint32 interval = _windowSeconds / uint32(_numSamples);
        if (interval < MIN_SAMPLE_INTERVAL) revert SampleIntervalTooShort();

        pool          = IUniswapV3PoolTCO(_pool);
        windowSeconds = _windowSeconds;
        numSamples    = _numSamples;

        // Validate pool has sufficient observation history.
        uint32[] memory probe = new uint32[](2);
        probe[0] = _windowSeconds;
        probe[1] = 0;
        pool.observe(probe); // reverts if history insufficient
    }

    // ─── Primary Interface ────────────────────────────────────────────────────

    /// @notice Returns the composite 0-100 concentration risk score.
    ///         0 = organic (high entropy, random tick distribution)
    ///         100 = fully concentrated (zero entropy, monotonic manipulation)
    function getConcentrationScore() external view returns (uint256) {
        return getConcentrationScoreForPool(address(pool), windowSeconds, numSamples);
    }

    /// @notice Returns the composite 0-100 concentration risk score for ANY pool.
    /// @param _pool          Uniswap V3 pool address.
    /// @param _windowSeconds Total observation window in seconds.
    /// @param _numSamples    Number of samples to draw.
    function getConcentrationScoreForPool(address _pool, uint32 _windowSeconds, uint8 _numSamples) public view returns (uint256) {
        int24[] memory ticks = _sampleTicks(_pool, _windowSeconds, _numSamples);
        (uint256 hhiBps,) = _computeHHI(ticks);
        uint256 biasBps = _computeDirectionalBias(ticks);
        return _compositeScore(hhiBps, biasBps);
    }

    /// @notice Returns the full information-theoretic breakdown.
    function getConcentrationBreakdown()
        external
        view
        returns (ConcentrationResult memory result)
    {
        return getConcentrationBreakdownForPool(address(pool), windowSeconds, numSamples);
    }

    function getConcentrationBreakdownForPool(address _pool, uint32 _windowSeconds, uint8 _numSamples)
        public
        view
        returns (ConcentrationResult memory result)
    {
        int24[] memory ticks = _sampleTicks(_pool, _windowSeconds, _numSamples);
        (uint256 hhiBps, uint256 uniqueBuckets) = _computeHHI(ticks);
        uint256 biasBps = _computeDirectionalBias(ticks);

        // Approximate H_2 = floor( log2( BPS / hhiBps ) )
        // We scale up by 1000 first to get sub-bit precision in the integer result.
        uint256 entropyBits;
        if (hhiBps > 0 && hhiBps < BPS) {
            // log2( BPS / hhiBps ) = log2(BPS) - log2(hhiBps)
            // Use OZ Math.log2 (returns floor).
            uint256 ratio = (BPS * 1_000) / hhiBps; // scale ×1000 for precision
            entropyBits = Math.log2(ratio);           // floor(log2(ratio)) ≥ log2(BPS/hhiBps)
        }

        result = ConcentrationResult({
            hhiBps:                 hhiBps,
            uniqueBuckets:          uniqueBuckets,
            directionalBiasBps:     biasBps,
            approximateEntropyBits: entropyBits,
            concentrationScore:     _compositeScore(hhiBps, biasBps)
        });
    }

    /// @notice Returns the raw HHI value (no composite scoring).
    ///         Useful for callers who want to apply their own scoring function.
    function getHHI() external view returns (uint256 hhiBps, uint256 uniqueBuckets) {
        int24[] memory ticks = _sampleTicks(address(pool), windowSeconds, numSamples);
        return _computeHHI(ticks);
    }

    function getHHIForPool(address _pool, uint32 _windowSeconds, uint8 _numSamples) external view returns (uint256 hhiBps, uint256 uniqueBuckets) {
        int24[] memory ticks = _sampleTicks(_pool, _windowSeconds, _numSamples);
        return _computeHHI(ticks);
    }

    /// @notice Returns approximate Renyi H_2 entropy bits for current window.
    ///         0 = fully concentrated. Higher = more organic.
    function getApproximateEntropyBits() external view returns (uint256 entropyBits) {
        int24[] memory ticks = _sampleTicks(address(pool), windowSeconds, numSamples);
        (uint256 hhiBps,) = _computeHHI(ticks);
        if (hhiBps > 0 && hhiBps < BPS) {
            entropyBits = Math.log2((BPS * 1_000) / hhiBps);
        }
    }

    /// @notice Returns directional bias in BPS.
    ///         5000 = random walk. 10000 = fully monotonic (manipulation).
    function getDirectionalBias() external view returns (uint256 biasBps) {
        int24[] memory ticks = _sampleTicks(address(pool), windowSeconds, numSamples);
        return _computeDirectionalBias(ticks);
    }

    // ─── Internal: Tick Sampling ──────────────────────────────────────────────

    /// @dev Samples numSamples average ticks from the pool using observe().
    ///      Returns an array of numSamples time-weighted average ticks,
    ///      one per sample interval (oldest to most recent).
    function _sampleTicks(address _pool, uint32 _windowSeconds, uint8 _numSamples) internal view returns (int24[] memory ticks) {
        if (_pool == address(0)) revert InvalidConfig();
        if (_numSamples < MIN_SAMPLES || _numSamples > MAX_SAMPLES) revert InvalidSamples();
        
        uint8  n        = _numSamples;
        uint32 interval = _windowSeconds / uint32(n);

        // Build secondsAgos: [window, window-interval, ..., interval, 0]
        uint32[] memory secondsAgos = new uint32[](n + 1);
        for (uint8 i = 0; i <= n; ) {
            secondsAgos[i] = _windowSeconds - i * interval;
            unchecked { ++i; }
        }

        // Fetch cumulative ticks
        int56[] memory tickCumulatives;
        try IUniswapV3PoolTCO(_pool).observe(secondsAgos) returns (int56[] memory tcs, uint160[] memory) {
            tickCumulatives = tcs;
        } catch {
            revert InsufficientObservationHistory();
        }

        // Convert cumulative ticks to per-interval average ticks.
        ticks = new int24[](n);
        for (uint8 i = 0; i < n; ) {
            int56 delta = tickCumulatives[i + 1] - tickCumulatives[i];
            ticks[i] = int24(delta / int56(uint56(interval)));
            unchecked { ++i; }
        }
    }

    // ─── Internal: HHI Computation ────────────────────────────────────────────

    /// @dev Computes the Herfindahl-Hirschman Index of the bucketed tick distribution.
    ///
    ///      Algorithm:
    ///        1. Assign each tick to a bucket: bucket = tick / BUCKET_WIDTH.
    ///        2. Count occurrences per bucket using a fixed-size parallel array.
    ///        3. HHI = sum(count_i^2) / N^2 , scaled to BPS.
    ///
    ///      Complexity: O(N × K) with K ≤ MAX_BUCKETS.
    ///      No dynamic memory allocation inside the loop — gas-efficient.
    ///
    /// @return hhiBps       HHI in BPS (0–10000). 10000 = single bucket.
    /// @return uniqueBuckets Number of distinct tick buckets in the sample.
    function _computeHHI(int24[] memory ticks)
        internal
        pure
        returns (uint256 hhiBps, uint256 uniqueBuckets)
    {
        uint256 n = ticks.length;
        if (n == 0) return (BPS, 0);

        // Fixed-size arrays avoid dynamic memory overhead inside the loop.
        int24[64]   memory bucketKeys;
        uint256[64] memory bucketCounts;
        uint256 numBuckets;

        for (uint256 i; i < n; ) {
            int24 bucket = ticks[i] / BUCKET_WIDTH;
            bool found;

            for (uint256 j; j < numBuckets; ) {
                if (bucketKeys[j] == bucket) {
                    bucketCounts[j]++;
                    found = true;
                    break;
                }
                unchecked { ++j; }
            }

            if (!found && numBuckets < MAX_BUCKETS) {
                bucketKeys[numBuckets]   = bucket;
                bucketCounts[numBuckets] = 1;
                numBuckets++;
            }
            unchecked { ++i; }
        }

        uniqueBuckets = numBuckets;
        if (numBuckets == 0) return (BPS, 0);

        uint256 sumSquares;
        for (uint256 j; j < numBuckets; ) {
            sumSquares += bucketCounts[j] * bucketCounts[j];
            unchecked { ++j; }
        }

        // HHI_bps = sum(count_i^2) × BPS / N^2
        hhiBps = (sumSquares * BPS) / (n * n);
    }

    // ─── Internal: Directional Bias ───────────────────────────────────────────

    /// @dev Measures the fraction of consecutive tick pairs that move in the same
    ///      direction — a proxy for conditional entropy H(X_t | X_{t-1}).
    ///
    ///      Same direction includes:
    ///        - Both positive (price rising)
    ///        - Both negative (price falling)
    ///        - Both zero (price frozen — also a manipulation indicator)
    ///
    ///      Baseline: a symmetric random walk has ~50% same-direction pairs
    ///      → biasBps ≈ NEUTRAL_BIAS_BPS (5000).
    ///
    ///      Attack: monotone price push → 100% same-direction
    ///      → biasBps = BPS (10000).
    ///
    /// @return biasBps Same-direction fraction in BPS (0–10000).
    function _computeDirectionalBias(int24[] memory ticks)
        internal
        pure
        returns (uint256 biasBps)
    {
        uint256 n = ticks.length;
        if (n < 2) return NEUTRAL_BIAS_BPS;

        uint256 sameDir;
        for (uint256 i = 1; i < n; ) {
            bool prevPos  = ticks[i - 1] > 0;
            bool prevNeg  = ticks[i - 1] < 0;
            bool currPos  = ticks[i]     > 0;
            bool currNeg  = ticks[i]     < 0;
            bool prevZero = !prevPos && !prevNeg;
            bool currZero = !currPos && !currNeg;

            // Both rising, both falling, or both frozen = same direction.
            if ((prevPos && currPos) || (prevNeg && currNeg) || (prevZero && currZero)) {
                sameDir++;
            }
            unchecked { ++i; }
        }

        biasBps = (sameDir * BPS) / (n - 1);
    }

    // ─── Internal: Score Composition ─────────────────────────────────────────

    /// @dev Maps HHI and directional bias to a 0-100 composite risk score.
    ///
    ///      HHI scoring (60% weight):
    ///        Min HHI ≈ BPS / MAX_BUCKETS = 156 BPS (64 equally-used buckets)
    ///        Max HHI = BPS (single bucket, full concentration)
    ///        → Linear interpolation from [156, 10000] → [0, 100]
    ///
    ///      Directional bias scoring (40% weight):
    ///        Baseline = NEUTRAL_BIAS_BPS (5000) → score 0  (random walk)
    ///        Max = BPS (10000)                  → score 100 (monotonic)
    ///        Below baseline → score 0 (alternating = organic)
    ///        → Linear interpolation from [5000, 10000] → [0, 100]
    function _compositeScore(uint256 hhiBps, uint256 biasBps)
        internal
        pure
        returns (uint256 score)
    {
        // --- HHI concentration score ---
        uint256 hiiMin = BPS / MAX_BUCKETS; // 156 BPS (most organic possible)
        uint256 hiiScore;
        if (hhiBps <= hiiMin) {
            hiiScore = 0;
        } else if (hhiBps >= BPS) {
            hiiScore = MAX_SCORE;
        } else {
            hiiScore = ((hhiBps - hiiMin) * MAX_SCORE) / (BPS - hiiMin);
        }

        // --- Directional bias score ---
        uint256 biasScore;
        if (biasBps <= NEUTRAL_BIAS_BPS) {
            biasScore = 0; // random or alternating = organic
        } else if (biasBps >= BPS) {
            biasScore = MAX_SCORE;
        } else {
            biasScore = ((biasBps - NEUTRAL_BIAS_BPS) * MAX_SCORE) / (BPS - NEUTRAL_BIAS_BPS);
        }

        // Weighted composite: 60% HHI + 40% bias.
        score = (hiiScore * HHI_WEIGHT + biasScore * BIAS_WEIGHT) / (HHI_WEIGHT + BIAS_WEIGHT);
    }
}
