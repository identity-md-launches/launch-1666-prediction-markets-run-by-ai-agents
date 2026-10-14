// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice Drives the token with random transfers, approvals and transferFroms from a fixed set of
///         actors. Reverting calls are allowed (insufficient balance or allowance is expected).
contract VerdictHandler is Test {
    VerdictToken public immutable token;
    address[] public actors;

    constructor(VerdictToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 bal = token.balanceOf(owner);
        if (bal < cap) cap = bal;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract VerdictTokenInvariantTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    VerdictToken token;
    VerdictHandler handler;
    address[] actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new VerdictToken();

        actors.push(deployer);
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
        actors.push(makeAddr("a4"));

        handler = new VerdictHandler(token, actors);
        targetContract(address(handler));
    }

    /// @dev Supply is fixed forever: nothing mints and nothing burns.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev Every token is held by one of the actors: transfers neither create nor destroy value.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, EXPECTED_SUPPLY);
    }

    /// @dev Nothing leaks to the handler, the token itself or the zero address.
    function invariant_noStrayBalances() public view {
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }
}
