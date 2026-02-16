// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LicenseRegistry} from "src/LicenseRegistry.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";

/// @dev Minimal BuildNFT stub for registry tests.
contract MockBuildNFT {
    mapping(uint256 => address) internal _ownerOf;
    mapping(uint256 => address) internal _creatorOf;
    mapping(uint256 => bytes32) internal _geometryOf;
    mapping(uint256 => uint256) internal _massOf;
    mapping(uint256 => uint16) internal _densityOf;
    mapping(uint256 => bool) internal _burned;

    function setOwner(uint256 tokenId, address owner) external {
        _ownerOf[tokenId] = owner;
    }

    function setCreator(uint256 tokenId, address creator) external {
        _creatorOf[tokenId] = creator;
    }

    function setGeometry(uint256 tokenId, bytes32 g) external {
        _geometryOf[tokenId] = g;
    }

    function setMass(uint256 tokenId, uint256 m) external {
        _massOf[tokenId] = m;
    }

    function setDensity(uint256 tokenId, uint16 d) external {
        _densityOf[tokenId] = d;
    }

    function setBurned(uint256 tokenId, bool v) external {
        _burned[tokenId] = v;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "NONEXISTENT");
        return o;
    }

    function geometryOf(uint256 tokenId) external view returns (bytes32) {
        // mirror your real BuildNFT pattern: geometryOf for non-existent tokens is fine
        // as long as ownerOf is the authoritative existence check.
        return _geometryOf[tokenId];
    }

    function creatorOf(uint256 tokenId) external view returns (address) {
        return _creatorOf[tokenId];
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return _ownerOf[tokenId] != address(0);
    }

    function massOf(uint256 tokenId) external view returns (uint256) {
        return _massOf[tokenId];
    }

    function densityOf(uint256 tokenId) external view returns (uint16) {
        return _densityOf[tokenId];
    }

    function isBurned(uint256 tokenId) external view returns (bool) {
        return _burned[tokenId];
    }
}

contract RebalanceRouterMock {
    bool public shouldFail;
    uint256 public callCount;
    uint256 public lastValue;

    function setShouldFail(bool v) external {
        shouldFail = v;
    }

    function execute() external payable {
        callCount += 1;
        lastValue = msg.value;
        require(!shouldFail, "router fail");
    }
}

