// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskConsumer, IRiskScoreProvider} from "./interfaces/IRiskConsumer.sol";

// ============================================================================
//  RiskCircuitBreaker
//  Abstract base contract.  Inherit this in any lending protocol, vault, or
//  AMM that wants autonomous, risk-score-driven parameter adjustment.
//
//  Architecture:
//    1.  checkAndRespond() is permissionless (any EOA/bot can call after cooldown)
//    2.  _onLevelChange() is the single hook to override in concrete contracts
//    3.  AlertLevel is a 5-rung ladder: NOMINAL → WATCH → WARNING → DANGER → EMERGENCY
//    4.  Cooldown prevents oscillation / gas griefing
//
//  Why this beats Gauntlet / Chaos Labs:
//    Both are off-chain advisory services.  This is an on-chain primitive.
//    A protocol that inherits RiskCircuitBreaker can tighten LTV, pause borrows,
//    or halt deposits in the SAME BLOCK a risk threshold is crossed — with zero
//    governance delay.
// ============================================================================

/// @title RiskCircuitBreaker
/// @notice Abstract base for on-chain autonomous risk response.
abstract contract RiskCircuitBreaker is IRiskConsumer {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Five-rung risk alert ladder.
    enum AlertLevel {
        NOMINAL, // score  0-24
        WATCH, // score 25-49
        WARNING, // score 50-64
        DANGER, // score 65-79
        EMERGENCY // score 80-100
    }

    /// @notice Configuration for alert thresholds and cooldown period.
    struct CircuitBreakerConfig {
        uint256 watchThreshold; // score >= this → WATCH        (default 25)
        uint256 warningThreshold; // score >= this → WARNING     (default 50)
        uint256 dangerThreshold; // score >= this → DANGER       (default 65)
        uint256 emergencyThreshold; // score >= this → EMERGENCY (default 80)
        uint256 cooldownSeconds; // min seconds between triggers (default 300)
    }

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The UnifiedRiskCompositor this breaker reads scores from.
    IRiskScoreProvider public immutable compositor;

    /// @notice The asset this circuit breaker protects.
    address public immutable trackedAsset;

    /// @notice Threshold and cooldown configuration (immutable post-construction).
    CircuitBreakerConfig public config;

    /// @notice Current alert level (persists between calls).
    AlertLevel public currentLevel;

    /// @notice Timestamp of the last checkAndRespond call.
    uint256 public lastTriggerTime;

    /// @notice Risk score that last triggered a level change.
    uint256 public override lastTriggerScore;

    // =========================================================================
    // Errors
    // =========================================================================

    error CooldownActive(uint256 unlocksAt);
    error InvalidConfig();
    error ZeroCompositor();
    error ZeroTrackedAsset();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Fired whenever the alert level changes.
    event AlertLevelChanged(
        AlertLevel indexed from,
        AlertLevel indexed to,
        uint256 score,
        uint256 timestamp
    );

    /// @notice Fired on every successful checkAndRespond call.
    event CircuitBreakerTriggered(AlertLevel indexed level, uint256 score, uint256 timestamp);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _compositor, address _trackedAsset, CircuitBreakerConfig memory _config) {
        if (_compositor == address(0)) revert ZeroCompositor();
        if (_trackedAsset == address(0)) revert ZeroCompositor();
        if (_trackedAsset == address(0)) revert ZeroTrackedAsset();
        if (
            _config.watchThreshold == 0
                || _config.warningThreshold <= _config.watchThreshold
                || _config.dangerThreshold <= _config.warningThreshold
                || _config.emergencyThreshold <= _config.dangerThreshold
                || _config.emergencyThreshold > 100
        ) revert InvalidConfig();

        compositor = IRiskScoreProvider(_compositor);
        trackedAsset = _trackedAsset;
        config = _config;
        currentLevel = AlertLevel.NOMINAL;
    }

    // =========================================================================
    // IRiskConsumer — riskCompositor() address getter
    // =========================================================================

    function riskCompositor() external view override returns (address) {
        return address(compositor);
    }

    // =========================================================================
    // Core Logic
    // =========================================================================

    /// @notice Reads the current risk score and transitions the circuit breaker
    ///         if the alert level has changed.  Enforces a cooldown between calls.
    /// @dev Permissionless — any EOA, keeper, or automation network can call this.
    /// @return levelChanged True if the alert level changed during this call.
    function checkAndRespond() public returns (bool levelChanged) {
        if (isInCooldown()) revert CooldownActive(lastTriggerTime + config.cooldownSeconds);

        // Explicit try-catch wrapping around getRiskScore(asset) vs getRiskScore()
        uint256 score;
        try compositor.getRiskScore(trackedAsset) returns (uint256 s) {
            score = s;
        } catch {
            score = compositor.getRiskScore();
        }

        AlertLevel prevLevel = currentLevel;
        AlertLevel newLevel = _scoreToAlertLevel(score);

        levelChanged = (newLevel != currentLevel);
        if (levelChanged) {
            currentLevel = newLevel;
            lastTriggerScore = score;
            emit AlertLevelChanged(prevLevel, newLevel, score, block.timestamp);
            _onLevelChange(prevLevel, newLevel, score);
        }

        lastTriggerTime = block.timestamp;
        emit CircuitBreakerTriggered(newLevel, score, block.timestamp);
    }

    // =========================================================================
    // Hook (override in concrete contracts)
    // =========================================================================

    /// @notice Called when the alert level changes.
    /// @param from  Previous alert level.
    /// @param to    New alert level.
    /// @param score Current composite risk score (0-100).
    function _onLevelChange(AlertLevel from, AlertLevel to, uint256 score) internal virtual;

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @notice Returns true if the cooldown is still active.
    function isInCooldown() public view returns (bool) {
        return block.timestamp < lastTriggerTime + config.cooldownSeconds;
    }

    /// @notice Returns how many seconds until the cooldown expires (0 if expired).
    function getTimeUntilCooldownExpiry() external view returns (uint256) {
        uint256 cooldownEnd = lastTriggerTime + config.cooldownSeconds;
        if (block.timestamp >= cooldownEnd) return 0;
        return cooldownEnd - block.timestamp;
    }

    /// @notice Maps a 0-100 score to an AlertLevel.
    function _scoreToAlertLevel(uint256 score) internal view returns (AlertLevel) {
        if (score >= config.emergencyThreshold) return AlertLevel.EMERGENCY;
        if (score >= config.dangerThreshold) return AlertLevel.DANGER;
        if (score >= config.warningThreshold) return AlertLevel.WARNING;
        if (score >= config.watchThreshold) return AlertLevel.WATCH;
        return AlertLevel.NOMINAL;
    }

    // =========================================================================
    // IRiskConsumer — default implementations (override as needed)
    // =========================================================================

    /// @notice Returns false by default; override if the concrete contract
    ///         exposes a separate "apply" pathway (e.g. called by governance).
    function applyRiskUpdate() external virtual override returns (bool) {
        return false;
    }
}

