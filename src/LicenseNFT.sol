// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {
    ERC1155Supply
} from "openzeppelin-contracts/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract LicenseNFT is ERC1155, ERC1155Supply, Ownable {
    address public registry;
    mapping(uint256 => uint256) public maxSupply;

    // NEW: events (safe addition)
    event RegistrySet(address indexed registry);
    event MaxSupplySet(uint256 indexed id, uint256 max);
    event LicenseMinted(address indexed to, uint256 indexed id, uint256 qty);
    event LicenseBurned(address indexed from, uint256 indexed id, uint256 qty);
    event BaseURISet(string newUri);

    constructor(string memory uri) ERC1155(uri) Ownable(msg.sender) {}

    modifier onlyRegistry() {
        require(msg.sender == registry, "not registry");
        _;
    }

    function setRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0), "registry=0");
        registry = newRegistry;

        // NEW: emit
        emit RegistrySet(newRegistry);
    }

    function setMaxSupply(uint256 id, uint256 max) external {
        if (registry != address(0)) {
            require(msg.sender == registry, "not registry");
        } else {
            require(msg.sender == owner(), "not owner");
        }
        require(max >= totalSupply(id), "max<ts");
        maxSupply[id] = max;

        // NEW: emit
        emit MaxSupplySet(id, max);
    }

    function mint(address to, uint256 id, uint256 qty) external onlyRegistry {
        require(maxSupply[id] > 0, "max=0");
        require(totalSupply(id) + qty <= maxSupply[id], "max exceeded");
        _mint(to, id, qty, "");

        // NEW: emit
        emit LicenseMinted(to, id, qty);
    }

    // NEW: batch mint helper (registry-only)
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata qtys)
        external
        onlyRegistry
    {
        require(ids.length == qtys.length, "len");
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 qty = qtys[i];
            require(maxSupply[id] > 0, "max=0");
            require(totalSupply(id) + qty <= maxSupply[id], "max exceeded");
        }
        _mintBatch(to, ids, qtys, "");
        // optional: emit per-id would be more indexable; keeping it minimal to avoid loops of events
    }

    // NEW: burn (registry-only) for escrow/reclaim flows
    // Note: registry can burn from any address. This is intentional for protocol-controlled flows.
    function burn(address from, uint256 id, uint256 qty) external onlyRegistry {
        _burn(from, id, qty);
        emit LicenseBurned(from, id, qty);
    }

    // NEW: optional base URI setter (owner-only)
    function setURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
        emit BaseURISet(newUri);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }
}
