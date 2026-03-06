import {
    Runner,
    CronCapability,
    handler,
    EVMClient,
    HTTPClient,
    getNetwork,
    encodeCallMsg,
    bytesToHex,
    type Runtime,
    type HTTPSendRequester,
    ok,
    json,
    LATEST_BLOCK_NUMBER,
    consensusMedianAggregation,
} from "@chainlink/cre-sdk";
import { type Address, decodeFunctionResult, encodeFunctionData, zeroAddress } from "viem";

const ASSET_REGISTRY_ABI = [
    {
        inputs: [],
        name: "getEnabledAssets",
        outputs: [{ internalType: "address[]", name: "", type: "address[]" }],
        stateMutability: "view",
        type: "function",
    },
] as const;

const MULTI_ASSET_ROUTER_ABI = [
    {
        inputs: [{ internalType: "address", name: "asset", type: "address" }],
        name: "assetRiskState",
        outputs: [
            { internalType: "uint256", name: "score", type: "uint256" },
            { internalType: "uint256", name: "mcoInput", type: "uint256" },
            { internalType: "uint256", name: "tdrvInput", type: "uint256" },
            { internalType: "uint256", name: "cpInput", type: "uint256" },
            { internalType: "uint256", name: "tcoInput", type: "uint256" },
            { internalType: "uint8", name: "tier", type: "uint8" },
            { internalType: "uint256", name: "recommendedLtvBps", type: "uint256" },
            { internalType: "uint256", name: "realizedVolBps", type: "uint256" },
            { internalType: "uint256", name: "manipulationCostUsd", type: "uint256" },
            { internalType: "uint256", name: "ewmaScore", type: "uint256" },
            { internalType: "uint256", name: "updatedAt", type: "uint256" },
        ],
        stateMutability: "view",
        type: "function",
    },
] as const;

const CIRCUIT_BREAKER_ABI = [
    {
        inputs: [],
        name: "currentLevel",
        outputs: [{ internalType: "uint8", name: "", type: "uint8" }],
        stateMutability: "view",
        type: "function",
    },
] as const;

const CCRB_ABI = [
    {
        inputs: [{ internalType: "uint64", name: "destChainSelector", type: "uint64" }],
        name: "estimateFee",
        outputs: [{ internalType: "uint256", name: "fee", type: "uint256" }],
        stateMutability: "view",
        type: "function",
    },
] as const;

type WorkflowAsset = {
    symbol: string;
    address: string;
    coingeckoId: string;
};

type Config = {
    evm: {
        chainSelectorName: string;
        assetRegistryAddress: string;
        multiAssetRouterAddress: string;
        circuitBreakerAddress: string;
        ccrbAddress: string;
        ccipDestinationSelector: string;
    };
    api: {
        priceUrlTemplate: string;
    };
    thresholds: {
        warningScore: number;
        emergencyScore: number;
        volatilityPct: number;
    };
    assets: WorkflowAsset[];
};

type RouterState = {
    score: number;
    tier: number;
    recommendedLtvBps: number;
    realizedVolBps: number;
    manipulationCostUsd: string;
    updatedAt: number;
};

type AssetDecision = {
    asset: string;
    symbol: string;
    onchainScore: number;
    onchainTier: number;
    recommendedLtvBps: number;
    realizedVolBps: number;
    manipulationCostUsd: string;
    offchainVolatilityPct: number;
    severity: number;
    updatedAt: number;
};

type WorkflowOutput = {
    timestamp: string;
    enabledAssetCount: number;
    circuitBreakerLevel: number;
    globalSeverity: number;
    recommendedAction: string;
    estimatedCcipFeeWei: string;
    assets: AssetDecision[];
};

type VolatilityRequest = {
    priceUrlTemplate: string;
    coingeckoId: string;
};

const makeEvmClient = (runtime: Runtime<Config>) => {
    const { chainSelectorName } = runtime.config.evm;
    const network = getNetwork({
        chainFamily: "evm",
        chainSelectorName,
        isTestnet: true,
    });
    if (!network) throw new Error(`Network ${chainSelectorName} not found`);
    return new EVMClient(network.chainSelector.selector);
};

