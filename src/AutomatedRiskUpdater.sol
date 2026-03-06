// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

interface IMultiAssetRiskRouterForAutomation {
    function updateRiskForAssets(address[] calldata assets) external returns (uint256 updatedCount, uint256 failedCount);
}

interface IAssetRegistryForAutomation {
    function getSupportedAssets() external view returns (address[] memory);
    function getEnabledAssets() external view returns (address[] memory);
}

interface ICircuitBreakerForAutomation {
    function checkAndRespond() external returns (bool levelChanged);
    function isInCooldown() external view returns (bool);
    function currentLevel() external view returns (uint8);
}

/// @title AutomatedRiskUpdater
/// @notice Chainlink Automation keeper that updates multi-asset risk in bounded batches.
contract AutomatedRiskUpdater is AutomationCompatibleInterface {
    event UpkeepPerformed(
        uint256 indexed timestamp,
        uint256 assetsAttempted,
        uint256 assetsUpdated,
        uint256 assetsFailed,
        uint8 alertLevel,
        bool levelChanged
    );
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event IntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event BatchSizeUpdated(uint256 oldBatchSize, uint256 newBatchSize);

    IMultiAssetRiskRouterForAutomation public immutable router;
    IAssetRegistryForAutomation public immutable registry;
    ICircuitBreakerForAutomation public immutable circuitBreaker;
    address public immutable owner;

    uint256 public updateIntervalSeconds;
    uint256 public batchSize;
    uint256 public nextAssetIndex;
    uint256 public lastUpkeepTimestamp;
    uint256 public upkeepCount;
    bool public paused;

    constructor(
        address _router,
        address _registry,
        address _circuitBreaker,
        uint256 _intervalSeconds
    ) {
        require(_router != address(0), "ARU: zero router");
        require(_registry != address(0), "ARU: zero registry");
        require(_intervalSeconds >= 60, "ARU: min 60s interval");

        router = IMultiAssetRiskRouterForAutomation(_router);
        registry = IAssetRegistryForAutomation(_registry);
        circuitBreaker = ICircuitBreakerForAutomation(_circuitBreaker);
        updateIntervalSeconds = _intervalSeconds;
        batchSize = 4;
        owner = msg.sender;
    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused) return (false, bytes(""));
        if (block.timestamp < lastUpkeepTimestamp + updateIntervalSeconds) return (false, bytes(""));

        if (address(circuitBreaker) != address(0) && circuitBreaker.isInCooldown()) {
            return (false, bytes(""));
        }

        address[] memory assets = _getEligibleAssets();
        if (assets.length == 0) return (false, bytes(""));

        upkeepNeeded = true;
        performData = abi.encode(nextAssetIndex, assets.length);
    }

    function performUpkeep(bytes calldata) external override {
        require(!paused, "ARU: paused");
        require(block.timestamp >= lastUpkeepTimestamp + updateIntervalSeconds, "ARU: too soon");

        address[] memory assets = _getEligibleAssets();
        uint256 attempted;
        uint256 updated;
        uint256 failed;

        if (assets.length > 0) {
            (address[] memory batch, uint256 newCursor) = _nextBatch(assets, nextAssetIndex, batchSize);
            attempted = batch.length;
            nextAssetIndex = newCursor;

            try router.updateRiskForAssets(batch) returns (uint256 ok, uint256 bad) {
                updated = ok;
                failed = bad;
            } catch {
                // If router call fails unexpectedly, count the full batch as failed.
                failed = attempted;
            }
        } else {
            nextAssetIndex = 0;
        }

        lastUpkeepTimestamp = block.timestamp;
        upkeepCount++;

        bool levelChanged = false;
        uint8 alertLevel = 0;
        if (address(circuitBreaker) != address(0)) {
            if (!circuitBreaker.isInCooldown()) {
                levelChanged = circuitBreaker.checkAndRespond();
            }
            alertLevel = circuitBreaker.currentLevel();
        }

        emit UpkeepPerformed(block.timestamp, attempted, updated, failed, alertLevel, levelChanged);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "ARU: not owner");
        _;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setUpdateInterval(uint256 newIntervalSeconds) external onlyOwner {
        require(newIntervalSeconds >= 60, "ARU: min 60s");
        emit IntervalUpdated(updateIntervalSeconds, newIntervalSeconds);
        updateIntervalSeconds = newIntervalSeconds;
    }

    function setBatchSize(uint256 newBatchSize) external onlyOwner {
        require(newBatchSize > 0 && newBatchSize <= 64, "ARU: bad batch");
        emit BatchSizeUpdated(batchSize, newBatchSize);
        batchSize = newBatchSize;
    }

    function secondsUntilNextUpkeep() external view returns (uint256) {
        uint256 nextTime = lastUpkeepTimestamp + updateIntervalSeconds;
        if (block.timestamp >= nextTime) return 0;
        return nextTime - block.timestamp;
    }

    function _getEligibleAssets() internal view returns (address[] memory assets) {
        // Preferred path for modern registries.
        try registry.getEnabledAssets() returns (address[] memory enabled) {
            return enabled;
        } catch {
            // Backward compatibility for older registry interfaces.
            return registry.getSupportedAssets();
        }
    }

    function _nextBatch(address[] memory assets, uint256 cursor, uint256 maxBatch)
        internal
        pure
        returns (address[] memory batch, uint256 newCursor)
    {
        uint256 total = assets.length;
        uint256 n = maxBatch < total ? maxBatch : total;
        batch = new address[](n);

        uint256 start = total == 0 ? 0 : cursor % total;
        for (uint256 i = 0; i < n; ) {
            batch[i] = assets[(start + i) % total];
            unchecked {
                ++i;
            }
        }

        if (total == 0) return (batch, 0);
        newCursor = (start + n) % total;
    }
}

