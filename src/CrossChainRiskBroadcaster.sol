// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {CCIPReceiver}   from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import {Client}         from "@chainlink/contracts-ccip/libraries/Client.sol";

// ============================================================================
//  CrossChainRiskBroadcaster
//
//  Chainlink CCIP integration for RiskSync.
//
//  ── WHY CCIP? ───────────────────────────────────────────────────────────────
//
//  DeFi risk is cross-chain. A WETH price crash on Ethereum mainnet will
//  propagate to Aave on Base, GMX on Arbitrum, and Venus on BNB Chain within
//  minutes — but each chain's lending protocol has no awareness of what is
//  happening on other chains until liquidations begin.
//
//  CrossChainRiskBroadcaster solves this:
//    1. When composite risk score crosses WARNING (≥50) or EMERGENCY (≥80),
//       this contract sends a RiskPayload to all configured destination chains
//       via Chainlink CCIP.
//    2. A receiver on each destination chain receives the payload and can
//       trigger a local circuit breaker — in the SAME block the risk spikes.
//
//  ── ARCHITECTURE ────────────────────────────────────────────────────────────
//
//  Source chain (Ethereum):
//    AutomatedRiskUpdater → CrossChainRiskBroadcaster → CCIP Router
//                                                             ↓
//  Destination chain (Base / Arbitrum / BNB):          CCIP Receiver
//    CrossChainRiskBroadcaster._ccipReceive()
//         → emit CrossChainRiskReceived event
//         → (optional) trigger local circuit breaker
//
//  ── PAYLOAD ─────────────────────────────────────────────────────────────────
//
//  struct RiskPayload {
//    uint256 compositeScore;   // 0-100
//    uint8   alertLevel;       // 0=NOMINAL … 4=EMERGENCY
//    uint256 ltvBps;           // recommended LTV (5000-8000)
//    uint256 timestamp;        // source chain block.timestamp
//    address sourceContract;   // sender address for verification
//  }
//
// ============================================================================

interface IMultiAssetRouterForCCIP {
    function assetRiskState(address asset) external view returns (
        uint256 compositeScore,
        uint256 mcoInput,
        uint256 tdrvInput,
        uint256 cpInput,
        uint256 tcoInput,
        uint8 tier,
        uint256 recommendedLtvBps,
        uint256 realizedVolBps,
        uint256 manipulationCostUsd,
        uint256 ewmaScore,
        uint256 lastUpdatedAt
    );
}

interface ICircuitBreakerForCCIP {
    function currentLevel() external view returns (uint8);
}

