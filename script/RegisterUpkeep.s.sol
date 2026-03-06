// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface LinkTokenInterface {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface AutomationRegistrar2_1 {
    struct RegistrationParams {
        string name;
        bytes encryptedEmail;
        address upkeepContract;
        uint32 gasLimit;
        address adminAddress;
        uint8 triggerType;
        bytes checkData;
        bytes triggerConfig;
        bytes offchainConfig;
        uint96 amount;
    }

    function registerUpkeep(RegistrationParams calldata requestParams) external returns (uint256);
}

contract RegisterUpkeep is Script {
    address constant LINK_TOKEN = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant REGISTRAR = 0xb0E49c5D0d05cbc241d68c05BC5BA1d1B7B72976;

    // The deployed AutomatedRiskUpdater (Sepolia deployment 2026-03-06)
    address constant ARU = 0x473779900D540F0098D4EDf40bD3b94a36f8731C;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Approve LINK
        uint96 fundAmount = 2 ether; // 2 LINK
        console2.log("Approving 2 LINK for Registrar...");
        LinkTokenInterface(LINK_TOKEN).approve(REGISTRAR, fundAmount);

        // 2. Register Upkeep
        console2.log("Registering AutomatedRiskUpdater upkeep...");
        AutomationRegistrar2_1.RegistrationParams memory params = AutomationRegistrar2_1.RegistrationParams({
            name: "DeFiStressOracle ARU",
            encryptedEmail: new bytes(0),
            upkeepContract: ARU,
            gasLimit: 3000000,
            adminAddress: deployer,
            triggerType: 0, // Condition-based (Custom Logic)
            checkData: new bytes(0), // No static checkData needed
            triggerConfig: new bytes(0), // No triggerConfig needed for condition based
            offchainConfig: new bytes(0),
            amount: fundAmount
        });

        uint256 upkeepId = AutomationRegistrar2_1(REGISTRAR).registerUpkeep(params);
        console2.log("Successfully registered!");
        console2.log("Upkeep ID:", upkeepId);

        vm.stopBroadcast();
    }
}
