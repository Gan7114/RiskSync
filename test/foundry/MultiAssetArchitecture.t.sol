// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {MultiAssetRiskRouter} from "../../src/MultiAssetRiskRouter.sol";
import {AutomatedRiskUpdater} from "../../src/AutomatedRiskUpdater.sol";

contract MockMCOForRouter {
    mapping(address => uint256) public baseCostUsdByPool;
    mapping(address => uint256) public securityScoreByPool;
    mapping(address => bool) public shouldRevertByPool;

    function setPoolResult(address pool, uint256 baseCostUsd, uint256 securityScore) external {
        baseCostUsdByPool[pool] = baseCostUsd;
        securityScoreByPool[pool] = securityScore;
    }

    function setShouldRevert(address pool, bool value) external {
        shouldRevertByPool[pool] = value;
    }

    function getManipulationCostForPool(address pool, address, uint256)
        external
        view
        returns (uint256 costUsd, uint256 securityScore)
    {
        if (shouldRevertByPool[pool]) revert("MCO_REVERT");
        return (baseCostUsdByPool[pool], securityScoreByPool[pool]);
    }

    function getManipulationCostForPool(address pool, address, uint256, uint8 decimals)
        external
        view
        returns (uint256 costUsd, uint256 securityScore)
    {
        if (shouldRevertByPool[pool]) revert("MCO_REVERT");
        costUsd = baseCostUsdByPool[pool] + (uint256(decimals) * 1e8);
        securityScore = securityScoreByPool[pool];
    }

    function getManipulationCostForPoolWithDecimals(address pool, address, uint256, uint8 decimals)
        external
        view
        returns (uint256 costUsd, uint256 securityScore)
    {
        if (shouldRevertByPool[pool]) revert("MCO_REVERT");
        costUsd = baseCostUsdByPool[pool] + (uint256(decimals) * 1e8);
        securityScore = securityScoreByPool[pool];
    }
}

contract MockTDRVForRouter {
    mapping(address => uint256) public volScoreByPool;
    mapping(address => uint256) public realizedVolByPool;
    mapping(address => bool) public shouldRevertByPool;

    function setPoolData(address pool, uint256 volScore, uint256 realizedVolBps) external {
        volScoreByPool[pool] = volScore;
        realizedVolByPool[pool] = realizedVolBps;
    }

    function setShouldRevert(address pool, bool value) external {
        shouldRevertByPool[pool] = value;
    }

    function getVolatilityScoreForPool(address pool, uint32, uint8, uint256, uint256)
        external
        view
        returns (uint256 volScore)
    {
        if (shouldRevertByPool[pool]) revert("TDRV_REVERT");
        return volScoreByPool[pool];
    }

    function getRealizedVolatilityForPool(address pool, uint32, uint8)
        external
        view
        returns (uint256 annualizedVolBps)
    {
        if (shouldRevertByPool[pool]) revert("TDRV_REVERT");
        return realizedVolByPool[pool];
    }
}

contract MockCPLCSForRouter {
    mapping(address => uint256) public scoreByAsset;
    mapping(address => uint256) public collateralUsdByAsset;
    mapping(address => bool) public shouldRevertByAsset;

    function setAssetData(address asset, uint256 score, uint256 collateralUsd) external {
        scoreByAsset[asset] = score;
        collateralUsdByAsset[asset] = collateralUsd;
    }

    function setShouldRevert(address asset, bool value) external {
        shouldRevertByAsset[asset] = value;
    }

    function getCascadeScore(address asset, uint256 shockBps)
        external
        view
        returns (
            uint256 totalCollateralUsd,
            uint256 estimatedLiquidationUsd,
            uint256 secondaryPriceImpactBps,
            uint256 totalImpactBps,
            uint256 amplificationBps,
            uint256 cascadeScore
        )
    {
        if (shouldRevertByAsset[asset]) revert("CPLCS_REVERT");

        totalCollateralUsd = collateralUsdByAsset[asset];
        estimatedLiquidationUsd = totalCollateralUsd / 10;
        secondaryPriceImpactBps = shockBps / 5;
        totalImpactBps = shockBps + secondaryPriceImpactBps;
        amplificationBps = 10_000 + secondaryPriceImpactBps;
        cascadeScore = scoreByAsset[asset];
    }
}

