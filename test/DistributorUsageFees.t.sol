// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "src/Distributor.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockBuildNFT {
    mapping(uint256 => address) private owners;
    mapping(uint256 => uint256) private locked;
    Distributor private distributor;

    function setOwner(uint256 buildId, address owner, uint256 lockedBlox) external {
        owners[buildId] = owner;
        locked[buildId] = lockedBlox;
    }

    function ownerOf(uint256 buildId) external view returns (address) {
        address o = owners[buildId];
        require(o != address(0), "NONEXISTENT");
        return o;
    }

    function lockedBloxOf(uint256 buildId) external view returns (uint256) {
        require(owners[buildId] != address(0), "NONEXISTENT");
        return locked[buildId];
    }

    function isActive(uint256 buildId) external view returns (bool) {
        return owners[buildId] != address(0);
    }

    function setDistributor(address payable distributor_) external {
        distributor = Distributor(distributor_);
    }

    function accrue(uint256[] calldata buildIds, uint256[] calldata counts, address payer)
        external
        payable
    {
        distributor.accrueFromComposition{value: msg.value}(buildIds, counts, payer);
    }
}

contract DistributorUsageFeesTest is Test {
    Distributor private distributor;
    MockBuildNFT private buildNFT;
    ERC20Mock private blox;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA11);
    address private protocolTreasury = address(0xBEEF);

    function setUp() public {
        blox = new ERC20Mock();
        distributor = new Distributor(address(blox), address(this));
        buildNFT = new MockBuildNFT();

        buildNFT.setOwner(1, alice, 2 ether);
        buildNFT.setOwner(2, bob, 1 ether);
        buildNFT.setOwner(3, carol, 3 ether);

        buildNFT.setDistributor(payable(address(distributor)));
        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function testAccrueSplitsByCountsAndTracksUniqueUsers() public {
        uint256[] memory ids = new uint256[](3);
        uint256[] memory counts = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        counts[0] = 32;
        counts[1] = 10;
        counts[2] = 8;

        uint256 value = 0.005 ether;
        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        buildNFT.accrue{value: value}(ids, counts, payer);

        uint256 weight1 = ((2 ether) / 1e12) * 2;
        uint256 weight2 = ((1 ether) / 1e12) * 2;
        uint256 weight3 = ((3 ether) / 1e12) * 2;
        uint256 totalWeight = weight1 + weight2 + weight3;

        uint256 share1 = (value * weight1) / totalWeight;
        uint256 share2 = (value * weight2) / totalWeight;
        uint256 share3 = value - share1 - share2;

        assertEq(distributor.ethOwed(alice), share1);
        assertEq(distributor.ethOwed(bob), share2);
        assertEq(distributor.ethOwed(carol), share3);

        assertEq(distributor.uniqueUsers(1), 1);
        assertEq(distributor.uniqueUsers(2), 1);
        assertEq(distributor.uniqueUsers(3), 1);

        vm.prank(payer);
        buildNFT.accrue{value: value}(ids, counts, payer);

        assertEq(distributor.uniqueUsers(1), 1);
        assertEq(distributor.uniqueUsers(2), 1);
        assertEq(distributor.uniqueUsers(3), 1);
    }

    function testSelfPayAllowedAccruesToOwner() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory counts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        counts[0] = 3;
        counts[1] = 1;

        uint256 value = 0.004 ether;

        vm.prank(alice);
        buildNFT.accrue{value: value}(ids, counts, alice);

        uint256 weight1 = ((2 ether) / 1e12) * 2;
        uint256 weight2 = ((1 ether) / 1e12) * 2;
        uint256 totalWeight = weight1 + weight2;
        uint256 share1 = (value * weight1) / totalWeight;
        uint256 share2 = value - share1;

        assertEq(distributor.ethOwed(alice), share1);
        assertEq(distributor.ethOwed(protocolTreasury), 0);
        assertEq(distributor.ethOwed(bob), share2);
        assertEq(distributor.uniqueUsers(1), 1);
    }

    function testClaimResetsAndTransfers() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = 2;
        counts[0] = 1;

        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        buildNFT.accrue{value: 0.001 ether}(ids, counts, payer);

        uint256 owed = distributor.ethOwed(bob);
        uint256 before = bob.balance;

        vm.prank(bob);
        distributor.claim();

        assertEq(distributor.ethOwed(bob), 0);
        assertEq(bob.balance, before + owed);
    }

    function testOnlyBuildNFTCanAccrue() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = 1;
        counts[0] = 1;

        vm.expectRevert(bytes("only buildNFT"));
        distributor.accrueFromComposition{value: 1}(ids, counts, alice);
    }

    function testBurnedComponentRoutesToTreasury() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory counts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 999;
        counts[0] = 1;
        counts[1] = 1;

        uint256 value = 0.006 ether;
        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);

        uint256 treasuryBefore = distributor.ethOwed(protocolTreasury);
        uint256 aliceBefore = distributor.ethOwed(alice);

        vm.prank(payer);
        buildNFT.accrue{value: value}(ids, counts, payer);

        uint256 weightLive = ((2 ether) / 1e12) * 2;
        uint256 totalWeight = weightLive + 1;
        uint256 expectedLive = (value * weightLive) / totalWeight;
        uint256 expectedBurned = value - expectedLive;

        assertEq(distributor.ethOwed(alice), aliceBefore + expectedLive);
        assertEq(distributor.ethOwed(protocolTreasury), treasuryBefore + expectedBurned);
    }
}
