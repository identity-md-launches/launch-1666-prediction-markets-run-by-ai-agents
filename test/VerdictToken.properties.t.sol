// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice Stateless property tests at the edges of the arithmetic: zero, one unit, the whole supply,
///         the maximum, the same call twice, the owner spending its own allowance, the sender who
///         is the zero address. Each fuzz has the edge cases it covers pinned beside it.
/// forge-config: default.fuzz.runs = 1000
contract VerdictTokenPropertiesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    VerdictToken token;

    function setUp() public {
        vm.prank(deployer);
        token = new VerdictToken();
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(deployer);
        token.transfer(who, amount);
    }

    function _bal3() internal view returns (uint256) {
        return token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol);
    }

    // ------------------------------------------------------------------------------------------
    // Round trips and idempotence
    // ------------------------------------------------------------------------------------------

    /// @dev Sending an amount and sending it straight back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresState(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        _fund(alice, funded);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.balanceOf(bob), 0);
        assertEq(_bal3(), SUPPLY);
    }

    /// @dev Splitting a transfer into two parts delivers the same total as one transfer.
    function testFuzz_transferIsAdditive(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(alice, b);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), a + b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// @dev Approving the same value twice is idempotent and overwrites rather than accumulates.
    function testFuzz_approveIsIdempotentAndOverwrites(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        token.approve(bob, first);
        token.approve(bob, first);
        assertEq(token.allowance(alice, bob), first, "double approve accumulated");
        token.approve(bob, second);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), second, "approve did not overwrite");
    }

    /// @dev An allowance does not need a balance to be set: alice holds nothing and approves the max.
    function test_approveWithoutBalanceSucceeds() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, type(uint256).max));
        assertEq(token.allowance(alice, bob), type(uint256).max);
        // ...but it cannot be spent beyond the balance alice actually has (zero).
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Allowance arithmetic
    // ------------------------------------------------------------------------------------------

    /// @dev Spending exactly the allowance leaves zero and a further unit reverts.
    function testFuzz_spendingExactAllowanceLeavesZero(uint256 allowed) public {
        allowed = bound(allowed, 1, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        token.transferFrom(deployer, bob, allowed);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), allowed);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Repeated partial spends decrement the allowance by exactly what was moved, every time.
    function testFuzz_allowanceDecrementsByExactlyWhatWasSpent(uint256 allowed, uint256 s1, uint256 s2) public {
        allowed = bound(allowed, 0, SUPPLY);
        s1 = bound(s1, 0, allowed);
        s2 = bound(s2, 0, allowed - s1);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, s1);
        assertEq(token.allowance(deployer, alice), allowed - s1);
        token.transferFrom(deployer, carol, s2);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), allowed - s1 - s2);
        assertEq(token.balanceOf(bob), s1);
        assertEq(token.balanceOf(carol), s2);
        assertEq(_bal3(), SUPPLY);
    }

    /// @dev One unit below the maximum is a finite allowance and is decremented like any other.
    function test_maxMinusOneAllowanceIsFinite() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    /// @dev The infinite allowance survives spending the whole supply through it.
    function test_infiniteAllowanceSurvivesSpendingWholeSupply() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, SUPPLY);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        // The owner is now empty: the allowance remains but nothing more can be pulled.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Allowances are per (owner, spender): spending one spender's allowance does not touch
    ///      another's, and approving bob does not let carol spend.
    function testFuzz_allowancesAreIndependentPerSpender(uint256 toBob, uint256 toCarol, uint256 spend) public {
        toBob = bound(toBob, 0, SUPPLY);
        toCarol = bound(toCarol, 0, SUPPLY);
        spend = bound(spend, 0, toBob);
        vm.startPrank(deployer);
        token.approve(bob, toBob);
        token.approve(carol, toCarol);
        vm.stopPrank();
        vm.prank(bob);
        token.transferFrom(deployer, alice, spend);
        assertEq(token.allowance(deployer, bob), toBob - spend);
        assertEq(token.allowance(deployer, carol), toCarol, "another spender's allowance moved");
        assertEq(token.allowance(bob, deployer), 0, "allowance is not symmetric");
    }

    /// @dev Approving does not let the spender pull from a third account.
    function test_allowanceDoesNotExtendToOtherOwners() public {
        _fund(alice, 10e18);
        _fund(bob, 10e18);
        vm.prank(alice);
        token.approve(carol, 10e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(bob, carol, 1);
    }

    /// @dev transferFrom where the caller is the owner still needs a self-allowance: there is no
    ///      implicit owner bypass.
    function test_ownerCannotTransferFromItselfWithoutSelfAllowance() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1e18));
        token.transferFrom(alice, bob, 1e18);
    }

    function test_ownerCanTransferFromItselfWithSelfAllowance() public {
        _fund(alice, 10e18);
        vm.startPrank(alice);
        token.approve(alice, 4e18);
        assertTrue(token.transferFrom(alice, bob, 4e18));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 4e18);
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.allowance(alice, alice), 0);
    }

    /// @dev transferFrom back to the owner is a balance no-op but still consumes allowance.
    function test_transferFromToOwnerIsNoOpOnBalanceButSpendsAllowance() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 3e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, 3e18));
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1e18);
        assertEq(token.allowance(deployer, alice), 1e18, "a reverted transferFrom spent allowance");
    }

    /// @dev Zero-value transferFrom with zero allowance succeeds: nothing is spent, nothing moves.
    function test_zeroTransferFromWithoutAllowanceSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // The zero address as a caller
    // ------------------------------------------------------------------------------------------

    /// @dev Nothing is ever credited to the zero address, so it has no balance to send; and the
    ///      library refuses it as a sender outright, before the balance check.
    function test_zeroAddressCannotTransfer() public {
        assertEq(token.balanceOf(address(0)), 0);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(alice, 0);
    }

    function test_zeroAddressCannotApprove() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(alice, 1);
    }

    /// @dev Nobody can pull from the zero address. The allowance is spent before the transfer, so a
    ///      non-zero amount fails the allowance check (the zero address never approved anyone), and
    ///      a zero amount fails inside `_approve` because the zero address may not be an approver.
    ///      Either way nothing moves.
    function test_transferFromZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // Failure paths at the edges, from an arbitrary holder
    // ------------------------------------------------------------------------------------------

    /// @dev Any holder with any balance: one unit over reverts with the exact error and no state change.
    function testFuzz_anyHolderCannotSendOneUnitOverBalance(address holder, uint256 funded) public {
        vm.assume(holder != address(0) && holder != deployer && holder != alice);
        funded = bound(funded, 0, SUPPLY - 1);
        _fund(holder, funded);
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, funded, funded + 1)
        );
        token.transfer(alice, funded + 1);
        assertEq(token.balanceOf(holder), funded);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev The maximum uint256 as an amount is refused from every account, including the deployer.
    function test_maxAmountRevertsEverywhere() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, type(uint256).max)
        );
        token.transfer(bob, type(uint256).max);
    }

    /// @dev A failed transfer changes nothing: balances, supply and allowances all survive it.
    function testFuzz_failedTransferLeavesNoTrace(uint256 funded, uint256 excess) public {
        funded = bound(funded, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - funded);
        _fund(alice, funded);
        vm.prank(alice);
        token.approve(bob, 5);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, funded + excess);
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 5);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Two accounts can never together hold more than the supply, so the library's unchecked
    ///      addition in `_update` cannot overflow: the richest pair sums to exactly the supply.
    function testFuzz_noPairOfBalancesExceedsSupply(uint256 toAlice, uint256 toBob) public {
        toAlice = bound(toAlice, 0, SUPPLY);
        toBob = bound(toBob, 0, SUPPLY - toAlice);
        _fund(alice, toAlice);
        _fund(bob, toBob);
        assertLe(token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(_bal3(), SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // A contract as a holder
    // ------------------------------------------------------------------------------------------

    /// @dev A contract without a receive function holds and moves tokens like an EOA: there is no
    ///      receiver hook that could reject or re-enter.
    function test_contractHolderWithoutHooksReceivesAndSends() public {
        Holder h = new Holder(token);
        _fund(address(h), 7e18);
        assertEq(token.balanceOf(address(h)), 7e18);
        h.send(alice, 7e18);
        assertEq(token.balanceOf(alice), 7e18);
        assertEq(token.balanceOf(address(h)), 0);
    }

    /// @dev Transfer to the token contract itself succeeds and the tokens are stranded there: the
    ///      contract has no way to move them. This is standard ERC-20 behaviour and documented in
    ///      the README's holder-hygiene note.
    function test_transferToTokenContractStrandsTokens() public {
        vm.prank(deployer);
        token.transfer(address(token), 1e18);
        assertEq(token.balanceOf(address(token)), 1e18);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", deployer, 1e18));
        assertFalse(ok, "no rescue path exists");
        assertEq(token.balanceOf(address(token)), 1e18);
    }
}

/// @dev A minimal contract holder with no receive, fallback or hooks.
contract Holder {
    VerdictToken immutable token;

    constructor(VerdictToken token_) {
        token = token_;
    }

    function send(address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }
}