contract MockTCOForRouter {
    mapping(address => uint256) public scoreByPool;
    mapping(address => bool) public shouldRevertByPool;

    function setPoolScore(address pool, uint256 score) external {
        scoreByPool[pool] = score;
    }

    function setShouldRevert(address pool, bool value) external {
        shouldRevertByPool[pool] = value;
    }

    function getConcentrationScoreForPool(address pool, uint32, uint8) external view returns (uint256) {
        if (shouldRevertByPool[pool]) revert("TCO_REVERT");
        return scoreByPool[pool];
    }
}

contract MockRouterBatch {
    uint256 public callCount;
    uint256 public lastBatchCount;
    address public lastFirstAsset;
    mapping(address => bool) public shouldFail;

    function setFail(address asset, bool value) external {
        shouldFail[asset] = value;
    }

    function updateRiskForAssets(address[] calldata assets) external returns (uint256 updatedCount, uint256 failedCount) {
        callCount++;
        lastBatchCount = assets.length;
        lastFirstAsset = assets.length > 0 ? assets[0] : address(0);

        for (uint256 i = 0; i < assets.length; ) {
            if (shouldFail[assets[i]]) {
                failedCount++;
            } else {
                updatedCount++;
            }
            unchecked {
                ++i;
            }
        }
    }
}

contract MockRegistryBatch {
    address[] private _assets;

    function setAssets(address[] memory assets_) external {
        _assets = assets_;
    }

    function getSupportedAssets() external view returns (address[] memory) {
        return _assets;
    }

    function getEnabledAssets() external view returns (address[] memory) {
        return _assets;
    }
}

contract MockCircuitBreakerBatch {
    bool public inCooldown;
    uint8 public level;
    bool public levelChanged;
    uint256 public checks;

    function setCooldown(bool value) external {
        inCooldown = value;
    }

    function setLevel(uint8 value) external {
        level = value;
    }

    function setLevelChanged(bool value) external {
        levelChanged = value;
    }

    function checkAndRespond() external returns (bool) {
        checks++;
        return levelChanged;
    }

    function isInCooldown() external view returns (bool) {
        return inCooldown;
    }

    function currentLevel() external view returns (uint8) {
        return level;
    }
}

