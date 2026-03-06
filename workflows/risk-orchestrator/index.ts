import {
    cre,
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

/**
 * Preferred URC ABI (current contract): getRiskBreakdown() with no args.
 */
const URC_BREAKDOWN_ABI = [
    {
        inputs: [],
        name: "getRiskBreakdown",
        outputs: [
            { internalType: "uint256", name: "compositeScore", type: "uint256" },
            { internalType: "uint256", name: "mcoScore", type: "uint256" },
            { internalType: "uint256", name: "tdrvScore", type: "uint256" },
            { internalType: "uint256", name: "cplcsScore", type: "uint256" },
            { internalType: "uint8", name: "tier", type: "uint8" },
            { internalType: "uint256", name: "recommendedLtvBps", type: "uint256" },
            { internalType: "uint256", name: "realizedVolBps", type: "uint256" },
            { internalType: "uint256", name: "manipulationCostUsd", type: "uint256" },
            { internalType: "uint256", name: "updatedAt", type: "uint256" },
        ],
        stateMutability: "view",
        type: "function",
    },
] as const;

/**
 * Legacy URC ABI (older deployments): getRiskBreakdown(address asset).
 * Kept for backward compatibility across already-deployed URC versions.
 */
const URC_BREAKDOWN_LEGACY_ABI = [
    {
        inputs: [{ internalType: "address", name: "asset", type: "address" }],
        name: "getRiskBreakdown",
        outputs: [
            { internalType: "uint256", name: "compositeScore", type: "uint256" },
            { internalType: "uint256", name: "mcoScore", type: "uint256" },
            { internalType: "uint256", name: "tdrvScore", type: "uint256" },
            { internalType: "uint256", name: "cplcsScore", type: "uint256" },
            { internalType: "uint8", name: "tier", type: "uint8" },
            { internalType: "uint256", name: "recommendedLtvBps", type: "uint256" },
            { internalType: "uint256", name: "lastUpdated", type: "uint256" },
            { internalType: "uint256", name: "ewmaScore", type: "uint256" },
            { internalType: "uint8", name: "momentum", type: "uint8" },
        ],
        stateMutability: "view",
        type: "function",
    },
] as const;

/**
 * Minimal fallback ABI if both breakdown selectors fail.
 */
const URC_SCORE_ABI = [
    {
        inputs: [],
        name: "getRiskScore",
        outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
        stateMutability: "view",
        type: "function",
    },
] as const;

type Config = {
    evm: {
        chainSelectorName: string;
        urcAddress: string;
        wethAddress: string;
    };
    api: {
        priceUrl: string;
    };
};

/**
 * 1. Fetch On-chain Risk Score from UnifiedRiskCompositor
 */
const getOnChainRisk = (runtime: Runtime<Config>) => {
    const { chainSelectorName, urcAddress, wethAddress } = runtime.config.evm;
    const network = getNetwork({
        chainFamily: "evm",
        chainSelectorName,
        isTestnet: true,
    });
    if (!network) throw new Error(`Network ${chainSelectorName} not found`);

    const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector);

    const callView = (data: `0x${string}`) =>
        evmClient
            .callContract(runtime, {
                call: encodeCallMsg({
                    from: zeroAddress,
                    to: urcAddress as Address,
                    data,
                }),
                blockNumber: LATEST_BLOCK_NUMBER,
            })
            .result();

    // 1) Preferred selector: getRiskBreakdown()
    try {
        const callData = encodeFunctionData({
            abi: URC_BREAKDOWN_ABI,
            functionName: "getRiskBreakdown",
            args: [],
        });
        const callResult = callView(callData);
        const decoded = decodeFunctionResult({
            abi: URC_BREAKDOWN_ABI,
            functionName: "getRiskBreakdown",
            data: bytesToHex(callResult.data),
        });
        return Number(decoded[0]);
    } catch (e) {
        runtime.log(`Primary breakdown call failed, trying legacy ABI: ${String(e)}`);
    }

    // 2) Legacy selector: getRiskBreakdown(address)
    try {
        const callDataLegacy = encodeFunctionData({
            abi: URC_BREAKDOWN_LEGACY_ABI,
            functionName: "getRiskBreakdown",
            args: [wethAddress as Address],
        });
        const callResultLegacy = callView(callDataLegacy);
        const decodedLegacy = decodeFunctionResult({
            abi: URC_BREAKDOWN_LEGACY_ABI,
            functionName: "getRiskBreakdown",
            data: bytesToHex(callResultLegacy.data),
        });
        return Number(decodedLegacy[0]);
    } catch (e) {
        runtime.log(`Legacy breakdown call failed, falling back to getRiskScore(): ${String(e)}`);
    }

    // 3) Last-resort selector: getRiskScore()
    const callDataScore = encodeFunctionData({
        abi: URC_SCORE_ABI,
        functionName: "getRiskScore",
        args: [],
    });
    const callResultScore = callView(callDataScore);
    const decodedScore = decodeFunctionResult({
        abi: URC_SCORE_ABI,
        functionName: "getRiskScore",
        data: bytesToHex(callResultScore.data),
    });
    return Number(decodedScore);
};

/**
 * 2. Fetch Off-chain Market Data (CoinGecko 24h Volatility/Change)
 */
const getOffChainVolatility = (sendRequester: HTTPSendRequester, config: Config) => {
    const response = sendRequester
        .sendRequest({ url: config.api.priceUrl, method: "GET" })
        .result();

    if (!ok(response)) {
        throw new Error(`HTTP request failed: ${response.statusCode}`);
    }

    const data = json(response) as any;
    // Get absolute 24h percentage change as a proxy for volatility
    const change24h = Math.abs(data.ethereum.usd_24h_change || 0);
    return change24h;
};

/**
 * Main Workflow Handler
 */
const onTrigger = async (runtime: Runtime<Config>) => {
    runtime.log("--- Risk Orchestrator Workflow Starting ---");

    // Step 1: Read On-chain Risk
    const onChainScore = getOnChainRisk(runtime);
    runtime.log(`On-chain Composite Risk Score: ${onChainScore}`);

    // Step 2: Read Off-chain Market Sentiment (Volatility)
    const httpClient = new cre.capabilities.HTTPClient();
    const offChainVol = await httpClient
        .sendRequest(runtime, getOffChainVolatility, consensusMedianAggregation())(runtime.config)
        .result();

    runtime.log(`Off-chain 24h Price Volatility: ${offChainVol.toFixed(2)}%`);

    // Step 3: Combined Orchestration Logic
    if (onChainScore > 70 && offChainVol > 5) {
        runtime.log("⚠️ GLOBAL RISK ALERT: High on-chain risk detected during volatile market conditions!");
    } else if (onChainScore > 70) {
        runtime.log("ℹ️ Alert: On-chain risk is elevated, but market volatility is stable.");
    } else {
        runtime.log("✅ Risk levels are within nominal parameters.");
    }

    return { onChainScore, offChainVol };
};

// Define the Workflow
export async function main() {
    const cron = new cre.capabilities.CronCapability();
    const trigger = cron.trigger({ schedule: "0 */5 * * * *" }); // Every 5 minutes

    cre.handler(trigger, onTrigger);
}
