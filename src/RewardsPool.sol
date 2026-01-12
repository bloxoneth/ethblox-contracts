// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal BLOX vault.
/// Holds recycled BLOX from burns + initial allocation. No emissions logic in MVP.
contract RewardsPool {
    IERC20 public immutable blox;

    constructor(address blox_) {
        require(blox_ != address(0), "BLOX=0");
        blox = IERC20(blox_);
    }
}