// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Splitter + upgrade router for BLOX emissions.
/// - Owner should be a Gnosis Safe (day 1)
/// - Rules sum to 10_000 bps
/// - Anyone can call distribute()
/// - Optional: forward all funds to a new distributor (no proxy upgrade)
/// - Optional: freeze rules forever for credibility
interface IBuildNFTView {
    function ownerOf(uint256 tokenId) external view returns (address);
    function lockedBloxOf(uint256 tokenId) external view returns (uint256);
    function isActive(uint256 tokenId) external view returns (bool);
}

contract Distributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable blox;

    // --- ownership (2-step) ---
    address public owner;
    address public pendingOwner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // --- distribution rules ---
    struct Rule {
        address to;
        uint16 bps; // out of 10_000
    }

    Rule[] public rules;
    bool public rulesFrozen;

    // --- upgrade router ---
    address public forwardTo; // if set, forwards entire balance to this address

    // --- usage fee registry ---
    address public buildNFT;
    address public protocolTreasury;
    mapping(uint256 => mapping(address => bool)) public hasUsed;
    mapping(uint256 => uint256) public uniqueUsers;
    mapping(address => uint256) public ethOwed;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event RulesSet(uint256 count);
    event RulesFrozen();
    event ForwardToSet(address indexed forwardTo);

    event Distributed(uint256 balanceBefore, uint256 sentTotal);
    event Forwarded(address indexed forwardTo, uint256 amount);

    event BuildNFTSet(address indexed buildNFT);
    event ProtocolTreasurySet(address indexed protocolTreasury);
    event UsageAccrued(
        uint256 indexed buildId,
        address indexed payer,
        address indexed owner,
        uint256 amount,
        bool selfBlocked
    );
    event Claimed(address indexed owner, address indexed to, uint256 amount);

    constructor(address blox_, address owner_) {
        require(blox_ != address(0), "BLOX=0");
        require(owner_ != address(0), "owner=0");
        blox = IERC20(blox_);
        owner = owner_;
    }

    receive() external payable {}

    // -------- ownership --------

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pendingOwner");
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, owner);
    }

    // -------- config --------

    function setRules(Rule[] calldata newRules) external onlyOwner {
        require(!rulesFrozen, "rules frozen");

        delete rules;

        uint256 total;
        for (uint256 i = 0; i < newRules.length; i++) {
            address to = newRules[i].to;
            uint16 bps = newRules[i].bps;

            require(to != address(0), "rule to=0");
            require(bps > 0, "rule bps=0");

            total += bps;
            rules.push(Rule({to: to, bps: bps}));
        }

        require(total == 10_000, "bps != 100%");
        emit RulesSet(newRules.length);
    }

    /// @notice Optional credibility lever: permanently freeze rules.
    function freezeRules() external onlyOwner {
        require(!rulesFrozen, "already frozen");
        rulesFrozen = true;
        emit RulesFrozen();
    }

    /// @notice Optional upgrade path: forward all future distributions to a new contract.
    /// Set to zero address to disable forwarding.
    function setForwardTo(address forwardTo_) external onlyOwner {
        forwardTo = forwardTo_;
        emit ForwardToSet(forwardTo_);
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

    // -------- view helpers --------

    function rulesLength() external view returns (uint256) {
        return rules.length;
    }

    function accrueFromComposition(
        uint256[] calldata buildIds,
        uint256[] calldata counts,
        address payer
    ) external payable nonReentrant {
        require(msg.value > 0, "no fee");
        require(msg.sender == buildNFT, "only buildNFT");
        require(buildNFT != address(0), "buildNFT=0");
        require(protocolTreasury != address(0), "treasury=0");
        require(buildIds.length == counts.length, "len");
        require(buildIds.length > 0, "no components");
        require(buildIds.length <= 32, "too many");

        uint256 len = buildIds.length;
        uint256 totalWeight;
        uint256 liveWeight;
        uint256 lastIndex = len - 1;
        uint256[] memory weights = new uint256[](len);
        bool[] memory burned = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            if (i > 0) {
                require(buildIds[i] > buildIds[i - 1], "not sorted");
            }
            require(counts[i] > 0, "count=0");

            uint256 buildId = buildIds[i];
            if (!IBuildNFTView(buildNFT).isActive(buildId)) {
                burned[i] = true;
                weights[i] = 1;
                totalWeight += 1;
                continue;
            }

            if (!hasUsed[buildId][payer]) {
                hasUsed[buildId][payer] = true;
                uniqueUsers[buildId] += 1;
            }

            uint256 lockedBlox = IBuildNFTView(buildNFT).lockedBloxOf(buildId);
            uint256 baseWeight = lockedBlox / 1e12;
            if (baseWeight == 0) baseWeight = 1;
            uint256 weight = baseWeight * (1 + uniqueUsers[buildId]);
            weights[i] = weight;
            totalWeight += weight;
            liveWeight += weight;
        }

        if (liveWeight == 0) {
            ethOwed[protocolTreasury] += msg.value;
            emit UsageAccrued(0, payer, protocolTreasury, msg.value, false);
            return;
        }
        uint256 remaining = msg.value;

        for (uint256 i = 0; i < len; i++) {
            uint256 buildId = buildIds[i];
            uint256 amount = (msg.value * weights[i]) / totalWeight;
            if (i == lastIndex) {
                amount = remaining;
            } else {
                remaining -= amount;
            }

            if (burned[i]) {
                ethOwed[protocolTreasury] += amount;
                emit UsageAccrued(buildId, payer, address(0), amount, false);
            } else {
                address ownerOfBuild = IBuildNFTView(buildNFT).ownerOf(buildId);
                ethOwed[ownerOfBuild] += amount;
                emit UsageAccrued(buildId, payer, ownerOfBuild, amount, false);
            }
        }
    }

    // -------- distribution --------

    /// @notice Distribute the current BLOX balance according to rules,
    /// or forward entire balance to `forwardTo` if set.
    function distribute() external {
        uint256 balance = blox.balanceOf(address(this));
        require(balance > 0, "no balance");

        address fwd = forwardTo;
        if (fwd != address(0)) {
            blox.safeTransfer(fwd, balance);
            emit Forwarded(fwd, balance);
            return;
        }
        uint256 len = rules.length;
        require(len > 0, "no rules");

        uint256 sentTotal;

        // Send pro-rata, then send rounding dust to the last rule
        for (uint256 i = 0; i < len; i++) {
            uint256 amount = (balance * rules[i].bps) / 10_000;

            if (i == len - 1) {
                // give the remainder/dust to last receiver
                amount = balance - sentTotal;
            }

            if (amount > 0) {
                blox.safeTransfer(rules[i].to, amount);
                sentTotal += amount;
            }
        }

        emit Distributed(balance, sentTotal);
    }

    function claim() external nonReentrant {
        uint256 amt = ethOwed[msg.sender];
        require(amt > 0, "nothing");
        ethOwed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "eth xfer");
        emit Claimed(msg.sender, msg.sender, amt);
    }

    function claimTo(address to) external nonReentrant {
        uint256 amt = ethOwed[msg.sender];
        require(amt > 0, "nothing");
        ethOwed[msg.sender] = 0;
        (bool ok,) = to.call{value: amt}("");
        require(ok, "eth xfer");
        emit Claimed(msg.sender, to, amt);
    }
}
