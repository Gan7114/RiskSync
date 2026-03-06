// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AssetRegistry
/// @notice Owner-managed asset configurations consumed by MultiAssetRiskRouter.
contract AssetRegistry is Ownable {
    struct AssetConfig {
        address asset;
        address pool;             // Uniswap V3 pool used by MCO/TDRV/TCO
        address feed;             // Chainlink USD feed for token1
        uint8 token1Decimals;     // Decimals of pool token1
        uint256 shockBps;         // Cascade shock (BPS) for CPLCS
        uint256 mcoThresholdLow;  // USD 1e8 scale
        uint256 mcoThresholdHigh; // USD 1e8 scale
        bool enabled;             // Eligible for router updates
    }

    uint256 public constant MAX_BPS = 10_000;

    error AssetAlreadyExists();
    error AssetDoesNotExist();
    error InvalidConfig();
    error ZeroAsset();

    event AssetAdded(address indexed asset, address pool, address feed, bool enabled);
    event AssetUpdated(address indexed asset, address pool, address feed, bool enabled);
    event AssetDisabled(address indexed asset);
    event AssetEnabled(address indexed asset);

    mapping(address => AssetConfig) private _configs;
    mapping(address => bool) private _exists;
    address[] private _supportedAssets;

    constructor() Ownable(msg.sender) { }

    /// @notice Add a newly tracked asset to the registry.
    function addAsset(
        address _asset,
        address _pool,
        address _feed,
        uint8 _token1Decimals,
        uint256 _shockBps,
        uint256 _mcoLow,
        uint256 _mcoHigh
    ) external onlyOwner {
        AssetConfig memory cfg = AssetConfig({
            asset: _asset,
            pool: _pool,
            feed: _feed,
            token1Decimals: _token1Decimals,
            shockBps: _shockBps,
            mcoThresholdLow: _mcoLow,
            mcoThresholdHigh: _mcoHigh,
            enabled: true
        });
        _addAsset(cfg);
    }

    /// @notice Add a new asset with full explicit config (supports disabled placeholders).
    function addAssetConfig(AssetConfig calldata cfg) external onlyOwner {
        _addAsset(cfg);
    }

    /// @notice Update an existing asset configuration.
    function updateAsset(
        address _asset,
        address _pool,
        address _feed,
        uint8 _token1Decimals,
        uint256 _shockBps,
        uint256 _mcoLow,
        uint256 _mcoHigh
    ) external onlyOwner {
        AssetConfig memory cfg = AssetConfig({
            asset: _asset,
            pool: _pool,
            feed: _feed,
            token1Decimals: _token1Decimals,
            shockBps: _shockBps,
            mcoThresholdLow: _mcoLow,
            mcoThresholdHigh: _mcoHigh,
            enabled: _configs[_asset].enabled
        });
        _updateAsset(cfg);
    }

    /// @notice Update all fields, including enabled state.
    function updateAssetConfig(AssetConfig calldata cfg) external onlyOwner {
        _updateAsset(cfg);
    }

    /// @notice Disable risk updates for an asset.
    function disableAsset(address _asset) external onlyOwner {
        if (!_exists[_asset]) revert AssetDoesNotExist();
        if (!_configs[_asset].enabled) return;
        _configs[_asset].enabled = false;
        emit AssetDisabled(_asset);
    }

    /// @notice Re-enable risk updates for an asset.
    function enableAsset(address _asset) external onlyOwner {
        if (!_exists[_asset]) revert AssetDoesNotExist();
        AssetConfig memory cfg = _configs[_asset];
        cfg.enabled = true;
        _validateConfig(cfg);
        _configs[_asset].enabled = true;
        emit AssetEnabled(_asset);
    }

    /// @notice Return all assets known to the registry.
    function getSupportedAssets() external view returns (address[] memory) {
        return _supportedAssets;
    }

    /// @notice Return only enabled assets.
    function getEnabledAssets() external view returns (address[] memory enabledAssets) {
        uint256 total = _supportedAssets.length;
        enabledAssets = new address[](total);
        uint256 n;
        for (uint256 i = 0; i < total; ) {
            address asset = _supportedAssets[i];
            if (_configs[asset].enabled) {
                enabledAssets[n] = asset;
                n++;
            }
            unchecked {
                ++i;
            }
        }

        assembly {
            mstore(enabledAssets, n)
        }
    }

    /// @notice Return the full configuration for an asset.
    function getConfig(address _asset) external view returns (AssetConfig memory cfg) {
        if (!_exists[_asset]) revert AssetDoesNotExist();
        return _configs[_asset];
    }

    function exists(address _asset) external view returns (bool) {
        return _exists[_asset];
    }

    function _addAsset(AssetConfig memory cfg) internal {
        if (cfg.asset == address(0)) revert ZeroAsset();
        if (_exists[cfg.asset]) revert AssetAlreadyExists();
        cfg.token1Decimals = _normalizeDecimals(cfg.token1Decimals);
        cfg.shockBps = _normalizeShock(cfg.shockBps);
        _validateConfig(cfg);

        _exists[cfg.asset] = true;
        _configs[cfg.asset] = cfg;
        _supportedAssets.push(cfg.asset);

        emit AssetAdded(cfg.asset, cfg.pool, cfg.feed, cfg.enabled);
    }

    function _updateAsset(AssetConfig memory cfg) internal {
        if (!_exists[cfg.asset]) revert AssetDoesNotExist();
        cfg.token1Decimals = _normalizeDecimals(cfg.token1Decimals);
        cfg.shockBps = _normalizeShock(cfg.shockBps);
        _validateConfig(cfg);

        _configs[cfg.asset] = cfg;
        emit AssetUpdated(cfg.asset, cfg.pool, cfg.feed, cfg.enabled);
    }

    function _validateConfig(AssetConfig memory cfg) internal pure {
        if (cfg.asset == address(0)) revert ZeroAsset();
        if (cfg.token1Decimals == 0 || cfg.token1Decimals > 30) revert InvalidConfig();
        if (cfg.shockBps == 0 || cfg.shockBps > MAX_BPS) revert InvalidConfig();
        if (cfg.mcoThresholdLow >= cfg.mcoThresholdHigh || cfg.mcoThresholdLow == 0) revert InvalidConfig();

        // Enabled assets must be fully wired. Disabled placeholders may omit infra.
        if (cfg.enabled) {
            if (cfg.pool == address(0) || cfg.feed == address(0)) revert InvalidConfig();
        }
    }

    function _normalizeDecimals(uint8 dec) internal pure returns (uint8) {
        return dec == 0 ? uint8(18) : dec;
    }

    function _normalizeShock(uint256 shockBps) internal pure returns (uint256) {
        return shockBps == 0 ? uint256(2_000) : shockBps;
    }
}
