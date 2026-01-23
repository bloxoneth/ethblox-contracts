// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "openzeppelin-contracts/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract LicenseNFT is ERC1155, ERC1155Supply, Ownable {
    address public registry;
    mapping(uint256 => uint256) public maxSupply;

    constructor(string memory uri) ERC1155(uri) Ownable(msg.sender) {}

    modifier onlyRegistry() {
        require(msg.sender == registry, "not registry");
        _;
    }

    function setRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0), "registry=0");
        registry = newRegistry;
    }

    function setMaxSupply(uint256 id, uint256 max) external {
        if (registry != address(0)) {
            require(msg.sender == registry, "not registry");
        } else {
            require(msg.sender == owner(), "not owner");
        }
        require(max >= totalSupply(id), "max<ts");
        maxSupply[id] = max;
    }

    function mint(address to, uint256 id, uint256 qty) external onlyRegistry {
        require(maxSupply[id] > 0, "max=0");
        require(totalSupply(id) + qty <= maxSupply[id], "max exceeded");
        _mint(to, id, qty, "");
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }
}
