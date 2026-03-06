// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRiskConsumer
/// @notice Standard interface for protocols that consume DeFiStressOracle risk data.
///         Implement this to integrate automatic risk-based parameter adjustment.
/// @dev Any on-chain protocol (lending market, DEX, vault) should implement this
///      interface to be recognized by risk aggregators and automation networks.
interface IRiskConsumer {
    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when the risk score causes a parameter update.
    event RiskParamsUpdated(
        uint256 indexed compositeScore,
        uint256 oldLtvBps,
        uint256 newLtvBps,
        uint256 timestamp
    );

    /// @notice Emitted when the protocol enters a protected state.
    event ProtocolProtected(uint256 indexed triggerScore, string reason, uint256 timestamp);

    /// @notice Emitted when the protocol exits a protected state.
    event ProtectionLifted(uint256 indexed currentScore, uint256 timestamp);

    // =========================================================================
    // Core Interface
    // =========================================================================

    /// @notice Called by the risk compositor or automation to apply the latest score.
    /// @dev Implementations should call `urc.getRiskScore()` internally for the current
    ///      score and apply any necessary parameter changes.
    /// @return applied True if any parameters were actually changed.
    function applyRiskUpdate() external returns (bool applied);

    /// @notice Returns the address of the UnifiedRiskCompositor this protocol uses.
    function riskCompositor() external view returns (address);

    /// @notice Returns the current maximum LTV this protocol will accept (in BPS).
    /// @dev Should decrease as risk score increases.
    function currentMaxLtvBps() external view returns (uint256);

    /// @notice Returns whether the protocol has suspended any sensitive operations.
    /// @dev e.g., new borrows paused, new deposits halted, etc.
    function isProtectionActive() external view returns (bool);

    /// @notice Returns the risk score at which protection was last triggered.
    function lastTriggerScore() external view returns (uint256);
}

/// @title IRiskScoreProvider
/// @notice Interface that the risk aggregators expose to IRiskConsumers.
interface IRiskScoreProvider {
    /// @notice Backward compatibility for single-asset compositor.
    function getRiskScore() external view returns (uint256);
    
    /// @notice Returns the most recently computed composite score (0-100) for a specific asset.
    function getRiskScore(address asset) external view returns (uint256);

    /// @notice Returns the timestamp of the last score update.
    function lastUpdatedAt() external view returns (uint256);

    /// @notice Returns the timestamp of the last score update for a specific asset.
    function lastUpdatedAt(address asset) external view returns (uint256);
}
