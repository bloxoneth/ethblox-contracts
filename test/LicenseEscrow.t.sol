// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {LicenseRegistry} from "src/LicenseRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract FeeRegistryMock {
    function accrueFromComposition(
        uint256[] calldata,
        uint256[] calldata
    ) external payable {}
}

contract LicenseEscrowTest is Test {
    BuildNFT private buildNFT;
    LicenseNFT private licenseNFT;
    LicenseRegistry private licenseRegistry;
    ERC20Mock private blox;
    FeeRegistryMock private feeRegistry;

    address private rewardsPool = address(0x100);
    address private liquidityReceiver = address(0x200);
    address private protocolTreasury = address(0x300);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedBuild = vm.computeCreateAddress(address(this), nonce + 4);

        blox = new ERC20Mock();
        feeRegistry = new FeeRegistryMock();
        licenseNFT = new LicenseNFT("ipfs://licenses");
        licenseRegistry = new LicenseRegistry(predictedBuild, address(licenseNFT));
        buildNFT = new BuildNFT(
            address(blox),
            rewardsPool,
            address(feeRegistry),
            liquidityReceiver,
            protocolTreasury,
            address(licenseRegistry),
            address(licenseNFT),
            1_000
        );
        licenseNFT.setRegistry(address(licenseRegistry));

        blox.mint(alice, 1_000 ether);
        blox.mint(bob, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _mintBuild(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint256[] memory componentBuildIds,
        uint256[] memory componentCounts
    ) internal returns (uint256 tokenId) {
        uint256 lockAmount = mass * buildNFT.BLOX_PER_MASS();
        vm.startPrank(minter);
        blox.approve(address(buildNFT), lockAmount);
        tokenId = buildNFT.mint{value: buildNFT.FEE_PER_MINT()}(
            geo,
            mass,
            "ipfs://build",
            componentBuildIds,
            componentCounts
        );
        vm.stopPrank();
    }

    function _emptyComponents()
        internal
        pure
        returns (uint256[] memory ids, uint256[] memory counts)
    {
        ids = new uint256[](0);
        counts = new uint256[](0);
    }

    function testRegisterMintAndComposeEscrowsOnePerType() public {
        bytes32 geoA = keccak256("geo-A");
        bytes32 geoB = keccak256("geo-B");
        (uint256[] memory emptyIds, uint256[] memory emptyCounts) = _emptyComponents();

        uint256 buildA = _mintBuild(alice, geoA, 5, emptyIds, emptyCounts);
        uint256 buildB = _mintBuild(alice, geoB, 6, emptyIds, emptyCounts);

        vm.startPrank(alice);
        licenseRegistry.registerBuild(buildA, geoA, 10, 0.05 ether, 0.01 ether);
        licenseRegistry.registerBuild(buildB, geoB, 10, 0.05 ether, 0.01 ether);
        vm.stopPrank();

        uint256 licenseIdA = licenseRegistry.licenseIdForBuild(buildA);
        uint256 licenseIdB = licenseRegistry.licenseIdForBuild(buildB);

        uint256 priceA = licenseRegistry.quote(buildA, 1);
        uint256 priceB = licenseRegistry.quote(buildB, 1);

        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: priceA}(buildA, 1);
        vm.prank(alice);
        licenseRegistry.mintLicenseForBuild{value: priceB}(buildB, 1);

        vm.prank(alice);
        licenseNFT.setApprovalForAll(address(buildNFT), true);

        uint256 aliceBeforeA = licenseNFT.balanceOf(alice, licenseIdA);
        uint256 aliceBeforeB = licenseNFT.balanceOf(alice, licenseIdB);

        uint256[] memory componentBuildIds = new uint256[](2);
        uint256[] memory componentCounts = new uint256[](2);
        componentBuildIds[0] = buildA;
        componentBuildIds[1] = buildB;
        componentCounts[0] = 1;
        componentCounts[1] = 1;

        uint256 composedId = _mintBuild(
            alice,
            keccak256("geo-composed"),
            7,
            componentBuildIds,
            componentCounts
        );

        assertEq(licenseNFT.balanceOf(alice, licenseIdA), aliceBeforeA - 1);
        assertEq(licenseNFT.balanceOf(alice, licenseIdB), aliceBeforeB - 1);
        assertEq(licenseNFT.balanceOf(address(buildNFT), licenseIdA), 1);
        assertEq(licenseNFT.balanceOf(address(buildNFT), licenseIdB), 1);

        vm.prank(alice);
        buildNFT.burn(composedId);

        assertEq(licenseNFT.balanceOf(alice, licenseIdA), aliceBeforeA);
        assertEq(licenseNFT.balanceOf(alice, licenseIdB), aliceBeforeB);
        assertEq(licenseNFT.balanceOf(address(buildNFT), licenseIdA), 0);
        assertEq(licenseNFT.balanceOf(address(buildNFT), licenseIdB), 0);
    }

    function testRevertIfLicenseMissing() public {
        bytes32 geoA = keccak256("geo-missing");
        (uint256[] memory emptyIds, uint256[] memory emptyCounts) = _emptyComponents();

        uint256 buildA = _mintBuild(alice, geoA, 5, emptyIds, emptyCounts);

        vm.prank(alice);
        licenseRegistry.registerBuild(buildA, geoA, 10, 0.05 ether, 0.01 ether);

        uint256[] memory componentBuildIds = new uint256[](1);
        uint256[] memory componentCounts = new uint256[](1);
        componentBuildIds[0] = buildA;
        componentCounts[0] = 1;

        uint256 lockAmount = 7 * buildNFT.BLOX_PER_MASS();
        uint256 fee = buildNFT.FEE_PER_MINT();
        vm.startPrank(bob);
        blox.approve(address(buildNFT), lockAmount);
        licenseNFT.setApprovalForAll(address(buildNFT), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector,
                bob,
                0,
                1,
                1
            )
        );
        buildNFT.mint{value: fee}(
            keccak256("geo-compose-missing"),
            7,
            "ipfs://build",
            componentBuildIds,
            componentCounts
        );
        vm.stopPrank();
    }

    function testRevertIfRegisterGeometryMismatch() public {
        bytes32 geoA = keccak256("geo-mismatch");
        (uint256[] memory emptyIds, uint256[] memory emptyCounts) = _emptyComponents();

        uint256 buildA = _mintBuild(alice, geoA, 5, emptyIds, emptyCounts);

        vm.prank(alice);
        vm.expectRevert(bytes("geometry mismatch"));
        licenseRegistry.registerBuild(buildA, keccak256("wrong-geo"), 10, 0.05 ether, 0.01 ether);
    }
}
