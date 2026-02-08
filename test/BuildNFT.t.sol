// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {Distributor} from "src/Distributor.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {LicenseRegistry} from "src/LicenseRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract BuildNFTTest is Test {
    BuildNFT private buildNFT;
    LicenseNFT private licenseNFT;
    LicenseRegistry private licenseRegistry;
    ERC20Mock private blox;
    Distributor private distributor;

    address private liquidityReceiver = address(0x200);
    address private protocolTreasury = address(0x300);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA11);
    uint8 private constant KIND_BRICK = 0;
    uint8 private constant KIND_BUILD = 1;
    uint256 private constant BLOX_PER_MASS = 1e18;

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedBuild = vm.computeCreateAddress(address(this), nonce + 4);

        blox = new ERC20Mock();
        distributor = new Distributor(address(blox), address(this));
        licenseNFT = new LicenseNFT("ipfs://licenses");
        licenseRegistry = new LicenseRegistry(predictedBuild, address(licenseNFT), protocolTreasury);
        buildNFT = new BuildNFT(
            address(blox),
            address(distributor),
            liquidityReceiver,
            protocolTreasury,
            address(licenseRegistry),
            address(licenseNFT),
            1_000
        );
        licenseNFT.setRegistry(address(licenseRegistry));
        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);
        buildNFT.setKindEnabled(uint16(KIND_BUILD), true);

        blox.mint(address(this), 3_000 ether);
        blox.transfer(alice, 1_000 ether);
        blox.transfer(bob, 1_000 ether);
        blox.transfer(carol, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function _mintAs(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint256[] memory componentTokenIds,
        uint256[] memory componentCounts,
        uint8 kind,
        uint8 width,
        uint8 depth,
        uint16 density
    ) internal returns (uint256 tokenId) {
        uint256 lockAmount = mass * BLOX_PER_MASS;

        vm.startPrank(minter);
        blox.approve(address(buildNFT), lockAmount);
        tokenId = buildNFT.mint{value: buildNFT.FEE_PER_MINT()}(
            geo, mass, "ipfs://test", componentTokenIds, componentCounts, kind, width, depth, density
        );
        vm.stopPrank();
    }

    function _mintBuildAsAlice(bytes32 geo, uint256 mass) internal returns (uint256 tokenId) {
        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256[] memory emptyCounts = new uint256[](0);

        tokenId = _mintAs(alice, geo, mass, emptyTokenIds, emptyCounts, KIND_BUILD, 0, 0, 1);
    }

    function _mintBuildAs(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint256[] memory componentTokenIds,
        uint256[] memory componentCounts
    ) internal returns (uint256 tokenId) {
        tokenId = _mintAs(minter, geo, mass, componentTokenIds, componentCounts, KIND_BUILD, 0, 0, 1);
    }

    function _mintBrickAs(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint8 width,
        uint8 depth,
        uint16 density
    )
        internal
        returns (uint256 tokenId)
    {
        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256[] memory emptyCounts = new uint256[](0);

        tokenId = _mintAs(
            minter, geo, mass, emptyTokenIds, emptyCounts, KIND_BRICK, width, depth, density
        );
    }

    function _ones(uint256 n) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            arr[i] = 1;
        }
    }

    function testGeometryReusableAfterBurn() public {
        bytes32 geo = keccak256("geo-reuse");
        uint256 mass = 5;

        uint256 tokenId = _mintBuildAsAlice(geo, mass);
        assertTrue(buildNFT.geometryConsumed(geo));

        vm.prank(alice);
        buildNFT.burn(tokenId);

        uint256 fee = buildNFT.FEE_PER_MINT();

        vm.startPrank(alice);
        blox.approve(address(buildNFT), mass * BLOX_PER_MASS);
        vm.expectRevert(bytes("geometry consumed"));
        buildNFT.mint{value: fee}(
            geo, mass, "ipfs://test", new uint256[](0), new uint256[](0), KIND_BUILD, 0, 0, 1
        );
        vm.stopPrank();
    }

    function testFeeRouting_NoComponentsGoesToTreasury() public {
        bytes32 geo = keccak256("geo-fee-no-components");
        uint256 mass = 4;
        uint256 fee = buildNFT.FEE_PER_MINT();

        uint256 liquidityBefore = liquidityReceiver.balance;
        uint256 treasuryBefore = protocolTreasury.balance;

        _mintBuildAsAlice(geo, mass);

        uint256 liquidityCut = (fee * 30) / 100;
        uint256 treasuryCut = (fee * 20) / 100;
        uint256 ownersCut = fee - liquidityCut - treasuryCut;

        assertEq(liquidityReceiver.balance, liquidityBefore + liquidityCut);
        assertEq(protocolTreasury.balance, treasuryBefore + treasuryCut + ownersCut);
    }

    function testFeeRouting_WithComponentsAccruesToComponentOwner() public {
        bytes32 bobGeo = keccak256("geo-component");
        uint256 mass = 3;
        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 componentId = _mintBuildAs(bob, bobGeo, mass, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(componentId, bobGeo);

        uint256 licensePrice = licenseRegistry.quote(componentId, 1);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(componentId, 1);
        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;

        uint256 fee = buildNFT.FEE_PER_MINT();
        uint256 liquidityBefore = liquidityReceiver.balance;
        uint256 treasuryBefore = protocolTreasury.balance;
        uint256 bobAccruedBefore = distributor.ethOwed(bob);
        uint256 treasuryAccruedBefore = distributor.ethOwed(protocolTreasury);

        _mintBuildAs(alice, keccak256("geo-fee-components"), 5, componentTokenIds, _ones(1));

        uint256 liquidityCut = (fee * 30) / 100;
        uint256 treasuryCut = (fee * 20) / 100;
        uint256 ownersCut = fee - liquidityCut - treasuryCut;

        assertEq(liquidityReceiver.balance, liquidityBefore + liquidityCut);
        assertEq(protocolTreasury.balance, treasuryBefore + treasuryCut);
        assertEq(distributor.ethOwed(bob), bobAccruedBefore + ownersCut);
        assertEq(distributor.ethOwed(protocolTreasury), treasuryAccruedBefore);
    }

    function testFeeRouting_WeightsByLockedBlox() public {
        bytes32 bobGeo = keccak256("geo-weight-a");
        bytes32 aliceGeo = keccak256("geo-weight-b");

        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 buildA = _mintBuildAs(bob, bobGeo, 2, emptyTokenIds, _ones(0));
        uint256 buildB = _mintBuildAs(alice, aliceGeo, 5, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(buildA, bobGeo);
        vm.prank(alice);
        licenseRegistry.registerBuild(buildB, aliceGeo);

        uint256 priceA = licenseRegistry.quote(buildA, 1);
        uint256 priceB = licenseRegistry.quote(buildB, 1);
        vm.prank(carol);
        licenseRegistry.mintLicenseForBuild{value: priceA}(buildA, 1);
        vm.prank(carol);
        licenseRegistry.mintLicenseForBuild{value: priceB}(buildB, 1);
        vm.prank(carol);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](2);
        componentTokenIds[0] = buildA;
        componentTokenIds[1] = buildB;

        uint256 bobAccruedBefore = distributor.ethOwed(bob);
        uint256 aliceAccruedBefore = distributor.ethOwed(alice);

        _mintBuildAs(carol, keccak256("geo-weight-mix"), 4, componentTokenIds, _ones(2));

        uint256 ownersCut = buildNFT.FEE_PER_MINT() - (buildNFT.FEE_PER_MINT() * 30) / 100
            - (buildNFT.FEE_PER_MINT() * 20) / 100;
        uint256 weightA = ((2 * buildNFT.BLOX_PER_MASS()) / 1e12) * 2;
        uint256 weightB = ((5 * buildNFT.BLOX_PER_MASS()) / 1e12) * 2;
        uint256 expectedA = (ownersCut * weightA) / (weightA + weightB);
        uint256 expectedB = ownersCut - expectedA;

        assertEq(distributor.ethOwed(bob), bobAccruedBefore + expectedA);
        assertEq(distributor.ethOwed(alice), aliceAccruedBefore + expectedB);
    }

    function testFeeRouting_SelfPayAllowedAccruesToOwner() public {
        bytes32 bobGeo = keccak256("geo-self-pay");
        uint256 mass = 3;
        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 componentId = _mintBuildAs(bob, bobGeo, mass, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(componentId, bobGeo);

        uint256 licensePrice = licenseRegistry.quote(componentId, 1);
        vm.prank(bob);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(componentId, 1);
        vm.prank(bob);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;

        uint256 fee = buildNFT.FEE_PER_MINT();
        uint256 liquidityCut = (fee * 30) / 100;
        uint256 treasuryCut = (fee * 20) / 100;
        uint256 ownersCut = fee - liquidityCut - treasuryCut;

        uint256 bobAccruedBefore = distributor.ethOwed(bob);
        uint256 treasuryAccruedBefore = distributor.ethOwed(protocolTreasury);

        _mintBuildAs(bob, keccak256("geo-self-pay-mint"), 5, componentTokenIds, _ones(1));

        assertEq(distributor.ethOwed(bob), bobAccruedBefore + ownersCut);
        assertEq(distributor.ethOwed(protocolTreasury), treasuryAccruedBefore);
    }

    function testBrickNotBurnable() public {
        uint256 tokenId = _mintBrickAs(alice, keccak256("geo-brick"), 1, 2, 4, 27);

        vm.prank(alice);
        vm.expectRevert(bytes("brick"));
        buildNFT.burn(tokenId);
    }

    function testBrickSpecStoredAndKey() public {
        bytes32 geo = keccak256("geo-brick-spec");
        uint256 tokenId = _mintBrickAs(alice, geo, 1, 2, 4, 27);
        (uint8 width, uint8 depth, uint16 density) = buildNFT.brickSpecOf(tokenId);
        assertEq(width, 2);
        assertEq(depth, 4);
        assertEq(density, 27);
        assertEq(buildNFT.brickSpecKeyOf(tokenId), keccak256(abi.encodePacked(geo, uint8(2), uint8(4))));
    }

    function testBrickSpecUnique() public {
        bytes32 geo = keccak256("geo-brick-spec-1");
        _mintBrickAs(alice, geo, 1, 2, 4, 27);
        bytes32 specKey = keccak256(abi.encodePacked(geo, uint8(2), uint8(4)));
        assertTrue(buildNFT.brickSpecConsumed(specKey, 27));

        uint256 fee = buildNFT.FEE_PER_MINT();

        vm.startPrank(bob);
        blox.approve(address(buildNFT), 1 * BLOX_PER_MASS);
        vm.expectRevert(bytes("brick spec used"));
        buildNFT.mint{value: fee}(
            geo,
            1,
            "ipfs://test",
            new uint256[](0),
            new uint256[](0),
            KIND_BRICK,
            2,
            4,
            27
        );
        vm.stopPrank();
    }

    function testBrickSpecDensityVariantsAllowed() public {
        bytes32 geo = keccak256("geo-brick-variants");
        _mintBrickAs(alice, geo, 1, 2, 4, 1);
        _mintBrickAs(bob, geo, 1, 2, 4, 8);

        bytes32 specKey = keccak256(abi.encodePacked(geo, uint8(2), uint8(4)));
        assertTrue(buildNFT.brickSpecConsumed(specKey, 1));
        assertTrue(buildNFT.brickSpecConsumed(specKey, 8));
    }

    function testKindDisabledRevertsUntilEnabled() public {
        bytes32 geo = keccak256("geo-kind-disabled");
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyCounts = new uint256[](0);

        assertFalse(buildNFT.kindEnabled(2));

        vm.startPrank(alice);
        blox.approve(address(buildNFT), 1 * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("kind disabled"));
        buildNFT.mint{value: fee}(
            geo,
            1,
            "ipfs://test",
            emptyIds,
            emptyCounts,
            2,
            0,
            0,
            1
        );
        vm.stopPrank();

        buildNFT.setKindEnabled(2, true);
        _mintAs(alice, geo, 1, emptyIds, emptyCounts, 2, 0, 0, 1);
    }

    function testSetKindEnabledReservedReverts() public {
        vm.expectRevert(bytes("reserved"));
        buildNFT.setKindEnabled(0, true);
    }

    function testDensityAffectsLockedBlox() public {
        bytes32 geo = keccak256("geo-density-lock");
        uint256 mass = 3;
        uint16 density = 27;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyCounts = new uint256[](0);
        uint256 tokenId = _mintAs(alice, geo, mass, emptyIds, emptyCounts, KIND_BUILD, 0, 0, density);
        assertEq(buildNFT.lockedBloxOf(tokenId), mass * BLOX_PER_MASS);

        uint256 brickId = _mintBrickAs(bob, keccak256("geo-density-brick"), mass, 2, 2, density);
        assertEq(buildNFT.lockedBloxOf(brickId), mass * BLOX_PER_MASS);
    }

    function testBaseTokenURIFormatting() public {
        buildNFT.setBaseTokenURI("ipfs://CID");

        uint256 tokenId = _mintBuildAsAlice(keccak256("geo-uri"), 1);
        assertEq(buildNFT.tokenURI(tokenId), "ipfs://CID/1.json");

        vm.expectRevert(bytes("ERC721: invalid token ID"));
        buildNFT.tokenURI(9999);
    }

    function testBuildGeometryConsumedAfterBurn() public {
        bytes32 geo = keccak256("geo-build-consume");
        uint256 mass = 2;

        uint256 tokenId = _mintBuildAs(alice, geo, mass, new uint256[](0), new uint256[](0));
        vm.prank(alice);
        buildNFT.burn(tokenId);

        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.startPrank(alice);
        blox.approve(address(buildNFT), mass * BLOX_PER_MASS);
        vm.expectRevert(bytes("geometry consumed"));
        buildNFT.mint{value: fee}(
            geo,
            mass,
            "ipfs://test",
            new uint256[](0),
            new uint256[](0),
            KIND_BUILD,
            0,
            0,
            1
        );
        vm.stopPrank();
    }

    function testBurnedComponentRoutesToTreasury() public {
        bytes32 bobGeo = keccak256("geo-burned-component");
        uint256 mass = 3;
        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 componentId = _mintBuildAs(bob, bobGeo, mass, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(componentId, bobGeo);

        uint256 licensePrice = licenseRegistry.quote(componentId, 1);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(componentId, 1);
        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        vm.prank(bob);
        buildNFT.burn(componentId);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;

        uint256 treasuryAccruedBefore = distributor.ethOwed(protocolTreasury);
        _mintBuildAs(alice, keccak256("geo-uses-burned"), 5, componentTokenIds, _ones(1));

        uint256 ownersCut = buildNFT.FEE_PER_MINT() - (buildNFT.FEE_PER_MINT() * 30) / 100
            - (buildNFT.FEE_PER_MINT() * 20) / 100;
        assertEq(distributor.ethOwed(protocolTreasury), treasuryAccruedBefore + ownersCut);
    }
}
