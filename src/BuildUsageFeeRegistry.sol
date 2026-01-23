// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IBuildNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Receives the 50% mint fee slice (0.005 ETH) and accrues it to component owners.
/// Owner is determined at time of mint via BuildNFT.ownerOf(tokenId).
contract BuildUsageFeeRegistry is Ownable, ReentrancyGuard {
    event CompositionFeeAccrued(
        uint256 indexed tokenId, address indexed owner, uint256 count, uint256 ethAmount
    );
    event FeesClaimed(address indexed claimer, uint256 amount);
    event BuildNFTSet(address indexed buildNFT);
    event ProtocolTreasurySet(address indexed protocolTreasury);

    uint256 public constant OWNER_SLICE_PER_MINT = 0.005 ether;
    uint256 public constant MAX_COMPONENTS = 16;

    address public buildNFT;
    address public protocolTreasury;

    mapping(address => uint256) public accruedETH;
    mapping(uint256 => uint256) public usageCount;

    constructor(address protocolTreasury_) Ownable(msg.sender) {
        require(protocolTreasury_ != address(0), "treasury=0");
        protocolTreasury = protocolTreasury_;
    }

    function setBuildNFT(address buildNFT_) external onlyOwner {
        require(buildNFT_ != address(0), "buildNFT=0");
        buildNFT = buildNFT_;
        emit BuildNFTSet(buildNFT_);
    }

    function setProtocolTreasury(address protocolTreasury_) external onlyOwner {
        require(protocolTreasury_ != address(0), "treasury=0");
        protocolTreasury = protocolTreasury_;
        emit ProtocolTreasurySet(protocolTreasury_);
    }

    function accrueFromComposition(uint256[] calldata tokenIds, uint256[] calldata counts)
        external
        payable
    {
        require(msg.sender == buildNFT, "only BuildNFT");
        require(msg.value == OWNER_SLICE_PER_MINT, "bad msg.value");

        uint256 len = tokenIds.length;
        require(len > 0, "empty");
        require(len == counts.length, "length mismatch");
        require(len <= MAX_COMPONENTS, "too many");

        uint256 totalCount = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 c = counts[i];

            require(c > 0, "count=0");
            if (i > 0) require(tokenId > tokenIds[i - 1], "not increasing");

            usageCount[tokenId] += c;
            totalCount += c;
        }

        require(totalCount > 0, "totalCount=0");

        uint256 ethPerUnit = msg.value / totalCount;
        uint256 distributed = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 c = counts[i];

            address owner = IBuildNFT(buildNFT).ownerOf(tokenId);
            uint256 share = ethPerUnit * c;

            accruedETH[owner] += share;
            distributed += share;

            emit CompositionFeeAccrued(tokenId, owner, c, share);
        }

        uint256 remainder = msg.value - distributed;
        if (remainder > 0) {
            accruedETH[protocolTreasury] += remainder;
        }
    }

    function claim() external nonReentrant {
        uint256 amount = accruedETH[msg.sender];
        require(amount > 0, "nothing to claim");

        accruedETH[msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit FeesClaimed(msg.sender, amount);
    }

    receive() external payable {
        revert("direct ETH not allowed");
    }
}
