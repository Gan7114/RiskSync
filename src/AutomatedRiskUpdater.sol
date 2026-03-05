// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

// ============================================================================
//  AutomatedRiskUpdater
//
//  Chainlink Automation integration for DeFiStressOracle.
//
//  ── WHY AUTOMATION? ─────────────────────────────────────────────────────────
//
//  Without Automation, `updateRiskScore()` and `checkAndRespond()` must be
//  called by a centralized bot or EOA. This creates:
//    • A single point of failure (bot goes down = stale risk scores)
//    • Centralization risk (who runs the bot?)
//    • No cryptoeconomic incentive for upkeep
//
//  Chainlink Automation solves all three:
//    • Decentralized keeper network (no single point of failure)
//    • Keepers are paid in LINK for each upkeep execution
//    • `checkUpkeep` / `performUpkeep` is the standard interface
//
//  ── HOW IT WORKS ────────────────────────────────────────────────────────────
//
//  1. Deploy this contract
//  2. Register it with Chainlink Automation Network (app.chain.link/automation)
//  3. Fund the upkeep with LINK
//  4. Chainlink nodes call checkUpkeep() every block
//  5. When it returns true, they call performUpkeep() which:
//       a. Calls compositor.updateRiskScore()  (refresh 4-pillar score)
//       b. Calls circuitBreaker.checkAndRespond()  (trigger alert if threshold crossed)
//       c. Emits UpkeepPerformed event
//
//  ── SAFETY ──────────────────────────────────────────────────────────────────
//
//  • performUpkeep re-validates conditions to prevent stale upkeep execution
//  • Owner can pause/unpause without unregistering from Automation
//  • Cooldown check prevents redundant circuit breaker triggers
//
// ============================================================================

interface ICompositorForAutomation {
    function updateRiskScore() external returns (uint256, uint8, uint256);
    function getRiskScore() external view returns (uint256);
}

interface ICircuitBreakerForAutomation {
    function checkAndRespond() external returns (bool levelChanged);
    function isInCooldown() external view returns (bool);
    function currentLevel() external view returns (uint8);
}

/// @title AutomatedRiskUpdater
/// @notice Chainlink Automation keeper for DeFiStressOracle risk updates.
contract AutomatedRiskUpdater is AutomationCompatibleInterface {
    // =========================================================================
    // Events
    // =========================================================================

    event UpkeepPerformed(
        uint256 indexed timestamp,
        uint256 compositeScore,
        uint8   alertLevel,
        bool    levelChanged
    );

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event IntervalUpdated(uint256 oldInterval, uint256 newInterval);

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The UnifiedRiskCompositor to update.
    ICompositorForAutomation public immutable compositor;

    /// @notice The circuit breaker to trigger after score update.
    ICircuitBreakerForAutomation public immutable circuitBreaker;

    /// @notice Owner address (can pause/unpause, update interval).
    address public immutable owner;

    /// @notice Minimum seconds between upkeep executions.
    uint256 public updateIntervalSeconds;

    /// @notice Timestamp of the last successful performUpkeep.
    uint256 public lastUpkeepTimestamp;

    /// @notice Total number of upkeeps performed.
    uint256 public upkeepCount;

    /// @notice Whether upkeep is paused by owner.
    bool public paused;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _compositor          UnifiedRiskCompositor address
    /// @param _circuitBreaker      LendingProtocolCircuitBreaker address
    /// @param _intervalSeconds     Minimum seconds between upkeeps (e.g. 300 = 5 min)
    constructor(
        address _compositor,
        address _circuitBreaker,
        uint256 _intervalSeconds
    ) {
        require(_compositor     != address(0), "ARU: zero compositor");
        require(_circuitBreaker != address(0), "ARU: zero circuit breaker");
        require(_intervalSeconds >= 60,        "ARU: min 60s interval");

        compositor            = ICompositorForAutomation(_compositor);
        circuitBreaker        = ICircuitBreakerForAutomation(_circuitBreaker);
        updateIntervalSeconds = _intervalSeconds;
        owner                 = msg.sender;
    }

    // =========================================================================
    // Chainlink Automation Interface
    // =========================================================================

    /// @notice Called by Chainlink Automation nodes every block to check
    ///         whether an upkeep is needed.
    /// @return upkeepNeeded  true → Automation will call performUpkeep()
    /// @return performData   encoded data passed to performUpkeep (empty here)
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded =
            !paused &&
            block.timestamp >= lastUpkeepTimestamp + updateIntervalSeconds &&
            !circuitBreaker.isInCooldown();

        performData = bytes("");
    }

    /// @notice Called by Chainlink Automation nodes when checkUpkeep returns true.
    ///         Updates the risk score and triggers circuit breaker response.
    function performUpkeep(bytes calldata) external override {
        // Re-validate conditions to guard against stale upkeep
        require(!paused, "ARU: paused");
        require(
            block.timestamp >= lastUpkeepTimestamp + updateIntervalSeconds,
            "ARU: too soon"
        );

        lastUpkeepTimestamp = block.timestamp;
        upkeepCount++;

        // Step 1: Refresh all 4 pillar scores and composite
        (uint256 compositeScore,,) = compositor.updateRiskScore();

        // Step 2: Trigger circuit breaker response if threshold crossed
        bool levelChanged = false;
        if (!circuitBreaker.isInCooldown()) {
            levelChanged = circuitBreaker.checkAndRespond();
        }

        uint8 alertLevel = circuitBreaker.currentLevel();

        emit UpkeepPerformed(block.timestamp, compositeScore, alertLevel, levelChanged);
    }

    // =========================================================================
    // Owner Functions
    // =========================================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "ARU: not owner");
        _;
    }

    /// @notice Pause upkeep without unregistering from Automation Network.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume upkeep.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Update the minimum interval between upkeeps.
    function setUpdateInterval(uint256 newIntervalSeconds) external onlyOwner {
        require(newIntervalSeconds >= 60, "ARU: min 60s");
        emit IntervalUpdated(updateIntervalSeconds, newIntervalSeconds);
        updateIntervalSeconds = newIntervalSeconds;
    }

    // =========================================================================
    // View Helpers
    // =========================================================================

    /// @notice Seconds until the next upkeep is eligible.
    function secondsUntilNextUpkeep() external view returns (uint256) {
        uint256 nextEligible = lastUpkeepTimestamp + updateIntervalSeconds;
        if (block.timestamp >= nextEligible) return 0;
        return nextEligible - block.timestamp;
    }

    /// @notice Current composite risk score from compositor (no state change).
    function currentRiskScore() external view returns (uint256) {
        return compositor.getRiskScore();
    }

    /// @notice Whether upkeep conditions are currently met.
    function isUpkeepNeeded() external view returns (bool) {
        return
            !paused &&
            block.timestamp >= lastUpkeepTimestamp + updateIntervalSeconds &&
            !circuitBreaker.isInCooldown();
    }
}
