// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from
    "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol";

interface IFeeRegistry {
    function accrueFromComposition(uint256[] calldata tokenIds, uint256[] calldata counts) external payable;
}

interface ILicenseRegistry {
    function licenseIdForBuild(uint256 buildId) external view returns (uint256);
}

/// @notice Single ERC721 for both "bricks" and "builds" in MVP.
/// Locks BLOX on mint, returns 90% on burn, recycles 10% to RewardsPool.
/// geometryHash uniqueness is enforced while the build exists; once burned, the hash is reusable.
contract BuildNFT is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ==============================
    // Events
    // ==============================

    event BuildMinted(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 mass,
        bytes32 indexed geometryHash,
        string tokenURI
    );

    event BuildBurned(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 mass,
        bytes32 indexed geometryHash,
        uint256 lockedBloxAmount,
        uint256 returnedToOwner,
        uint256 recycledToRewardsPool
    );

    // ==============================
    // Constants
    // ==============================

    uint256 public constant FEE_PER_MINT = 0.01 ether;
    uint256 public constant BLOX_PER_MASS = 1e18;

    // Fee split in basis points (bps). Sum must be 10_000.
    uint256 public constant LIQUIDITY_BPS = 3_000; // 30%
    uint256 public constant TREASURY_BPS  = 2_000; // 20%
    uint256 public constant OWNERS_BPS    = 5_000; // 50%
    uint256 public constant MAX_COMPONENT_TYPES = 32;

    // ==============================
    // External addresses
    // ==============================

    IERC20 public immutable blox;

    address public rewardsPool;
    address public feeRegistry;
    address public liquidityReceiver;
    address public protocolTreasury;
    address public licenseRegistry;
    address public licenseNFT;

    // ==============================
    // Config / state
    // ==============================

    uint256 public maxMass;
    uint256 public nextTokenId = 1;

    mapping(uint256 => uint256) public massOf;
    mapping(uint256 => bytes32) public geometryOf;
    mapping(uint256 => uint256) public lockedBloxOf;
    mapping(uint256 => address) public creatorOf;

    // Uniqueness enforcement WHILE minted (cleared on burn so hash can be reused).
    mapping(bytes32 => bool) public geometryInUse;
    mapping(uint256 => uint256[]) private escrowedLicenseIds;

    // ==============================
    // Constructor
    // ==============================

    constructor(
        address blox_,
        address rewardsPool_,
        address feeRegistry_,
        address liquidityReceiver_,
        address protocolTreasury_,
        address licenseRegistry_,
        address licenseNFT_,
        uint256 maxMass_
    ) ERC721("ETHBLOX Build", "BUILD") Ownable(msg.sender) {
        require(blox_ != address(0), "BLOX=0");
        require(rewardsPool_ != address(0), "rewards=0");
        require(feeRegistry_ != address(0), "registry=0");
        require(liquidityReceiver_ != address(0), "liquidity=0");
        require(protocolTreasury_ != address(0), "treasury=0");
        require(licenseRegistry_ != address(0), "licenseRegistry=0");
        require(licenseNFT_ != address(0), "licenseNFT=0");
        require(maxMass_ > 0, "maxMass=0");
        require(LIQUIDITY_BPS + TREASURY_BPS + OWNERS_BPS == 10_000, "bad bps");

        blox = IERC20(blox_);
        rewardsPool = rewardsPool_;
        feeRegistry = feeRegistry_;
        liquidityReceiver = liquidityReceiver_;
        protocolTreasury = protocolTreasury_;
        licenseRegistry = licenseRegistry_;
        licenseNFT = licenseNFT_;
        maxMass = maxMass_;
    }

    // ==============================
    // Mint
    // ==============================

    function mint(
        bytes32 geometryHash,
        uint256 mass,
        string calldata uri,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts
    ) external payable nonReentrant returns (uint256 tokenId) {
        require(msg.value == FEE_PER_MINT, "bad fee");
        require(mass > 0, "mass=0");
        require(mass <= maxMass, "mass>max");
        require(!geometryInUse[geometryHash], "geometry in use");
        require(componentBuildIds.length <= MAX_COMPONENT_TYPES, "too many components");
        require(componentBuildIds.length == componentCounts.length, "component mismatch");

        tokenId = nextTokenId++;
        if (componentBuildIds.length > 0) {
            for (uint256 i = 0; i < componentBuildIds.length; i++) {
                if (i > 0) {
                    require(
                        componentBuildIds[i] > componentBuildIds[i - 1],
                        "components not sorted"
                    );
                }

                uint256 licenseId = ILicenseRegistry(licenseRegistry)
                    .licenseIdForBuild(componentBuildIds[i]);
                require(licenseId != 0, "license not registered");

                IERC1155(licenseNFT).safeTransferFrom(
                    msg.sender,
                    address(this),
                    licenseId,
                    1,
                    ""
                );
                escrowedLicenseIds[tokenId].push(licenseId);
            }
        }

        // lock BLOX after escrow validation/transfers
        uint256 lockAmount = mass * BLOX_PER_MASS;
        blox.safeTransferFrom(msg.sender, address(this), lockAmount);

        // now reserve the geometry hash
        geometryInUse[geometryHash] = true;

        massOf[tokenId] = mass;
        geometryOf[tokenId] = geometryHash;
        lockedBloxOf[tokenId] = lockAmount;
        creatorOf[tokenId] = msg.sender;

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, uri);

        // fee split (computed as % of msg.value to keep future-proof)
        uint256 liquidityAmt = (msg.value * LIQUIDITY_BPS) / 10_000;
        uint256 treasuryAmt  = (msg.value * TREASURY_BPS) / 10_000;
        uint256 ownersAmt    = msg.value - liquidityAmt - treasuryAmt; // exact remainder-safe

        _payETH(liquidityReceiver, liquidityAmt);
        _payETH(protocolTreasury, treasuryAmt);

        // owners slice: accrue to registry if components provided, else treasury fallback
        if (componentBuildIds.length == 0) {
            _payETH(protocolTreasury, ownersAmt);
        } else {
            IFeeRegistry(feeRegistry).accrueFromComposition{value: ownersAmt}(componentBuildIds, componentCounts);
        }

        emit BuildMinted(tokenId, msg.sender, mass, geometryHash, uri);
    }

    // ==============================
    // Burn
    // ==============================

    function burn(uint256 tokenId) external nonReentrant {
        // ownerOf() reverts if token doesn't exist
        address owner = ownerOf(tokenId);

        require(
            msg.sender == owner || getApproved(tokenId) == msg.sender || isApprovedForAll(owner, msg.sender),
            "not owner/approved"
        );

        uint256 mass = massOf[tokenId];
        bytes32 gh = geometryOf[tokenId];
        uint256 locked = lockedBloxOf[tokenId];

        uint256 recycled = locked / 10;        // 10%
        uint256 returned = locked - recycled;  // 90%

        // allow geometry reuse after burn
        geometryInUse[gh] = false;

        // clear per-token state
        delete massOf[tokenId];
        delete geometryOf[tokenId];
        delete lockedBloxOf[tokenId];
        delete creatorOf[tokenId];

        uint256[] memory escrowed = escrowedLicenseIds[tokenId];
        delete escrowedLicenseIds[tokenId];

        _burn(tokenId);

        for (uint256 i = 0; i < escrowed.length; i++) {
            IERC1155(licenseNFT).safeTransferFrom(address(this), owner, escrowed[i], 1, "");
        }

        if (returned > 0) blox.safeTransfer(owner, returned);
        if (recycled > 0) blox.safeTransfer(rewardsPool, recycled);

        emit BuildBurned(tokenId, owner, mass, gh, locked, returned, recycled);
    }

    // ==============================
    // Admin setters
    // ==============================

    function setMaxMass(uint256 newMaxMass) external onlyOwner {
        require(newMaxMass > 0, "maxMass=0");
        maxMass = newMaxMass;
    }

    function setLiquidityReceiver(address a) external onlyOwner {
        require(a != address(0), "0");
        liquidityReceiver = a;
    }

    function setProtocolTreasury(address a) external onlyOwner {
        require(a != address(0), "0");
        protocolTreasury = a;
    }

    function setFeeRegistry(address a) external onlyOwner {
        require(a != address(0), "0");
        feeRegistry = a;
    }

    function setRewardsPool(address a) external onlyOwner {
        require(a != address(0), "0");
        rewardsPool = a;
    }

    // ==============================
    // Internals
    // ==============================

    function _payETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return ERC721URIStorage.tokenURI(tokenId);
    }
}
