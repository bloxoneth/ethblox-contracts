// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBuildNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function geometryOf(uint256 tokenId) external view returns (bytes32);
}

interface ILicenseNFT {
    function setMaxSupply(uint256 id, uint256 max) external;
    function mint(address to, uint256 id, uint256 qty) external;
}

contract LicenseRegistry {
    struct Pricing {
        uint256 startPrice;
        uint256 step;
        uint256 maxSupply;
    }

    address public buildNFT;
    address public licenseNFT;
    uint256 public nextLicenseId = 1;

    mapping(uint256 => uint256) public licenseIdForBuild;
    mapping(uint256 => Pricing) public pricingForLicense;

    event BuildRegistered(
        uint256 indexed buildId,
        uint256 indexed licenseId,
        uint256 maxSupply,
        uint256 startPrice,
        uint256 step
    );
    event LicenseMinted(uint256 indexed licenseId, address indexed buyer, uint256 qty, uint256 price);

    constructor(address buildNFT_, address licenseNFT_) {
        require(buildNFT_ != address(0), "buildNFT=0");
        require(licenseNFT_ != address(0), "licenseNFT=0");
        buildNFT = buildNFT_;
        licenseNFT = licenseNFT_;
    }

    function registerBuild(
        uint256 buildId,
        bytes32 expectedGeometryHash,
        uint256 maxSupply,
        uint256 startPriceWei,
        uint256 stepWei
    ) external {
        require(licenseIdForBuild[buildId] == 0, "already registered");
        require(IBuildNFT(buildNFT).ownerOf(buildId) == msg.sender, "not owner");
        require(
            IBuildNFT(buildNFT).geometryOf(buildId) == expectedGeometryHash,
            "geometry mismatch"
        );
        require(maxSupply > 0, "max=0");

        uint256 licenseId = nextLicenseId++;
        licenseIdForBuild[buildId] = licenseId;
        pricingForLicense[licenseId] = Pricing({
            startPrice: startPriceWei,
            step: stepWei,
            maxSupply: maxSupply
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
        uint256 price = _quoteForLicense(licenseId, qty);
        require(msg.value == price, "bad price");

        ILicenseNFT(licenseNFT).mint(msg.sender, licenseId, qty);

        emit LicenseMinted(licenseId, msg.sender, qty, price);
    }

    function _quoteForLicense(uint256 licenseId, uint256 qty) internal view returns (uint256) {
        require(qty > 0, "qty=0");
        Pricing memory pricing = pricingForLicense[licenseId];
        require(pricing.maxSupply > 0, "pricing=0");

        uint256 twoA = pricing.startPrice * 2;
        uint256 nMinusOne = qty - 1;
        uint256 series = (twoA + (nMinusOne * pricing.step)) * qty;
        return series / 2;
    }
}