/// @title CrossChainRiskBroadcaster
/// @notice Sends risk alerts cross-chain via Chainlink CCIP and receives them.
contract CrossChainRiskBroadcaster is CCIPReceiver {
    // =========================================================================
    // Types
    // =========================================================================

    struct RiskPayload {
        uint256 compositeScore;
        uint8   alertLevel;
        uint256 ltvBps;
        uint256 timestamp;
        address sourceContract;
    }

    struct Destination {
        uint64  chainSelector; // Chainlink CCIP chain selector
        address receiver;      // CrossChainRiskBroadcaster on destination chain
        bool    active;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event RiskAlertBroadcast(
        uint64  indexed destChainSelector,
        bytes32 indexed messageId,
        uint256 compositeScore,
        uint8   alertLevel,
        uint256 fee
    );

    event CrossChainRiskReceived(
        uint64  indexed sourceChainSelector,
        bytes32 indexed messageId,
        uint256 compositeScore,
        uint8   alertLevel,
        uint256 ltvBps,
        uint256 sourceTimestamp
    );

    event DestinationAdded(uint64 chainSelector, address receiver);
    event DestinationRemoved(uint64 chainSelector);

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidConfig();

    // =========================================================================
    // State
    // =========================================================================

    IMultiAssetRouterForCCIP public immutable router;

    /// @notice Address of the LendingProtocolCircuitBreaker to read alert level.
    ICircuitBreakerForCCIP public immutable circuitBreaker;

    /// @notice The asset being tracked for broadcast payload.
    address public immutable trackedAsset;
    address              public immutable owner;

    /// @notice Minimum alert level that triggers a cross-chain broadcast.
    /// Default: 2 (WARNING). Only broadcasts when risk is significant.
    uint8 public broadcastThreshold;

    /// @notice Configured destination chains.
    Destination[] public destinations;

    /// @notice Total CCIP messages sent.
    uint256 public broadcastCount;

    /// @notice Total CCIP messages received.
    uint256 public receiveCount;

    /// @notice Mapping of chain selector → index+1 in destinations array (0 = not found).
    mapping(uint64 => uint256) private _destIndex;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _ccipRouter      Chainlink CCIP Router on this chain
    /// @param _router     Address of the MultiAssetRiskRouter.
    /// @param _trackedAsset Address of the specific asset to broadcast.
    /// @param _breaker    Address of the local CircuitBreaker.
    constructor(
        address _ccipRouter,
        address _router,
        address _trackedAsset,
        address _breaker
    ) CCIPReceiver(_ccipRouter) {
        if (_router == address(0) || _trackedAsset == address(0) || _breaker == address(0)) revert InvalidConfig();
        router = IMultiAssetRouterForCCIP(_router);
        trackedAsset = _trackedAsset;
        circuitBreaker = ICircuitBreakerForCCIP(_breaker);
        owner             = msg.sender;
        broadcastThreshold = 2; // WARNING level
    }

    // =========================================================================
    // External: Send
    // =========================================================================

    /// @notice Broadcast current risk state to all configured destination chains.
    ///         Only broadcasts if alert level >= broadcastThreshold.
    ///         Caller must send enough ETH to cover CCIP fees.
    /// @return totalFee  Total ETH spent on CCIP fees across all destinations
    function broadcastToAll() external payable returns (uint256 totalFee) {
        uint8 alertLevel = circuitBreaker.currentLevel();
        require(alertLevel >= broadcastThreshold, "CCRB: below threshold");

        RiskPayload memory payload = _buildPayload();
        uint256 remaining = msg.value;

        for (uint256 i = 0; i < destinations.length; i++) {
            if (!destinations[i].active) continue;

            uint256 fee = _estimateFee(destinations[i].chainSelector, payload);
            require(remaining >= fee, "CCRB: insufficient ETH for fees");

            bytes32 msgId = _send(destinations[i].chainSelector, destinations[i].receiver, payload, fee);
            remaining -= fee;
            totalFee  += fee;

            emit RiskAlertBroadcast(
                destinations[i].chainSelector,
                msgId,
                payload.compositeScore,
                payload.alertLevel,
                fee
            );
        }

        // Refund unused ETH
        if (remaining > 0) {
            (bool ok,) = msg.sender.call{value: remaining}("");
            require(ok, "CCRB: refund failed");
        }
    }

    /// @notice Broadcast to a specific destination chain.
    function broadcastTo(uint64 destChainSelector) external payable returns (bytes32 messageId) {
        uint256 idx = _destIndex[destChainSelector];
        require(idx > 0, "CCRB: unknown destination");

        Destination memory dest = destinations[idx - 1];
        require(dest.active, "CCRB: destination inactive");

        RiskPayload memory payload = _buildPayload();
        uint256 fee = _estimateFee(destChainSelector, payload);
        require(msg.value >= fee, "CCRB: insufficient ETH");

        messageId = _send(destChainSelector, dest.receiver, payload, fee);
        broadcastCount++;

        emit RiskAlertBroadcast(destChainSelector, messageId, payload.compositeScore, payload.alertLevel, fee);

        // Refund excess
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "CCRB: refund failed");
        }
    }

    /// @notice Estimate the CCIP fee (in ETH) to broadcast to a destination.
    function estimateFee(uint64 destChainSelector) external view returns (uint256 fee) {
        RiskPayload memory payload = _buildPayload();
        return _estimateFee(destChainSelector, payload);
    }

    // =========================================================================
    // Internal: CCIP Receive
    // =========================================================================

    /// @inheritdoc CCIPReceiver
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        receiveCount++;

        RiskPayload memory payload = abi.decode(message.data, (RiskPayload));

        emit CrossChainRiskReceived(
            message.sourceChainSelector,
            message.messageId,
            payload.compositeScore,
            payload.alertLevel,
            payload.ltvBps,
            payload.timestamp
        );

        // Extension point: integrate with a local circuit breaker here
        // e.g.: localCircuitBreaker.receiveRemoteAlert(payload.alertLevel);
    }

    // =========================================================================
    // Owner: Destination Management
    // =========================================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "CCRB: not owner");
        _;
    }

    /// @notice Add a destination chain for cross-chain broadcasting.
    /// @param chainSelector  Chainlink CCIP chain selector (see chain.link/docs)
    /// @param receiver       CrossChainRiskBroadcaster address on destination chain
    function addDestination(uint64 chainSelector, address receiver) external onlyOwner {
        require(receiver != address(0), "CCRB: zero receiver");
        require(_destIndex[chainSelector] == 0, "CCRB: already exists");
        require(
            IRouterClient(i_ccipRouter).isChainSupported(chainSelector),
            "CCRB: chain not supported by CCIP"
        );

        destinations.push(Destination(chainSelector, receiver, true));
        _destIndex[chainSelector] = destinations.length;

        emit DestinationAdded(chainSelector, receiver);
    }

    /// @notice Disable a destination chain (soft delete).
    function removeDestination(uint64 chainSelector) external onlyOwner {
        uint256 idx = _destIndex[chainSelector];
        require(idx > 0, "CCRB: not found");
        destinations[idx - 1].active = false;
        emit DestinationRemoved(chainSelector);
    }

    /// @notice Update broadcast threshold (alert level that triggers sends).
    function setBroadcastThreshold(uint8 threshold) external onlyOwner {
        require(threshold <= 4, "CCRB: invalid threshold");
        broadcastThreshold = threshold;
    }

    function destinationCount() external view returns (uint256) {
        return destinations.length;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _buildPayload() internal view returns (RiskPayload memory) {
        (
            uint256 score,
            , // mcoInput
            , // tdrvInput
            , // cpInput
            , // tcoInput
            , // tier
            uint256 ltv,
            , // realizedVolBps
            , // manipulationCostUsd
            , // ewmaScore
              // lastUpdatedAt
        ) = router.assetRiskState(trackedAsset);

        return RiskPayload({
            compositeScore: score,
            alertLevel: circuitBreaker.currentLevel(),
            ltvBps: ltv,
            timestamp: block.timestamp,
            sourceContract: address(this)
        });
    }

    function _estimateFee(uint64 destChainSelector, RiskPayload memory payload) internal view returns (uint256) {
        Client.EVM2AnyMessage memory message = _buildMessage(address(0), payload);
        // Use a placeholder receiver for fee estimation
        message.receiver = abi.encode(address(this));
        return IRouterClient(i_ccipRouter).getFee(destChainSelector, message);
    }

    function _send(
        uint64 destChainSelector,
        address receiver,
        RiskPayload memory payload,
        uint256 fee
    ) internal returns (bytes32 messageId) {
        Client.EVM2AnyMessage memory message = _buildMessage(receiver, payload);
        return IRouterClient(i_ccipRouter).ccipSend{value: fee}(destChainSelector, message);
    }

    function _buildMessage(
        address receiver,
        RiskPayload memory payload
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage({
            receiver:     abi.encode(receiver),
            data:         abi.encode(payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken:     address(0), // pay in native ETH
            extraArgs:    Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200_000}))
        });
    }

    receive() external payable {}
}
