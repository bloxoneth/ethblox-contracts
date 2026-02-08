// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {Distributor} from "src/Distributor.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {LicenseRegistry} from "src/LicenseRegistry.sol";

/// @notice Base Sepolia deployment script (expects env PRIVATE_KEY).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address blox = vm.envOr("BLOX_ADDRESS", address(0x6578d53995FEB0e486135b893B8bC16AE1a5Ec52));
        address liquidityReceiver =
            vm.envOr("LIQUIDITY_RECEIVER", address(0x19E21180FEf7a99a43fd9a4Aa61A3D6316ab5eEE));
        address protocolTreasury =
            vm.envOr("PROTOCOL_TREASURY", address(0x87cC3F4d366a05fD2644c75334dbd1e811C2a54D));
        uint256 maxMass = vm.envOr("MAX_MASS", uint256(1_000_000));
        string memory licenseBaseURI =
            vm.envOr("LICENSE_BASE_URI", string("ipfs://PLACEHOLDER/{id}.json"));

        vm.startBroadcast(pk);

        uint256 nonce = vm.getNonce(deployer);
        address predictedBuildNFT = vm.computeCreateAddress(deployer, nonce + 3);

        Distributor distributor = new Distributor(blox, deployer);
        LicenseNFT licenseNFT = new LicenseNFT(licenseBaseURI);
        LicenseRegistry licenseRegistry =
            new LicenseRegistry(predictedBuildNFT, address(licenseNFT), protocolTreasury);
        BuildNFT buildNFT = new BuildNFT(
            blox,
            address(distributor),
            liquidityReceiver,
            protocolTreasury,
            address(licenseRegistry),
            address(licenseNFT),
            maxMass
        );

        licenseNFT.setRegistry(address(licenseRegistry));
        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);

        buildNFT.setKindEnabled(1, true);
        buildNFT.setKindEnabled(2, true);
        buildNFT.setKindEnabled(3, true);
        buildNFT.setKindEnabled(4, true);
        buildNFT.setKindEnabled(5, true);
        buildNFT.setKindEnabled(6, true);
        buildNFT.setKindEnabled(7, true);
        buildNFT.setKindEnabled(8, true);

        vm.stopBroadcast();
    }
}