contract MultiAssetRegistryAndRouterTest is Test {
    AssetRegistry internal registry;
    MockMCOForRouter internal mco;
    MockTDRVForRouter internal tdrv;
    MockCPLCSForRouter internal cplcs;
    MockTCOForRouter internal tco;
    MultiAssetRiskRouter internal router;

    address internal constant ASSET_ETH = address(0xE1);
    address internal constant ASSET_BTC = address(0xB1);
    address internal constant ASSET_LINK = address(0xC1);
    address internal constant POOL_ETH = address(0x1001);
    address internal constant POOL_BTC = address(0x1002);
    address internal constant FEED_ETH = address(0x2001);
    address internal constant FEED_BTC = address(0x2002);

    bytes4 internal constant OWNABLE_UNAUTHORIZED = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    function setUp() public {
        vm.warp(50_000);

        registry = new AssetRegistry();
        mco = new MockMCOForRouter();
        tdrv = new MockTDRVForRouter();
        cplcs = new MockCPLCSForRouter();
        tco = new MockTCOForRouter();

        router = new MultiAssetRiskRouter(
            address(registry),
            address(mco),
            address(tdrv),
            address(cplcs),
            address(tco),
            30,
            35,
            20,
            15
        );

        mco.setPoolResult(POOL_ETH, 0, 0);
        mco.setPoolResult(POOL_BTC, 0, 0);
        tdrv.setPoolData(POOL_ETH, 20, 4_200);
        tdrv.setPoolData(POOL_BTC, 45, 7_800);
        cplcs.setAssetData(ASSET_ETH, 30, 5_000_000 * 1e8);
        cplcs.setAssetData(ASSET_BTC, 55, 6_000_000 * 1e8);
        tco.setPoolScore(POOL_ETH, 40);
        tco.setPoolScore(POOL_BTC, 25);

        registry.addAsset(ASSET_ETH, POOL_ETH, FEED_ETH, 18, 2_000, 10 * 1e8, 30 * 1e8);
        registry.addAsset(ASSET_BTC, POOL_BTC, FEED_BTC, 6, 2_000, 10 * 1e8, 30 * 1e8);
    }

    function test_registryCrudAndAccessControl() public {
        address assetAave = address(0xAA01);
        address poolAave = address(0xAA02);
        address feedAave = address(0xAA03);

        registry.addAsset(assetAave, poolAave, feedAave, 18, 2_500, 15 * 1e8, 60 * 1e8);
        AssetRegistry.AssetConfig memory cfg = registry.getConfig(assetAave);
        assertTrue(cfg.enabled);
        assertEq(cfg.pool, poolAave);
        assertEq(cfg.feed, feedAave);

        registry.updateAsset(assetAave, address(0xAA22), address(0xAA33), 6, 3_000, 20 * 1e8, 80 * 1e8);
        cfg = registry.getConfig(assetAave);
        assertEq(cfg.pool, address(0xAA22));
        assertEq(cfg.feed, address(0xAA33));
        assertEq(cfg.token1Decimals, 6);

        registry.disableAsset(assetAave);
        assertFalse(registry.getConfig(assetAave).enabled);
        registry.enableAsset(assetAave);
        assertTrue(registry.getConfig(assetAave).enabled);

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED, address(0xBEEF)));
        registry.addAsset(address(0xC0FFEE), address(0xC1), address(0xC2), 18, 2_000, 1, 2);
    }

    function test_routerSingleUpdateCachesExpectedRiskState() public {
        (uint256 score, MultiAssetRiskRouter.RiskTier tier, uint256 ltv) = router.updateRiskForAsset(ASSET_ETH);
        assertEq(score, 37, "weighted score mismatch");
        assertEq(uint8(tier), uint8(MultiAssetRiskRouter.RiskTier.MODERATE), "tier mismatch");
        assertEq(ltv, 7_500, "ltv mismatch");

        (
            uint256 cachedScore,
            uint256 mcoInput,
            uint256 tdrvInput,
            uint256 cpInput,
            uint256 tcoInput,
            ,
            uint256 cachedLtv,
            uint256 realizedVolBps,
            uint256 manipulationCostUsd,
            uint256 ewmaScore,
            uint256 updatedAt
        ) = router.assetRiskState(ASSET_ETH);

        assertEq(cachedScore, score);
        assertEq(mcoInput, 60, "MCO input should reflect 18-decimal path");
        assertEq(tdrvInput, 20);
        assertEq(cpInput, 30);
        assertEq(tcoInput, 40);
        assertEq(cachedLtv, ltv);
        assertEq(realizedVolBps, 4_200);
        assertEq(manipulationCostUsd, 18 * 1e8);
        assertEq(ewmaScore, score);
        assertEq(updatedAt, block.timestamp);
    }

    function test_routerBatchUpdateIsolatesFailures() public {
        registry.disableAsset(ASSET_BTC);

        address[] memory assets = new address[](2);
        assets[0] = ASSET_ETH;
        assets[1] = ASSET_BTC;

        (uint256 updated, uint256 failed) = router.updateRiskForAssets(assets);
        assertEq(updated, 1);
        assertEq(failed, 1);

        (, , , , , , , , , , uint256 tsEth) = router.assetRiskState(ASSET_ETH);
        (, , , , , , , , , , uint256 tsBtc) = router.assetRiskState(ASSET_BTC);
        assertGt(tsEth, 0, "enabled asset should update");
        assertEq(tsBtc, 0, "disabled asset should stay untouched");
    }

    function test_routerPerAssetDecimalsAffectMcoInput() public {
        AssetRegistry.AssetConfig memory linkCfg = AssetRegistry.AssetConfig({
            asset: ASSET_LINK,
            pool: POOL_ETH,
            feed: FEED_ETH,
            token1Decimals: 6,
            shockBps: 2_000,
            mcoThresholdLow: 10 * 1e8,
            mcoThresholdHigh: 30 * 1e8,
            enabled: true
        });
        registry.addAssetConfig(linkCfg);

        MultiAssetRiskRouter mcoOnlyRouter = new MultiAssetRiskRouter(
            address(registry),
            address(mco),
            address(tdrv),
            address(cplcs),
            address(tco),
            100,
            0,
            0,
            0
        );

        mcoOnlyRouter.updateRiskForAsset(ASSET_ETH); // 18 decimals -> cost=18e8 -> score=40 -> input=60
        mcoOnlyRouter.updateRiskForAsset(ASSET_LINK); // 6 decimals -> cost=6e8 -> score=0 -> input=100

        (, uint256 ethMcoInput, , , , , , , , , ) = mcoOnlyRouter.assetRiskState(ASSET_ETH);
        (, uint256 linkMcoInput, , , , , , , , , ) = mcoOnlyRouter.assetRiskState(ASSET_LINK);
        assertEq(ethMcoInput, 60);
        assertEq(linkMcoInput, 100);
    }

    function test_disabledAssetHandlingRevertsSingleUpdate() public {
        registry.disableAsset(ASSET_ETH);
        vm.expectRevert(MultiAssetRiskRouter.AssetNotEnabled.selector);
        router.updateRiskForAsset(ASSET_ETH);
    }

    function test_registryEnabledAssetsFilter() public {
        registry.disableAsset(ASSET_BTC);
        address[] memory enabled = registry.getEnabledAssets();
        assertEq(enabled.length, 1);
        assertEq(enabled[0], ASSET_ETH);
    }
}