// ============================================================================
//  LendingProtocolCircuitBreaker
//  Concrete reference implementation showing how a lending market inherits
//  RiskCircuitBreaker to automatically adjust LTV caps and pause borrowing
//  when DeFiStressOracle risk thresholds are crossed.
//
//  This contract is deployable standalone and usable as-is for any protocol
//  that wants to wire a risk score to LTV + borrow-pause logic.
// ============================================================================

/// @title LendingProtocolCircuitBreaker
/// @notice Reference implementation: automatic LTV tightening + borrow pausing.
contract LendingProtocolCircuitBreaker is RiskCircuitBreaker {
    // =========================================================================
    // Constants — LTV ladder per alert level
    // =========================================================================

    uint256 public constant LTV_NOMINAL = 8_000; // 80%
    uint256 public constant LTV_WATCH = 7_500; // 75%
    uint256 public constant LTV_WARNING = 7_000; // 70%
    uint256 public constant LTV_DANGER = 6_000; // 60%
    uint256 public constant LTV_EMERGENCY = 5_000; // 50%

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Current maximum LTV this market will accept (BPS, e.g. 8000 = 80%).
    uint256 public override currentMaxLtvBps;

    /// @notice True when new borrows are suspended due to EMERGENCY alert.
    bool public borrowingPaused;

    /// @notice True when new deposits are suspended (only at EMERGENCY).
    bool public depositingPaused;

    // =========================================================================
    // Events
    // =========================================================================

    event LtvUpdated(uint256 indexed oldLtv, uint256 indexed newLtv, AlertLevel triggeredBy);
    event BorrowingPaused(uint256 score);
    event BorrowingResumed(uint256 score);
    event DepositingPaused(uint256 score);
    event DepositingResumed(uint256 score);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _compositor Address of the UnifiedRiskCompositor or MultiAssetRiskRouter.
    /// @param _trackedAsset Address of the specific collateral asset this breaker protects.
    constructor(address _compositor, address _trackedAsset)
        RiskCircuitBreaker(
            _compositor,
            _trackedAsset,
            CircuitBreakerConfig({
                watchThreshold: 25,
                warningThreshold: 50,
                dangerThreshold: 65,
                emergencyThreshold: 80,
                cooldownSeconds: 5 minutes
            })
        )
    {
        currentMaxLtvBps = LTV_NOMINAL;
    }

    // =========================================================================
    // Hook
    // =========================================================================

    /// @dev Automatically adjusts LTV and pauses/resumes borrowing/depositing.
    function _onLevelChange(AlertLevel, AlertLevel to, uint256 score) internal override {
        // --- LTV adjustment ---
        uint256 newLtv = _ltvForLevel(to);
        if (newLtv != currentMaxLtvBps) {
            uint256 old = currentMaxLtvBps;
            currentMaxLtvBps = newLtv;
            emit LtvUpdated(old, newLtv, to);
        }

        // --- Borrow pause/resume ---
        if (to == AlertLevel.EMERGENCY && !borrowingPaused) {
            borrowingPaused = true;
            emit BorrowingPaused(score);
        } else if (to <= AlertLevel.WATCH && borrowingPaused) {
            borrowingPaused = false;
            emit BorrowingResumed(score);
        }

        // --- Deposit pause/resume (only at full emergency) ---
        if (to == AlertLevel.EMERGENCY && !depositingPaused) {
            depositingPaused = true;
            emit DepositingPaused(score);
        } else if (to < AlertLevel.DANGER && depositingPaused) {
            depositingPaused = false;
            emit DepositingResumed(score);
        }
    }

    // =========================================================================
    // IRiskConsumer
    // =========================================================================

    function isProtectionActive() external view override returns (bool) {
        return borrowingPaused || depositingPaused;
    }

    // isProtectionActive() is declared with override above ✓
    function applyRiskUpdate() external override returns (bool applied) {
        // Delegating to checkAndRespond so governance / keepers can use either entrypoint.
        checkAndRespond();
        return true;
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _ltvForLevel(AlertLevel level) internal pure returns (uint256) {
        if (level == AlertLevel.EMERGENCY) return LTV_EMERGENCY;
        if (level == AlertLevel.DANGER) return LTV_DANGER;
        if (level == AlertLevel.WARNING) return LTV_WARNING;
        if (level == AlertLevel.WATCH) return LTV_WATCH;
        return LTV_NOMINAL;
    }
}