const callView = (runtime: Runtime<Config>, contract: Address, data: `0x${string}`) =>
    makeEvmClient(runtime)
        .callContract(runtime, {
            call: encodeCallMsg({
                from: zeroAddress,
                to: contract,
                data,
            }),
            blockNumber: LATEST_BLOCK_NUMBER,
        })
        .result();

const readEnabledAssets = (runtime: Runtime<Config>): Address[] => {
    const callData = encodeFunctionData({
        abi: ASSET_REGISTRY_ABI,
        functionName: "getEnabledAssets",
        args: [],
    });
    const result = callView(runtime, runtime.config.evm.assetRegistryAddress as Address, callData);
    const decoded = decodeFunctionResult({
        abi: ASSET_REGISTRY_ABI,
        functionName: "getEnabledAssets",
        data: bytesToHex(result.data),
    }) as readonly Address[];
    return [...decoded];
};

const readRouterState = (runtime: Runtime<Config>, asset: Address): RouterState => {
    const callData = encodeFunctionData({
        abi: MULTI_ASSET_ROUTER_ABI,
        functionName: "assetRiskState",
        args: [asset],
    });
    const result = callView(runtime, runtime.config.evm.multiAssetRouterAddress as Address, callData);
    const decoded = decodeFunctionResult({
        abi: MULTI_ASSET_ROUTER_ABI,
        functionName: "assetRiskState",
        data: bytesToHex(result.data),
    }) as readonly [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];

    return {
        score: Number(decoded[0]),
        tier: Number(decoded[5]),
        recommendedLtvBps: Number(decoded[6]),
        realizedVolBps: Number(decoded[7]),
        manipulationCostUsd: decoded[8].toString(),
        updatedAt: Number(decoded[10]),
    };
};

const readCircuitBreakerLevel = (runtime: Runtime<Config>): number => {
    const callData = encodeFunctionData({
        abi: CIRCUIT_BREAKER_ABI,
        functionName: "currentLevel",
        args: [],
    });
    const result = callView(runtime, runtime.config.evm.circuitBreakerAddress as Address, callData);
    const decoded = decodeFunctionResult({
        abi: CIRCUIT_BREAKER_ABI,
        functionName: "currentLevel",
        data: bytesToHex(result.data),
    }) as bigint;
    return Number(decoded);
};

const estimateCcipFee = (runtime: Runtime<Config>): string => {
    const destinationSelector = BigInt(runtime.config.evm.ccipDestinationSelector);
    const callData = encodeFunctionData({
        abi: CCRB_ABI,
        functionName: "estimateFee",
        args: [destinationSelector],
    });
    const result = callView(runtime, runtime.config.evm.ccrbAddress as Address, callData);
    const decoded = decodeFunctionResult({
        abi: CCRB_ABI,
        functionName: "estimateFee",
        data: bytesToHex(result.data),
    }) as bigint;
    return decoded.toString();
};

const getOffchainVolatility = (sendRequester: HTTPSendRequester, request: VolatilityRequest) => {
    const url = request.priceUrlTemplate.replace("{id}", request.coingeckoId);
    const response = sendRequester.sendRequest({ url, method: "GET" }).result();
    if (!ok(response)) {
        throw new Error(`HTTP request failed (${response.statusCode}) for ${request.coingeckoId}`);
    }

    const data = json(response) as Record<string, { usd_24h_change?: number }>;
    const assetData = data[request.coingeckoId];
    if (!assetData || typeof assetData.usd_24h_change !== "number") {
        throw new Error(`Missing usd_24h_change for ${request.coingeckoId}`);
    }

    return Math.abs(assetData.usd_24h_change);
};

const assetKey = (address: string) => address.toLowerCase();
const shortAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;

const classifySeverity = (onchainScore: number, offchainVolatilityPct: number, config: Config): number => {
    const scoreSeverity = onchainScore >= config.thresholds.emergencyScore
        ? 3
        : onchainScore >= config.thresholds.warningScore
            ? 2
            : onchainScore >= Math.max(1, config.thresholds.warningScore - 20)
                ? 1
                : 0;

    const volSeverity = offchainVolatilityPct >= config.thresholds.volatilityPct * 2
        ? 2
        : offchainVolatilityPct >= config.thresholds.volatilityPct
            ? 1
            : 0;

    if (scoreSeverity >= 2 && volSeverity >= 1) return 3;
    return Math.max(scoreSeverity, volSeverity);
};

