// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {
    ERC1155Holder
} from "openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol";

interface IDistributor {
    function accrueFromComposition(
        uint256[] calldata buildIds,
        uint256[] calldata counts,
        address payer
    ) external payable;
}

interface ILicenseRegistry {
    function licenseIdForBuild(uint256 buildId) external view returns (uint256);
}

/// @notice Single ERC721 for both "bricks" and "builds" in MVP.
/// Locks BLOX on mint, returns 90% on burn, recycles 10% to Distributor.
/// kind=0 is brick; kind>0 is build. Build geometry is consumed forever.
contract BuildNFT is ERC721, Ownable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct BrickSpec {
        uint8 width;
        uint8 depth;
        uint16 density;
    }

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
        uint256 recycledToDistributor
    );

    // ==============================
    // Constants
    // ==============================

    uint256 public constant FEE_PER_MINT = 0.01 ether;
    uint256 public constant BLOX_PER_MASS = 1e18;

    // Fee split in basis points (bps). Sum must be 10_000.
    uint256 public constant LIQUIDITY_BPS = 3_000; // 30%
    uint256 public constant TREASURY_BPS = 2_000; // 20%
    uint256 public constant OWNERS_BPS = 5_000; // 50%
    uint256 public constant MAX_COMPONENT_TYPES = 32;
    uint8 public constant KIND_BRICK = 0;
    uint8 public constant KIND_BUILD = 1;

    // ==============================
    // External addresses
    // ==============================

    IERC20 public immutable blox;

    string public baseTokenURI;

    address public distributor;
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
    mapping(uint256 => uint8) public kindOf;
    mapping(uint256 => uint16) public densityOf;
    mapping(uint256 => BrickSpec) public brickSpecOf;
    mapping(uint256 => bytes32) public brickSpecKeyOf;
    mapping(bytes32 => bool) public geometryConsumed;
    mapping(bytes32 => mapping(uint16 => bool)) public brickSpecConsumed;
    // kind IDs 1000+ are reserved for ecosystem/third-party categories (policy only).
    mapping(uint16 => bool) public kindEnabled;

    event KindEnabled(uint16 indexed kind, bool enabled);

    mapping(uint256 => uint256[]) private escrowedLicenseIds;

    // ==============================
    // Constructor
    // ==============================

    constructor(
        address blox_,
        address distributor_,
        address liquidityReceiver_,
        address protocolTreasury_,
        address licenseRegistry_,
        address licenseNFT_,
        uint256 maxMass_
    ) ERC721("ETHBLOX Build", "BUILD") Ownable(msg.sender) {
        require(blox_ != address(0), "BLOX=0");
        require(distributor_ != address(0), "distributor=0");
        require(liquidityReceiver_ != address(0), "liquidity=0");
        require(protocolTreasury_ != address(0), "treasury=0");
        require(licenseRegistry_ != address(0), "licenseRegistry=0");
        require(licenseNFT_ != address(0), "licenseNFT=0");
        require(maxMass_ > 0, "maxMass=0");
        require(LIQUIDITY_BPS + TREASURY_BPS + OWNERS_BPS == 10_000, "bad bps");

        blox = IERC20(blox_);
        distributor = distributor_;
        liquidityReceiver = liquidityReceiver_;
        protocolTreasury = protocolTreasury_;
        licenseRegistry = licenseRegistry_;
        licenseNFT = licenseNFT_;
        maxMass = maxMass_;
        // kind 0 is reserved for bricks and is always allowed.
    }

    // ==============================
    // Mint
    // ==============================

    function mint(
        bytes32 geometryHash,
        uint256 mass,
        string calldata uri,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        uint8 kind,
        uint8 width,
        uint8 depth,
        uint16 density
    ) external payable nonReentrant returns (uint256 tokenId) {
        require(msg.value == FEE_PER_MINT, "bad fee");
        if (kind > 0) {
            require(kindEnabled[uint16(kind)], "kind disabled");
        }
        require(mass > 0, "mass=0");
        require(mass <= maxMass, "mass>max");
        require(componentBuildIds.length <= MAX_COMPONENT_TYPES, "too many components");
        require(componentBuildIds.length == componentCounts.length, "component mismatch");
        require(geometryHash != bytes32(0), "geometry=0");
        if (kind == KIND_BRICK) {
            require(_isAllowedDensity(density), "density");
        } else {
            require(density > 0, "density");
            require(!geometryConsumed[geometryHash], "geometry consumed");
        }

        tokenId = nextTokenId++;
        if (kind == KIND_BRICK) {
            require(width > 0 && width <= 20, "width");
            require(depth > 0 && depth <= 20, "depth");
            bytes32 specKey = keccak256(abi.encodePacked(geometryHash, width, depth));
            require(!brickSpecConsumed[specKey][density], "brick spec used");
            brickSpecConsumed[specKey][density] = true;
        } else {
            geometryConsumed[geometryHash] = true;
        }
        if (componentBuildIds.length > 0) {
            for (uint256 i = 0; i < componentBuildIds.length; i++) {
                if (i > 0) {
                    require(
                        componentBuildIds[i] > componentBuildIds[i - 1], "components not sorted"
                    );
                }
                // counts are informational only (future metadata), not used for economics.
                require(componentCounts[i] > 0, "component=0");
                require(componentBuildIds[i] != 0, "component=0");

                uint256 licenseId =
                    ILicenseRegistry(licenseRegistry).licenseIdForBuild(componentBuildIds[i]);
                require(licenseId != 0, "license not registered");

                IERC1155(licenseNFT).safeTransferFrom(msg.sender, address(this), licenseId, 1, "");
                escrowedLicenseIds[tokenId].push(licenseId);
            }
        }

        {
            uint256 lockAmount = mass * BLOX_PER_MASS;
            blox.safeTransferFrom(msg.sender, address(this), lockAmount);
            lockedBloxOf[tokenId] = lockAmount;
        }

        massOf[tokenId] = mass;
        geometryOf[tokenId] = geometryHash;
        creatorOf[tokenId] = msg.sender;
        kindOf[tokenId] = kind;
        densityOf[tokenId] = density;
        if (kind == KIND_BRICK) {
            brickSpecOf[tokenId] = BrickSpec({width: width, depth: depth, density: density});
            brickSpecKeyOf[tokenId] = keccak256(abi.encodePacked(geometryHash, width, depth));
        }

        _safeMint(msg.sender, tokenId);

        _splitFee(msg.value, componentBuildIds, componentCounts, msg.sender);

        emit BuildMinted(tokenId, msg.sender, mass, geometryOf[tokenId], uri);
    }

    // ==============================
    // Burn
    // ==============================

    function burn(uint256 tokenId) external nonReentrant {
        // ownerOf() reverts if token doesn't exist
        address owner = ownerOf(tokenId);
        require(kindOf[tokenId] != KIND_BRICK, "brick");

        require(
            msg.sender == owner || getApproved(tokenId) == msg.sender
                || isApprovedForAll(owner, msg.sender),
            "not owner/approved"
        );

        uint256 mass = massOf[tokenId];
        bytes32 gh = geometryOf[tokenId];
        uint256 locked = lockedBloxOf[tokenId];

        uint256 recycled = locked / 10; // 10%
        uint256 returned = locked - recycled; // 90%

        // clear per-token state
        delete massOf[tokenId];
        delete geometryOf[tokenId];
        delete lockedBloxOf[tokenId];
        delete creatorOf[tokenId];
        delete kindOf[tokenId];
        delete densityOf[tokenId];
        delete brickSpecOf[tokenId];
        delete brickSpecKeyOf[tokenId];

        uint256[] memory escrowed = escrowedLicenseIds[tokenId];
        delete escrowedLicenseIds[tokenId];

        _burn(tokenId);

        for (uint256 i = 0; i < escrowed.length; i++) {
            IERC1155(licenseNFT).safeTransferFrom(address(this), owner, escrowed[i], 1, "");
        }

        if (returned > 0) blox.safeTransfer(owner, returned);
        if (recycled > 0) blox.safeTransfer(distributor, recycled);

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

    function setDistributor(address a) external onlyOwner {
        require(a != address(0), "0");
        distributor = a;
    }

    function setKindEnabled(uint16 kind, bool enabled) external onlyOwner {
        require(kind != 0, "reserved");
        kindEnabled[kind] = enabled;
        emit KindEnabled(kind, enabled);
    }

    function setBaseTokenURI(string calldata newBase) external onlyOwner {
        baseTokenURI = newBase;
    }

    // ==============================
    // Internals
    // ==============================

    function _payETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function _splitFee(
        uint256 fee,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        address payer
    ) internal {
        uint256 liquidityAmt = (fee * LIQUIDITY_BPS) / 10_000;
        uint256 treasuryAmt = (fee * TREASURY_BPS) / 10_000;
        uint256 ownersAmt = fee - liquidityAmt - treasuryAmt;

        _payETH(liquidityReceiver, liquidityAmt);
        _payETH(protocolTreasury, treasuryAmt);

        if (componentBuildIds.length == 0) {
            _payETH(protocolTreasury, ownersAmt);
        } else {
            IDistributor(distributor).accrueFromComposition{value: ownersAmt}(
                componentBuildIds, componentCounts, payer
            );
        }
    }

    function _isAllowedDensity(uint16 density) internal pure returns (bool) {
        return density == 1 || density == 8 || density == 27 || density == 64 || density == 125;
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return _isActive(tokenId);
    }

    function _isActive(uint256 tokenId) internal view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) return false;
        return kindOf[tokenId] != KIND_BRICK;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721)
        returns (string memory)
    {
        require(_ownerOf(tokenId) != address(0), "ERC721: invalid token ID");
        string memory base = baseTokenURI;
        if (bytes(base).length == 0) return "";
        return string.concat(base, "/", tokenId.toString(), ".json");
    }
}
