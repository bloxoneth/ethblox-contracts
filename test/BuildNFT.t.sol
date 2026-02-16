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
    uint8 private constant KIND_COLLECTOR = 2;
    uint256 private constant BLOX_PER_MASS = 1e18;
    bool private kindUnlockedForTests;

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

    function _unlockBuildKinds() internal {
        if (kindUnlockedForTests) return;
        uint256 genesisId = _mintBrickAs(alice, keccak256("unlock-genesis-1"), 1, 1, 1, 1);
        for (uint8 w = 1; w <= 10; w++) {
            for (uint8 d = w; d <= 10; d++) {
                if (w == 1 && d == 1) continue;
                uint256[] memory componentTokenIds = new uint256[](1);
                componentTokenIds[0] = genesisId;
                uint256[] memory componentCounts = new uint256[](1);
                componentCounts[0] = uint256(w) * uint256(d);
                _mintAs(
                    alice,
                    keccak256(abi.encodePacked("unlock", w, d)),
                    1,
                    componentTokenIds,
                    componentCounts,
                    KIND_BRICK,
                    w,
                    d,
                    1
                );
            }
        }
        assertTrue(buildNFT.isKindUnlocked());
        kindUnlockedForTests = true;
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
        if (kind > KIND_BRICK) {
            _unlockBuildKinds();
        }
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

    function _mintComposedBrickAs(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint8 width,
        uint8 depth,
        uint16 density
    ) internal returns (uint256 tokenId) {
        uint256 componentId = _mintBrickAs(minter, keccak256(abi.encodePacked(geo, "gen")), 1, 1, 1, density);
        uint256[] memory componentTokenIds = new uint256[](1);
        uint256[] memory componentCounts = new uint256[](1);
        componentTokenIds[0] = componentId;
        componentCounts[0] = uint256(width) * uint256(depth);
        tokenId = _mintAs(
            minter, geo, mass, componentTokenIds, componentCounts, KIND_BRICK, width, depth, density
        );
    }

    function _ones(uint256 n) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            arr[i] = 1;
        }
    }

    function _signReservation(uint256 authorPk, BuildNFT.MintReservation memory rsv)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = buildNFT.reservationDigest(rsv);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorPk, digest);
        sig = abi.encodePacked(r, s, v);
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

    function testMintWithReservationCreditsNonMintingDesigner() public {
        _unlockBuildKinds();

        uint256 authorPk = 0xBEEF11;
        address author = vm.addr(authorPk);
        bytes32 geo = keccak256("geo-reservation");
        uint256 mass = 12;
        string memory uri = "ipfs://reserved/1";
        uint256[] memory componentTokenIds = new uint256[](0);
        uint256[] memory componentCounts = new uint256[](0);
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;

        BuildNFT.MintReservation memory rsv = BuildNFT.MintReservation({
            author: author,
            reservedFor: address(0),
            geometryHash: geo,
            mass: mass,
            uriHash: keccak256(bytes(uri)),
            componentBuildIdsHash: keccak256(abi.encode(componentTokenIds)),
            componentCountsHash: keccak256(abi.encode(componentCounts)),
            kind: KIND_BUILD,
            width: 0,
            depth: 0,
            density: 1,
            nonce: nonce,
            expiry: expiry
        });
        bytes memory sig = _signReservation(authorPk, rsv);

        vm.startPrank(alice);
        blox.approve(address(buildNFT), mass * BLOX_PER_MASS);
        uint256 tokenId = buildNFT.mintWithReservation{value: buildNFT.FEE_PER_MINT()}(
            rsv,
            uri,
            componentTokenIds,
            componentCounts,
            sig
        );
        vm.stopPrank();

        assertEq(buildNFT.ownerOf(tokenId), alice);
        assertEq(buildNFT.creatorOf(tokenId), author);
    }

    function testMintWithReservationReplayReverts() public {
        _unlockBuildKinds();

        uint256 authorPk = 0xBEEF22;
        address author = vm.addr(authorPk);
        bytes32 geo = keccak256("geo-reservation-replay");
        uint256 mass = 7;
        string memory uri = "ipfs://reserved/2";
        uint256[] memory componentTokenIds = new uint256[](0);
        uint256[] memory componentCounts = new uint256[](0);
        uint256 nonce = 7;
        uint256 expiry = block.timestamp + 1 days;

        BuildNFT.MintReservation memory rsv = BuildNFT.MintReservation({
            author: author,
            reservedFor: alice,
            geometryHash: geo,
            mass: mass,
            uriHash: keccak256(bytes(uri)),
            componentBuildIdsHash: keccak256(abi.encode(componentTokenIds)),
            componentCountsHash: keccak256(abi.encode(componentCounts)),
            kind: KIND_BUILD,
            width: 0,
            depth: 0,
            density: 1,
            nonce: nonce,
            expiry: expiry
        });
        bytes memory sig = _signReservation(authorPk, rsv);

        vm.startPrank(alice);
        blox.approve(address(buildNFT), mass * BLOX_PER_MASS * 2);
        buildNFT.mintWithReservation{value: buildNFT.FEE_PER_MINT()}(
            rsv,
            uri,
            componentTokenIds,
            componentCounts,
            sig
        );

        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("reservation used"));
        buildNFT.mintWithReservation{value: fee}(
            rsv,
            uri,
            componentTokenIds,
            componentCounts,
            sig
        );
        vm.stopPrank();
    }

    function testMintWithReservationReservedBuyerEnforced() public {
        _unlockBuildKinds();

        uint256 authorPk = 0xBEEF33;
        address author = vm.addr(authorPk);
        bytes32 geo = keccak256("geo-reservation-target");
        uint256 mass = 5;
        string memory uri = "ipfs://reserved/3";
        uint256[] memory componentTokenIds = new uint256[](0);
        uint256[] memory componentCounts = new uint256[](0);
        uint256 nonce = 3;
        uint256 expiry = block.timestamp + 1 days;

        BuildNFT.MintReservation memory rsv = BuildNFT.MintReservation({
            author: author,
            reservedFor: bob,
            geometryHash: geo,
            mass: mass,
            uriHash: keccak256(bytes(uri)),
            componentBuildIdsHash: keccak256(abi.encode(componentTokenIds)),
            componentCountsHash: keccak256(abi.encode(componentCounts)),
            kind: KIND_BUILD,
            width: 0,
            depth: 0,
            density: 1,
            nonce: nonce,
            expiry: expiry
        });
        bytes memory sig = _signReservation(authorPk, rsv);

        vm.startPrank(alice);
        blox.approve(address(buildNFT), mass * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("wrong minter"));
        buildNFT.mintWithReservation{value: fee}(
            rsv,
            uri,
            componentTokenIds,
            componentCounts,
            sig
        );
        vm.stopPrank();
    }

    function testMintWithReservationExpiryBeyondSevenDaysReverts() public {
        _unlockBuildKinds();

        uint256 authorPk = 0xBEEF44;
        address author = vm.addr(authorPk);
        bytes32 geo = keccak256("geo-reservation-ttl");
        uint256 mass = 5;
        string memory uri = "ipfs://reserved/ttl";
        uint256[] memory componentTokenIds = new uint256[](0);
        uint256[] memory componentCounts = new uint256[](0);
        uint256 nonce = 9;
        uint256 expiry = block.timestamp + 8 days;

        BuildNFT.MintReservation memory rsv = BuildNFT.MintReservation({
            author: author,
            reservedFor: address(0),
            geometryHash: geo,
            mass: mass,
            uriHash: keccak256(bytes(uri)),
            componentBuildIdsHash: keccak256(abi.encode(componentTokenIds)),
            componentCountsHash: keccak256(abi.encode(componentCounts)),
            kind: KIND_BUILD,
            width: 0,
            depth: 0,
            density: 1,
            nonce: nonce,
            expiry: expiry
        });
        bytes memory sig = _signReservation(authorPk, rsv);

        vm.startPrank(alice);
        blox.approve(address(buildNFT), mass * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("reservation ttl"));
        buildNFT.mintWithReservation{value: fee}(
            rsv,
            uri,
            componentTokenIds,
            componentCounts,
            sig
        );
        vm.stopPrank();
    }

    function testFeeRouting_NoComponentsGoesToTreasury() public {
        bytes32 geo = keccak256("geo-fee-no-components");
        uint256 mass = 4;
        uint256 fee = buildNFT.FEE_PER_MINT();

        _unlockBuildKinds();
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
        uint256 bobDelta = distributor.ethOwed(bob) - bobAccruedBefore;
        uint256 aliceDelta = distributor.ethOwed(alice) - aliceAccruedBefore;

        assertEq(bobDelta + aliceDelta, ownersCut);
        assertTrue(bobDelta > 0);
        assertTrue(aliceDelta > 0);
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
        uint256 tokenId = _mintComposedBrickAs(alice, keccak256("geo-brick"), 1, 2, 4, 27);

        vm.prank(alice);
        vm.expectRevert(bytes("brick"));
        buildNFT.burn(tokenId);
    }

    function testBrickSpecStoredAndKey() public {
        bytes32 geo = keccak256("geo-brick-spec");
        uint256 tokenId = _mintComposedBrickAs(alice, geo, 1, 2, 4, 27);
        (uint8 width, uint8 depth, uint16 density) = buildNFT.brickSpecOf(tokenId);
        assertEq(width, 2);
        assertEq(depth, 4);
        assertEq(density, 27);
        assertEq(
            buildNFT.brickSpecKeyOf(tokenId),
            keccak256(abi.encodePacked(uint8(2), uint8(4), uint16(27)))
        );
    }

    function testBrickSpecUnique() public {
        bytes32 geo = keccak256("geo-brick-spec-1");
        uint256 componentId = _mintBrickAs(alice, keccak256("geo-brick-spec-1-gen"), 1, 1, 1, 27);
        uint256[] memory firstComponentIds = new uint256[](1);
        firstComponentIds[0] = componentId;
        uint256[] memory firstComponentCounts = new uint256[](1);
        firstComponentCounts[0] = 8;
        _mintAs(alice, geo, 1, firstComponentIds, firstComponentCounts, KIND_BRICK, 2, 4, 27);
        bytes32 specKey = keccak256(abi.encodePacked(uint8(2), uint8(4), uint16(27)));
        assertTrue(buildNFT.brickSpecConsumed(specKey));

        uint256 fee = buildNFT.FEE_PER_MINT();
        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;
        uint256[] memory componentCounts = new uint256[](1);
        componentCounts[0] = 8;

        vm.startPrank(bob);
        blox.approve(address(buildNFT), 1 * BLOX_PER_MASS);
        vm.expectRevert(bytes("brick spec used"));
        buildNFT.mint{value: fee}(
            geo,
            1,
            "ipfs://test",
            componentTokenIds,
            componentCounts,
            KIND_BRICK,
            2,
            4,
            27
        );
        vm.stopPrank();
    }

    function testBrickSpecDensityVariantsAllowed() public {
        bytes32 geo = keccak256("geo-brick-variants");
        _mintComposedBrickAs(alice, geo, 1, 2, 4, 1);
        _mintComposedBrickAs(bob, geo, 1, 2, 4, 8);

        bytes32 specKeyA = keccak256(abi.encodePacked(uint8(2), uint8(4), uint16(1)));
        bytes32 specKeyB = keccak256(abi.encodePacked(uint8(2), uint8(4), uint16(8)));
        assertTrue(buildNFT.brickSpecConsumed(specKeyA));
        assertTrue(buildNFT.brickSpecConsumed(specKeyB));
    }

    function testBrickSpecGlobalUniquenessByWidthDepthDensity() public {
        uint256 componentId = _mintBrickAs(alice, keccak256("geo-unique-a-gen"), 1, 1, 1, 27);
        uint256[] memory firstComponentTokenIds = new uint256[](1);
        firstComponentTokenIds[0] = componentId;
        uint256[] memory firstComponentCounts = new uint256[](1);
        firstComponentCounts[0] = 6;
        _mintAs(alice, keccak256("geo-unique-a"), 1, firstComponentTokenIds, firstComponentCounts, KIND_BRICK, 2, 3, 27);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;
        uint256[] memory componentCounts = new uint256[](1);
        componentCounts[0] = 6;
        uint256 fee = buildNFT.FEE_PER_MINT();

        vm.startPrank(bob);
        blox.approve(address(buildNFT), 1 * BLOX_PER_MASS);
        vm.expectRevert(bytes("brick spec used"));
        buildNFT.mint{value: fee}(
            keccak256("geo-unique-b"),
            1,
            "ipfs://test",
            componentTokenIds,
            componentCounts,
            KIND_BRICK,
            2,
            3,
            27
        );
        vm.stopPrank();
    }

    function testBrickSpecRotationEquivalentUniqueness() public {
        uint256 componentId = _mintBrickAs(alice, keccak256("geo-rot-a-gen"), 1, 1, 1, 27);
        uint256[] memory firstComponentTokenIds = new uint256[](1);
        firstComponentTokenIds[0] = componentId;
        uint256[] memory firstComponentCounts = new uint256[](1);
        firstComponentCounts[0] = 14;
        _mintAs(
            alice,
            keccak256("geo-rot-a"),
            1,
            firstComponentTokenIds,
            firstComponentCounts,
            KIND_BRICK,
            2,
            7,
            27
        );

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;
        uint256[] memory componentCounts = new uint256[](1);
        componentCounts[0] = 14;
        uint256 fee = buildNFT.FEE_PER_MINT();

        vm.startPrank(bob);
        blox.approve(address(buildNFT), 1 * BLOX_PER_MASS);
        vm.expectRevert(bytes("brick spec used"));
        buildNFT.mint{value: fee}(
            keccak256("geo-rot-b"),
            1,
            "ipfs://test",
            componentTokenIds,
            componentCounts,
            KIND_BRICK,
            7,
            2,
            27
        );
        vm.stopPrank();
    }

    function testOnlyGenesisOneByOneCanMintWithoutComponents() public {
        uint16[5] memory densities = [uint16(1), uint16(8), uint16(27), uint16(64), uint16(125)];
        for (uint256 i = 0; i < densities.length; i++) {
            _mintBrickAs(
                alice,
                keccak256(abi.encodePacked("geo-genesis", i)),
                1,
                1,
                1,
                densities[i]
            );
        }

        vm.startPrank(alice);
        blox.approve(address(buildNFT), 1 * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("components required"));
        buildNFT.mint{value: fee}(
            keccak256("geo-non-genesis-no-components"),
            1,
            "ipfs://test",
            new uint256[](0),
            new uint256[](0),
            KIND_BRICK,
            2,
            2,
            1
        );
        vm.stopPrank();
    }

    function testDensityMustMatchAcrossMintAndComponents() public {
        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 componentId = _mintBuildAs(bob, keccak256("geo-density-component"), 3, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(componentId, keccak256("geo-density-component"));
        uint256 licensePrice = licenseRegistry.quote(componentId, 1);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(componentId, 1);
        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = componentId;
        uint256[] memory componentCounts = new uint256[](1);
        componentCounts[0] = 1;

        vm.startPrank(alice);
        blox.approve(address(buildNFT), 10 * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("component density"));
        buildNFT.mint{value: fee}(
            keccak256("geo-density-mismatch"),
            4,
            "ipfs://test",
            componentTokenIds,
            componentCounts,
            KIND_BUILD,
            0,
            0,
            8
        );
        vm.stopPrank();
    }

    function testKindDisabledRevertsUntilEnabled() public {
        bytes32 geo = keccak256("geo-kind-disabled");
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyCounts = new uint256[](0);

        _unlockBuildKinds();
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
        uint256 masterId = _mintBuildAs(bob, geo, 1, emptyIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(masterId, geo);
        uint256 licensePrice = licenseRegistry.quote(masterId, 1);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(masterId, 1);
        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = masterId;
        uint256[] memory componentCounts = new uint256[](1);
        componentCounts[0] = 1;
        _mintAs(alice, geo, 1, componentTokenIds, componentCounts, 2, 0, 0, 1);
    }

    function testCollectorEditionRequiresExactMasterGeometryAndDensity() public {
        _unlockBuildKinds();
        buildNFT.setKindEnabled(uint16(KIND_COLLECTOR), true);

        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 masterId = _mintBuildAs(bob, keccak256("collector-master"), 5, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(masterId, keccak256("collector-master"));
        uint256 licensePrice = licenseRegistry.quote(masterId, 1);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(masterId, 1);
        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = masterId;
        uint256[] memory componentCounts = new uint256[](1);
        componentCounts[0] = 1;

        uint256 collectorId = _mintAs(
            alice,
            keccak256("collector-master"),
            7,
            componentTokenIds,
            componentCounts,
            KIND_COLLECTOR,
            0,
            0,
            1
        );
        assertEq(buildNFT.bwAnchorOf(collectorId), masterId);

        vm.startPrank(alice);
        blox.approve(address(buildNFT), 7 * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("collector geometry"));
        buildNFT.mint{value: fee}(
            keccak256("different-geometry"),
            7,
            "ipfs://test",
            componentTokenIds,
            componentCounts,
            KIND_COLLECTOR,
            0,
            0,
            1
        );
        vm.stopPrank();
    }

    function testCollectorEditionRequiresSingleComponentCountOne() public {
        _unlockBuildKinds();
        buildNFT.setKindEnabled(uint16(KIND_COLLECTOR), true);

        uint256[] memory emptyTokenIds = new uint256[](0);
        uint256 masterId = _mintBuildAs(bob, keccak256("collector-master-2"), 5, emptyTokenIds, _ones(0));

        vm.prank(bob);
        licenseRegistry.registerBuild(masterId, keccak256("collector-master-2"));
        uint256 licensePrice = licenseRegistry.quote(masterId, 2);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: licensePrice}(masterId, 2);
        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256[] memory componentTokenIds = new uint256[](1);
        componentTokenIds[0] = masterId;
        uint256[] memory badCounts = new uint256[](1);
        badCounts[0] = 2;

        vm.startPrank(alice);
        blox.approve(address(buildNFT), 7 * BLOX_PER_MASS);
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.expectRevert(bytes("collector count"));
        buildNFT.mint{value: fee}(
            keccak256("collector-master-2"),
            7,
            "ipfs://test",
            componentTokenIds,
            badCounts,
            KIND_COLLECTOR,
            0,
            0,
            1
        );
        vm.stopPrank();
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

        uint256 brickId =
            _mintComposedBrickAs(bob, keccak256("geo-density-brick"), mass, 2, 2, density);
        assertEq(buildNFT.lockedBloxOf(brickId), mass * BLOX_PER_MASS);
    }

    function testBaseTokenURIFormatting() public {
        buildNFT.setBaseTokenURI("ipfs://CID");

        uint256 tokenId = _mintBuildAsAlice(keccak256("geo-uri"), 1);
        assertEq(
            buildNFT.tokenURI(tokenId),
            string.concat("ipfs://CID/", vm.toString(tokenId), ".json")
        );

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