const actionForSeverity = (severity: number): string => {
    if (severity >= 3) return "broadcast_cross_chain_and_harden_ltv";
    if (severity === 2) return "tighten_ltv_and_raise_alert";
    if (severity === 1) return "monitor_closely";
    return "none";
};

const onTrigger = async (runtime: Runtime<Config>): Promise<WorkflowOutput> => {
    runtime.log("risk-orchestrator: start");

    const enabledAssets = readEnabledAssets(runtime);
    runtime.log(`enabled assets discovered: ${enabledAssets.length}`);

    const metadataByAsset = new Map(runtime.config.assets.map((asset) => [assetKey(asset.address), asset]));
    const httpClient = new HTTPClient();
    const decisions: AssetDecision[] = [];

    for (const asset of enabledAssets) {
        const state = readRouterState(runtime, asset);
        const meta = metadataByAsset.get(assetKey(asset));

        let offchainVolatilityPct = 0;
        if (meta?.coingeckoId) {
            try {
                offchainVolatilityPct = await httpClient
                    .sendRequest(runtime, getOffchainVolatility, consensusMedianAggregation())({
                        priceUrlTemplate: runtime.config.api.priceUrlTemplate,
                        coingeckoId: meta.coingeckoId,
                    })
                    .result();
            } catch (error) {
                runtime.log(`offchain volatility fetch failed for ${meta.symbol}: ${String(error)}`);
            }
        }

        const severity = classifySeverity(state.score, offchainVolatilityPct, runtime.config);
        const decision: AssetDecision = {
            asset,
            symbol: meta?.symbol ?? shortAddress(asset),
            onchainScore: state.score,
            onchainTier: state.tier,
            recommendedLtvBps: state.recommendedLtvBps,
            realizedVolBps: state.realizedVolBps,
            manipulationCostUsd: state.manipulationCostUsd,
            offchainVolatilityPct,
            severity,
            updatedAt: state.updatedAt,
        };

        decisions.push(decision);
        runtime.log(
            `[${decision.symbol}] score=${decision.onchainScore} tier=${decision.onchainTier} `
                + `vol24h=${decision.offchainVolatilityPct.toFixed(2)}% severity=${decision.severity}`,
        );
    }

    decisions.sort((a, b) => {
        if (b.severity !== a.severity) return b.severity - a.severity;
        return b.onchainScore - a.onchainScore;
    });

    const globalSeverity = decisions.length === 0 ? 0 : decisions[0].severity;
    let breakerLevel = 0;
    try {
        breakerLevel = readCircuitBreakerLevel(runtime);
    } catch (error) {
        runtime.log(`could not read circuit breaker level: ${String(error)}`);
    }

    let estimatedCcipFeeWei = "0";
    if (globalSeverity >= 2) {
        try {
            estimatedCcipFeeWei = estimateCcipFee(runtime);
            runtime.log(`ccip fee estimate for alert path: ${estimatedCcipFeeWei} wei`);
        } catch (error) {
            runtime.log(`ccip fee estimate failed: ${String(error)}`);
        }
    }

    const output: WorkflowOutput = {
        timestamp: runtime.now().toISOString(),
        enabledAssetCount: decisions.length,
        circuitBreakerLevel: breakerLevel,
        globalSeverity,
        recommendedAction: actionForSeverity(globalSeverity),
        estimatedCcipFeeWei,
        assets: decisions,
    };

    runtime.log(
        `global severity=${output.globalSeverity} action=${output.recommendedAction} `
            + `enabled_assets=${output.enabledAssetCount}`,
    );
    return output;
};

export async function main() {
    const runner = await Runner.newRunner<Config>();
    await runner.run(() => {
        const cron = new CronCapability();
        const trigger = cron.trigger({ schedule: "0 */5 * * * *" });
        return [handler(trigger, onTrigger)];
    });
}
