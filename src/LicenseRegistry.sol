// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface IBuildNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function geometryOf(uint256 tokenId) external view returns (bytes32);
    function isActive(uint256 tokenId) external view returns (bool);
    function massOf(uint256 tokenId) external view returns (uint256);
}

interface ILicenseNFT {
    function setMaxSupply(uint256 id, uint256 max) external;
    function mint(address to, uint256 id, uint256 qty) external;

    // NEW (read-only)
    function totalSupply(uint256 id) external view returns (uint256);
    function maxSupply(uint256 id) external view returns (uint256);
}

contract LicenseRegistry is Ownable {
    struct Pricing {
        uint256 startPrice;
        uint256 step;
        uint256 maxSupply;
        uint256 maxPrice;
    }

    address public buildNFT;
    address public licenseNFT;

    // NEW: where license ETH goes
    address public treasury;

    uint256 public nextLicenseId = 1;

    mapping(uint256 => uint256) public licenseIdForBuild;
    mapping(uint256 => Pricing) public pricingForLicense;

    event TreasurySet(address indexed treasury);

    event BuildRegistered(
        uint256 indexed buildId,
        uint256 indexed licenseId,
        uint256 maxSupply,
        uint256 startPrice,
        uint256 step
    );
    event LicenseMinted(
        uint256 indexed licenseId, address indexed buyer, uint256 qty, uint256 price
    );

    constructor(address buildNFT_, address licenseNFT_, address treasury_) Ownable(msg.sender) {
        require(buildNFT_ != address(0), "buildNFT=0");
        require(licenseNFT_ != address(0), "licenseNFT=0");
        require(treasury_ != address(0), "treasury=0");

        buildNFT = buildNFT_;
        licenseNFT = licenseNFT_;
        treasury = treasury_;

        emit TreasurySet(treasury_);
    }

    // NEW: editable treasury
    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function registerBuild(uint256 buildId, bytes32 expectedGeometryHash) external {
        require(licenseIdForBuild[buildId] == 0, "already registered");
        require(IBuildNFT(buildNFT).isActive(buildId), "inactive build");
        require(IBuildNFT(buildNFT).ownerOf(buildId) == msg.sender, "not owner");
        require(
            IBuildNFT(buildNFT).geometryOf(buildId) == expectedGeometryHash, "geometry mismatch"
        );
        uint256 mass = IBuildNFT(buildNFT).massOf(buildId);
        require(mass > 0, "mass=0");

        uint256 maxSupply = 10_000_000 / mass;
        require(maxSupply > 0, "max=0");

        (uint256 startPriceWei, uint256 maxPriceWei) = _pricingForMaxSupply(maxSupply);
        uint256 stepWei = maxSupply > 1 ? (maxPriceWei - startPriceWei) / (maxSupply - 1) : 0;

        uint256 licenseId = nextLicenseId++;
        licenseIdForBuild[buildId] = licenseId;
        pricingForLicense[licenseId] =
            Pricing({
                startPrice: startPriceWei,
                step: stepWei,
                maxSupply: maxSupply,
                maxPrice: maxPriceWei
            });

        ILicenseNFT(licenseNFT).setMaxSupply(licenseId, maxSupply);

        emit BuildRegistered(buildId, licenseId, maxSupply, startPriceWei, stepWei);
    }

    function quote(uint256 buildId, uint256 qty) external view returns (uint256) {
        uint256 licenseId = licenseIdForBuild[buildId];
        require(licenseId != 0, "not registered");
        return _quoteForLicense(licenseId, qty);
    }

    function mintLicenseForBuild(uint256 buildId, uint256 qty) external payable {
        uint256 licenseId = licenseIdForBuild[buildId];
        require(licenseId != 0, "not registered");
        require(IBuildNFT(buildNFT).isActive(buildId), "inactive build");

        uint256 price = _quoteForLicense(licenseId, qty);
        require(msg.value == price, "bad price");

        // NEW: fail early if this purchase would exceed max supply
        uint256 mintedSoFar = ILicenseNFT(licenseNFT).totalSupply(licenseId);
        uint256 cap = ILicenseNFT(licenseNFT).maxSupply(licenseId);
        require(cap > 0, "max=0");
        require(mintedSoFar + qty <= cap, "max exceeded");

        ILicenseNFT(licenseNFT).mint(msg.sender, licenseId, qty);

        // NEW: forward ETH to treasury immediately
        (bool ok,) = treasury.call{value: msg.value}("");
        require(ok, "treasury xfer");

        emit LicenseMinted(licenseId, msg.sender, qty, price);
    }

    function _quoteForLicense(uint256 licenseId, uint256 qty) internal view returns (uint256) {
        require(qty > 0, "qty=0");
        Pricing memory pricing = pricingForLicense[licenseId];
        require(pricing.maxSupply > 0, "pricing=0");
        uint256 sold = ILicenseNFT(licenseNFT).totalSupply(licenseId);
        require(sold + qty <= pricing.maxSupply, "max exceeded");

        uint256 start = pricing.startPrice + (sold * pricing.step);
        uint256 nMinusOne = qty - 1;
        uint256 series = (start * 2 + (nMinusOne * pricing.step)) * qty;
        return series / 2;
    }

    function _pricingForMaxSupply(uint256 maxSupply)
        internal
        pure
        returns (uint256 startPrice, uint256 maxPrice)
    {
        if (maxSupply >= 1_000_000) return (0.0005 ether, 0.01 ether);
        if (maxSupply >= 500_000) return (0.001 ether, 0.02 ether);
        if (maxSupply >= 250_000) return (0.002 ether, 0.04 ether);
        if (maxSupply >= 100_000) return (0.003 ether, 0.06 ether);
        if (maxSupply >= 50_000) return (0.004 ether, 0.08 ether);
        if (maxSupply >= 25_000) return (0.005 ether, 0.1 ether);
        if (maxSupply >= 10_000) return (0.008 ether, 0.2 ether);
        if (maxSupply >= 5_000) return (0.01 ether, 0.3 ether);
        if (maxSupply >= 1_000) return (0.02 ether, 0.5 ether);
        return (0.05 ether, 1 ether);
    }
}