contract LicenseRegistryTest is Test {
    MockBuildNFT private build;
    LicenseNFT private licenseNFT;
    LicenseRegistry private registry;
    RebalanceRouterMock private router;

    address private deployer = address(this);
    address private buildOwner = address(0xB0B);
    address private creator = address(0xC0FFEE);
    address private buyer = address(0xA11CE);

    address payable private treasury = payable(address(0xBEEF));
    address payable private newTreasury = payable(address(0xCAFE));

    uint256 private buildId = 1;
    bytes32 private geo = keccak256("geo-1");
    uint256 private mass = 100;

    function setUp() public {
        build = new MockBuildNFT();
        build.setOwner(buildId, buildOwner);
        build.setCreator(buildId, creator);
        build.setGeometry(buildId, geo);
        build.setMass(buildId, mass);
        build.setDensity(buildId, 1);

        licenseNFT = new LicenseNFT("ipfs://base/{id}.json");
        router = new RebalanceRouterMock();

        // Deploy registry with treasury
        registry = new LicenseRegistry(address(build), address(licenseNFT), treasury);

        // Wire permissions: only registry can mint + set max supply
        licenseNFT.setRegistry(address(registry));

        // Fund buyer with ETH
        vm.deal(buyer, 100 ether);
    }

    // ---------- constructor / admin ----------

    function testConstructorSetsState() public {
        assertEq(registry.buildNFT(), address(build));
        assertEq(registry.licenseNFT(), address(licenseNFT));
        assertEq(registry.treasury(), treasury);
        assertEq(registry.owner(), deployer);
    }

    function testSetTreasuryOnlyOwner() public {
        // Non-owner should revert (message depends on OZ version; keep generic)
        vm.prank(buyer);
        vm.expectRevert();
        registry.setTreasury(newTreasury);

        // Owner can set
        registry.setTreasury(newTreasury);
        assertEq(registry.treasury(), newTreasury);
    }

    // ---------- registerBuild ----------

    function testRegisterBuildHappyPath() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);

        uint256 licenseId = registry.licenseIdForBuild(buildId);
        assertEq(licenseId, 1);

        (uint256 startPrice, uint256 step, uint256 maxSupply, uint256 maxPrice) =
            registry.pricingForLicense(licenseId);
        assertEq(maxSupply, 10_000_000 / mass);
        assertTrue(startPrice > 0);
        assertTrue(maxPrice >= startPrice);

        // LicenseNFT maxSupply should be set
        assertEq(licenseNFT.maxSupply(licenseId), 10_000_000 / mass);
        assertEq(licenseNFT.balanceOf(creator, licenseId), 1);
    }

    function testRegisterBuildPermissionless() public {
        vm.prank(buyer);
        registry.registerBuild(buildId, geo);
        assertEq(registry.licenseIdForBuild(buildId), 1);
    }

    function testRegisterBuildRevertsOnGeometryMismatch() public {
        vm.prank(buildOwner);
        vm.expectRevert(bytes("geometry mismatch"));
        registry.registerBuild(buildId, keccak256("wrong"));
    }

    function testRegisterBuildRevertsIfAlreadyRegistered() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);

        vm.prank(buildOwner);
        vm.expectRevert(bytes("already registered"));
        registry.registerBuild(buildId, geo);
    }

    function testRegisterBuildRevertsIfBurned() public {
        build.setBurned(buildId, true);

        vm.prank(buildOwner);
        vm.expectRevert(bytes("build burned"));
        registry.registerBuild(buildId, geo);
    }

    function testRegisterBuildRevertsOnZeroMass() public {
        build.setMass(buildId, 0);
        vm.prank(buildOwner);
        vm.expectRevert(bytes("mass=0"));
        registry.registerBuild(buildId, geo);
    }

    // ---------- quote / mintLicenseForBuild ----------

    function testQuoteMatchesArithmeticSeries() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);

        uint256 licenseId = registry.licenseIdForBuild(buildId);
        (uint256 startPrice, uint256 step,,) = registry.pricingForLicense(licenseId);

        uint256 q = registry.quote(buildId, 3);
        uint256 start = startPrice + step; // creator receives first seeded license at registration
        uint256 expected = ((start * 2 + (2 * step)) * 3) / 2;
        assertEq(q, expected);
    }

    function testMintLicenseForBuildMintsAndSplitsETH() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);

        uint256 licenseId = registry.licenseIdForBuild(buildId);
        uint256 price = registry.quote(buildId, 2);

        uint256 treasuryBefore = treasury.balance;
        uint256 lpBefore = registry.lpBudgetBalance();

        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 2);

        // Buyer received ERC1155 licenses
        assertEq(licenseNFT.balanceOf(buyer, licenseId), 2);
        assertEq(licenseNFT.balanceOf(creator, licenseId), 1);

        uint256 expectedLp = price / 2;
        uint256 expectedTreasury = price - expectedLp;
        assertEq(treasury.balance, treasuryBefore + expectedTreasury);
        assertEq(registry.lpBudgetBalance(), lpBefore + expectedLp);
    }

    function testMintLicenseForBuildRevertsOnBadPrice() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);

        uint256 price = registry.quote(buildId, 2);

        vm.prank(buyer);
        vm.expectRevert(bytes("bad price"));
        registry.mintLicenseForBuild{value: price - 1}(buildId, 2);
    }

    function testMintLicenseForBuildAutoRegistersOnFirstAttempt() public {
        uint256 price = registry.quote(buildId, 1);
        assertEq(registry.licenseIdForBuild(buildId), 0);

        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 1);

        uint256 licenseId = registry.licenseIdForBuild(buildId);
        assertTrue(licenseId > 0);
        assertEq(licenseNFT.balanceOf(buyer, licenseId), 1);
        assertEq(licenseNFT.balanceOf(creator, licenseId), 1);
    }

    function testMintLicenseForBuildRevertsIfBurned() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);

        build.setBurned(buildId, true);

        uint256 price = registry.quote(buildId, 1);
        vm.prank(buyer);
        vm.expectRevert(bytes("build burned"));
        registry.mintLicenseForBuild{value: price}(buildId, 1);
    }

    function testQuoteWorksBeforeRegistration() public {
        uint256 q = registry.quote(buildId, 1);
        assertTrue(q > 0);
    }

    function testRegisterBuildDensityAwareSupply() public {
        build.setDensity(buildId, 8);
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);
        uint256 licenseId = registry.licenseIdForBuild(buildId);
        (, , uint256 maxSupply,) = registry.pricingForLicense(licenseId);
        assertEq(maxSupply, 10_000_000 / (mass * 8));
    }

    function testRebalanceGuards_Interval() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);
        uint256 price = registry.quote(buildId, 1);
        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 1);

        registry.setRouterWhitelist(address(router), true);
        registry.setRebalanceGuards(1 hours, 1, 100, 10 minutes);
        vm.warp(block.timestamp + 1 hours + 1);

        (bool ok,) = registry.executeRebalance(
            address(router), 1, 100, block.timestamp + 1 minutes, abi.encodeCall(router.execute, ())
        );
        assertTrue(ok);

        vm.expectRevert(bytes("interval"));
        registry.executeRebalance(
            address(router), 1, 100, block.timestamp + 1 minutes, abi.encodeCall(router.execute, ())
        );
    }

    function testRebalanceGuards_Threshold() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);
        uint256 price = registry.quote(buildId, 1);
        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 1);

        registry.setRouterWhitelist(address(router), true);
        registry.setRebalanceGuards(0, 1 ether, 100, 10 minutes);

        vm.expectRevert(bytes("threshold"));
        registry.executeRebalance(
            address(router), 1, 100, block.timestamp + 1 minutes, abi.encodeCall(router.execute, ())
        );
    }

    function testRebalanceGuards_Whitelist() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);
        uint256 price = registry.quote(buildId, 1);
        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 1);

        registry.setRebalanceGuards(0, 1, 100, 10 minutes);
        vm.expectRevert(bytes("router"));
        registry.executeRebalance(
            address(router), 1, 100, block.timestamp + 1 minutes, abi.encodeCall(router.execute, ())
        );
    }

    function testRebalanceGuards_SlippageAndDeadline() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);
        uint256 price = registry.quote(buildId, 1);
        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 1);

        registry.setRouterWhitelist(address(router), true);
        registry.setRebalanceGuards(0, 1, 100, 10 minutes);

        vm.expectRevert(bytes("slippage"));
        registry.executeRebalance(
            address(router), 1, 101, block.timestamp + 1 minutes, abi.encodeCall(router.execute, ())
        );

        vm.expectRevert(bytes("deadline"));
        registry.executeRebalance(
            address(router), 1, 100, block.timestamp + 11 minutes, abi.encodeCall(router.execute, ())
        );
    }

    function testRebalanceFailureKeepsLpBudget() public {
        vm.prank(buildOwner);
        registry.registerBuild(buildId, geo);
        uint256 price = registry.quote(buildId, 1);
        vm.prank(buyer);
        registry.mintLicenseForBuild{value: price}(buildId, 1);

        registry.setRouterWhitelist(address(router), true);
        registry.setRebalanceGuards(0, 1, 100, 10 minutes);
        router.setShouldFail(true);

        uint256 lpBefore = registry.lpBudgetBalance();
        (bool ok,) = registry.executeRebalance(
            address(router), 1, 100, block.timestamp + 1 minutes, abi.encodeCall(router.execute, ())
        );
        assertFalse(ok);
        assertEq(registry.lpBudgetBalance(), lpBefore);
    }
}