contract AutomatedRiskUpdaterBatchingTest is Test {
    MockRouterBatch internal router;
    MockRegistryBatch internal registry;
    MockCircuitBreakerBatch internal cb;
    AutomatedRiskUpdater internal aru;

    address internal constant A1 = address(0xA1);
    address internal constant A2 = address(0xA2);
    address internal constant A3 = address(0xA3);
    address internal constant A4 = address(0xA4);

    function setUp() public {
        vm.warp(100_000);

        router = new MockRouterBatch();
        registry = new MockRegistryBatch();
        cb = new MockCircuitBreakerBatch();

        aru = new AutomatedRiskUpdater(address(router), address(registry), address(cb), 300);
    }

    function test_performUpkeepBatchesAndRotatesCursor() public {
        address[] memory assets = new address[](4);
        assets[0] = A1;
        assets[1] = A2;
        assets[2] = A3;
        assets[3] = A4;
        registry.setAssets(assets);

        aru.setBatchSize(2);
        aru.performUpkeep("");

        assertEq(router.callCount(), 1);
        assertEq(router.lastBatchCount(), 2);
        assertEq(router.lastFirstAsset(), A1);
        assertEq(aru.nextAssetIndex(), 2);

        vm.warp(block.timestamp + 301);
        aru.performUpkeep("");

        assertEq(router.callCount(), 2);
        assertEq(router.lastBatchCount(), 2);
        assertEq(router.lastFirstAsset(), A3);
        assertEq(aru.nextAssetIndex(), 0);
    }

    function test_performUpkeepIsFailureTolerant() public {
        address[] memory assets = new address[](3);
        assets[0] = A1;
        assets[1] = A2;
        assets[2] = A3;
        registry.setAssets(assets);
        router.setFail(A2, true);
        aru.setBatchSize(3);

        aru.performUpkeep("");

        assertEq(router.callCount(), 1);
        assertEq(router.lastBatchCount(), 3);
        assertEq(aru.upkeepCount(), 1);
        assertEq(cb.checks(), 1);
    }

    function test_checkUpkeepRespectsCooldownAndAssetAvailability() public {
        (bool needed,) = aru.checkUpkeep("");
        assertFalse(needed, "empty registry should not trigger upkeep");

        address[] memory assets = new address[](1);
        assets[0] = A1;
        registry.setAssets(assets);

        cb.setCooldown(true);
        (needed,) = aru.checkUpkeep("");
        assertFalse(needed, "circuit breaker cooldown should block upkeep");

        cb.setCooldown(false);
        (needed,) = aru.checkUpkeep("");
        assertTrue(needed, "eligible assets with no cooldown should trigger upkeep");
    }
}
