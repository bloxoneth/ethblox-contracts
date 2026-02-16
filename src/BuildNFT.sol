// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {
    ERC1155Holder
} from "openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol";

interface IDistributor {
    function accrueFromComposition(
        uint256[] calldata buildIds,
        uint256[] calldata counts,
        address payer,
        uint256 buildMass,
        uint256 buildDensity
    ) external payable;
}

interface ILicenseRegistry {
    function licenseIdForBuild(uint256 buildId) external view returns (uint256);
}

/// @notice Single ERC721 for both "bricks" and "builds" in MVP.
/// Locks BLOX on mint, returns 90% on burn, recycles 10% to Distributor.
/// kind=0 is brick; kind>0 is build. Build geometry is consumed forever.
contract BuildNFT is ERC721, Ownable, ReentrancyGuard, ERC1155Holder, EIP712 {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct BrickSpec {
        uint8 width;
        uint8 depth;
        uint16 density;
    }

    struct MintParams {
        bytes32 geometryHash;
        uint256 mass;
        string uri;
        uint8 kind;
        uint8 width;
        uint8 depth;
        uint16 density;
    }

    struct MintReservation {
        address author;
        address reservedFor;
        bytes32 geometryHash;
        uint256 mass;
        bytes32 uriHash;
        bytes32 componentBuildIdsHash;
        bytes32 componentCountsHash;
        uint8 kind;
        uint8 width;
        uint8 depth;
        uint16 density;
        uint256 nonce;
        uint256 expiry;
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
    uint256 public constant RESERVATION_MAX_TTL = 7 days;

    // Fee split in basis points (bps). Sum must be 10_000.
    uint256 public constant LIQUIDITY_BPS = 3_000; // 30%
    uint256 public constant TREASURY_BPS = 2_000; // 20%
    uint256 public constant OWNERS_BPS = 5_000; // 50%
    uint256 public constant MAX_COMPONENT_TYPES = 32;
    uint16 public constant TOTAL_BRICK_SIZES = 55;
    uint8 public constant KIND_BRICK = 0;
    uint8 public constant KIND_BUILD = 1;
    uint8 public constant KIND_COLLECTOR = 2;

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
    mapping(uint256 => uint256) public bwAnchorOf;
    mapping(uint256 => BrickSpec) public brickSpecOf;
    mapping(uint256 => bytes32) public brickSpecKeyOf;
    mapping(uint16 => bool) public brickSizeCovered;
    uint16 public coveredBrickSizes;
    mapping(bytes32 => bool) public geometryConsumed;
    mapping(bytes32 => bool) public brickSpecConsumed;
    // kind IDs 1000+ are reserved for ecosystem/third-party categories (policy only).
    mapping(uint16 => bool) public kindEnabled;

    event KindEnabled(uint16 indexed kind, bool enabled);
    event BrickSizeCovered(uint8 indexed width, uint8 indexed depth, uint16 coveredSizes);
    event ReservationConsumed(bytes32 indexed reservationDigest, address indexed author, address indexed minter);

    mapping(uint256 => uint256[]) private escrowedLicenseIds;
    mapping(uint256 => bool) public burned;
    mapping(bytes32 => bool) public reservationConsumed;

    bytes32 public constant MINT_RESERVATION_TYPEHASH = keccak256(
        "MintReservation(address author,address reservedFor,bytes32 geometryHash,uint256 mass,bytes32 uriHash,bytes32 componentBuildIdsHash,bytes32 componentCountsHash,uint8 kind,uint8 width,uint8 depth,uint16 density,uint256 nonce,uint256 expiry)"
    );

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
    ) ERC721("ETHBLOX Build", "BUILD") Ownable(msg.sender) EIP712("ETHBLOX Build", "1") {
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
        MintParams memory p = MintParams({
            geometryHash: geometryHash,
            mass: mass,
            uri: uri,
            kind: kind,
            width: width,
            depth: depth,
            density: density
        });

        tokenId = _mintCore(p, componentBuildIds, componentCounts, msg.sender, msg.sender);

        _splitFee(msg.value, componentBuildIds, componentCounts, msg.sender, p.mass, p.density);

        emit BuildMinted(tokenId, msg.sender, p.mass, geometryOf[tokenId], p.uri);
    }

    function mintWithReservation(
        MintReservation calldata reservation,
        string calldata uri,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        bytes calldata signature
    ) external payable nonReentrant returns (uint256 tokenId) {
        require(reservation.author != address(0), "author=0");
        require(block.timestamp <= reservation.expiry, "reservation expired");
        require(reservation.expiry - block.timestamp <= RESERVATION_MAX_TTL, "reservation ttl");
        if (reservation.reservedFor != address(0)) {
            require(reservation.reservedFor == msg.sender, "wrong minter");
        }
        require(reservation.uriHash == keccak256(bytes(uri)), "uri hash");
        require(
            reservation.componentBuildIdsHash == keccak256(abi.encode(componentBuildIds)),
            "component ids hash"
        );
        require(
            reservation.componentCountsHash == keccak256(abi.encode(componentCounts)),
            "component counts hash"
        );

        bytes32 digest = reservationDigest(reservation);
        require(!reservationConsumed[digest], "reservation used");
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == reservation.author, "bad reservation sig");
        reservationConsumed[digest] = true;

        tokenId = _mintReserved(reservation, uri, componentBuildIds, componentCounts);

        emit ReservationConsumed(digest, reservation.author, msg.sender);
        emit BuildMinted(tokenId, reservation.author, reservation.mass, geometryOf[tokenId], uri);
    }

    function _mintCore(
        MintParams memory p,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        address payer,
        address creator
    ) internal returns (uint256 tokenId) {
        require(msg.value == FEE_PER_MINT, "bad fee");
        if (p.kind > 0) {
            require(_isKindUnlocked(), "kind locked");
            require(kindEnabled[uint16(p.kind)], "kind disabled");
        }
        require(p.mass > 0, "mass=0");
        require(p.mass <= maxMass, "mass>max");
        require(componentBuildIds.length <= MAX_COMPONENT_TYPES, "too many components");
        require(componentBuildIds.length == componentCounts.length, "component mismatch");
        require(p.geometryHash != bytes32(0), "geometry=0");
        if (p.kind == KIND_BRICK) {
            require(_isAllowedDensity(p.density), "density");
            require(p.width > 0 && p.width <= 10, "width");
            require(p.depth > 0 && p.depth <= 10, "depth");
        } else {
            require(p.density > 0, "density");
            if (p.kind != KIND_COLLECTOR) {
                require(!geometryConsumed[p.geometryHash], "geometry consumed");
            }
        }
        _validateCompositionRules(p, componentBuildIds, componentCounts);

        tokenId = nextTokenId++;
        if (p.kind == KIND_BRICK) {
            bytes32 specKey = _brickSpecKey(p.width, p.depth, p.density);
            require(!brickSpecConsumed[specKey], "brick spec used");
            brickSpecConsumed[specKey] = true;
            _coverBrickSize(p.width, p.depth);
        } else if (p.kind != KIND_COLLECTOR) {
            geometryConsumed[p.geometryHash] = true;
        }

        _handleComponents(p.kind, tokenId, componentBuildIds);
        _lockBlox(payer, tokenId, p.mass);

        massOf[tokenId] = p.mass;
        geometryOf[tokenId] = p.geometryHash;
        creatorOf[tokenId] = creator;
        kindOf[tokenId] = p.kind;
        densityOf[tokenId] = p.density;
        bwAnchorOf[tokenId] =
            p.kind == KIND_COLLECTOR && componentBuildIds.length == 1 ? componentBuildIds[0] : tokenId;
        if (p.kind == KIND_BRICK) {
            brickSpecOf[tokenId] = BrickSpec({width: p.width, depth: p.depth, density: p.density});
            brickSpecKeyOf[tokenId] = _brickSpecKey(p.width, p.depth, p.density);
        }

        _safeMint(payer, tokenId);
    }

    function _mintReserved(
        MintReservation calldata reservation,
        string calldata uri,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts
    ) internal returns (uint256 tokenId) {
        MintParams memory p = MintParams({
            geometryHash: reservation.geometryHash,
            mass: reservation.mass,
            uri: uri,
            kind: reservation.kind,
            width: reservation.width,
            depth: reservation.depth,
            density: reservation.density
        });
        tokenId = _mintCore(p, componentBuildIds, componentCounts, msg.sender, reservation.author);
        _splitReservedFee(componentBuildIds, componentCounts, reservation);
    }

    function _splitReservedFee(
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts,
        MintReservation calldata reservation
    ) internal {
        _splitFee(
            msg.value,
            componentBuildIds,
            componentCounts,
            msg.sender,
            reservation.mass,
            reservation.density
        );
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

        burned[tokenId] = true;

        uint256 recycled = locked / 10; // 10%
        uint256 returned = locked - recycled; // 90%

        // clear per-token state
        delete massOf[tokenId];
        delete geometryOf[tokenId];
        delete lockedBloxOf[tokenId];
        delete creatorOf[tokenId];
        delete kindOf[tokenId];
        delete densityOf[tokenId];
        delete bwAnchorOf[tokenId];
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
        address payer,
        uint256 buildMass,
        uint256 buildDensity
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
                componentBuildIds, componentCounts, payer, buildMass, buildDensity
            );
        }
    }

    function _isAllowedDensity(uint16 density) internal pure returns (bool) {
        return density == 1 || density == 8 || density == 27 || density == 64 || density == 125;
    }

    function _brickSpecKey(uint8 width, uint8 depth, uint16 density) internal pure returns (bytes32) {
        (uint8 w, uint8 d) = _canonicalDims(width, depth);
        return keccak256(abi.encodePacked(w, d, density));
    }

    function _brickSizeKey(uint8 width, uint8 depth) internal pure returns (uint16) {
        (uint8 w, uint8 d) = _canonicalDims(width, depth);
        return (uint16(w) << 8) | uint16(d);
    }

    function _canonicalDims(uint8 width, uint8 depth) internal pure returns (uint8, uint8) {
        return width <= depth ? (width, depth) : (depth, width);
    }

    function _coverBrickSize(uint8 width, uint8 depth) internal {
        uint16 sizeKey = _brickSizeKey(width, depth);
        if (brickSizeCovered[sizeKey]) return;
        brickSizeCovered[sizeKey] = true;
        coveredBrickSizes += 1;
        emit BrickSizeCovered(width, depth, coveredBrickSizes);
    }

    function _isKindUnlocked() internal view returns (bool) {
        return coveredBrickSizes == TOTAL_BRICK_SIZES;
    }

    function _isGenesisNoComponentMint(MintParams memory p) internal pure returns (bool) {
        return p.kind == KIND_BRICK && p.width == 1 && p.depth == 1 && _isAllowedDensity(p.density);
    }

    function _validateCompositionRules(
        MintParams memory p,
        uint256[] calldata componentBuildIds,
        uint256[] calldata componentCounts
    ) internal view {
        if (p.kind == KIND_COLLECTOR) {
            require(p.width == 0 && p.depth == 0, "collector dims");
            require(componentBuildIds.length == 1, "collector component");
            require(componentCounts[0] == 1, "collector count");
            require(_ownerOf(componentBuildIds[0]) != address(0), "component missing");
            require(densityOf[componentBuildIds[0]] == p.density, "component density");
            require(geometryOf[componentBuildIds[0]] == p.geometryHash, "collector geometry");
        }

        if (componentBuildIds.length == 0) {
            if (p.kind == KIND_BRICK) {
                require(_isGenesisNoComponentMint(p), "components required");
            }
            return;
        }

        uint256 componentArea;
        for (uint256 i = 0; i < componentBuildIds.length; i++) {
            if (i > 0) {
                require(componentBuildIds[i] > componentBuildIds[i - 1], "components not sorted");
            }
            require(componentCounts[i] > 0, "component=0");
            require(componentBuildIds[i] != 0, "component=0");
            bool componentExists = _ownerOf(componentBuildIds[i]) != address(0);
            if (!componentExists) {
                require(p.kind != KIND_BRICK, "component missing");
                continue;
            }
            require(densityOf[componentBuildIds[i]] == p.density, "component density");

            if (p.kind != KIND_BRICK) {
                continue;
            }

            require(kindOf[componentBuildIds[i]] == KIND_BRICK, "component kind");
            BrickSpec memory spec = brickSpecOf[componentBuildIds[i]];
            require(spec.width > 0 && spec.depth > 0, "component spec");
            componentArea += uint256(spec.width) * uint256(spec.depth) * componentCounts[i];
        }

        if (p.kind == KIND_BRICK) {
            require(componentArea == uint256(p.width) * uint256(p.depth), "area mismatch");
        }
    }

    function _handleComponents(
        uint8 targetKind,
        uint256 tokenId,
        uint256[] calldata componentBuildIds
    ) internal {
        if (componentBuildIds.length == 0) return;
        if (targetKind == KIND_BRICK) return;
        for (uint256 i = 0; i < componentBuildIds.length; i++) {
            uint256 licenseId =
                ILicenseRegistry(licenseRegistry).licenseIdForBuild(componentBuildIds[i]);
            require(licenseId != 0, "license not registered");

            IERC1155(licenseNFT).safeTransferFrom(msg.sender, address(this), licenseId, 1, "");
            escrowedLicenseIds[tokenId].push(licenseId);
        }
    }

    function _lockBlox(address payer, uint256 tokenId, uint256 mass) internal {
        uint256 lockAmount = mass * BLOX_PER_MASS;
        blox.safeTransferFrom(payer, address(this), lockAmount);
        lockedBloxOf[tokenId] = lockAmount;
    }

    function reservationDigest(MintReservation memory r) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                MINT_RESERVATION_TYPEHASH,
                r.author,
                r.reservedFor,
                r.geometryHash,
                r.mass,
                r.uriHash,
                r.componentBuildIdsHash,
                r.componentCountsHash,
                r.kind,
                r.width,
                r.depth,
                r.density,
                r.nonce,
                r.expiry
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return _isActive(tokenId);
    }

    function isBurned(uint256 tokenId) external view returns (bool) {
        return burned[tokenId];
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function ownerOfSafe(uint256 tokenId) external view returns (address) {
        return _ownerOf(tokenId);
    }

    function isKindUnlocked() external view returns (bool) {
        return _isKindUnlocked();
    }

    function _isActive(uint256 tokenId) internal view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) return false;
        return !burned[tokenId];
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
