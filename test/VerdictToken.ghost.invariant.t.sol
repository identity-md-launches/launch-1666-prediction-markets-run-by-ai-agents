// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice Drives the token with a mixed workload and keeps its own ledger (ghost balances and
///         allowances) as an oracle. Every action the handler takes is either expected to succeed,
///         in which case the ledger is updated, or expected to fail, in which case the handler
///         asserts the exact revert and leaves the ledger alone. Unexpected reverts fail the run.
contract VerdictGhostHandler is Test {
    VerdictToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostTransferredOut; // total that has ever left the deployer by any route
    uint256 public ghostMoved; // total value moved by successful transfers (excluding self-sends)
    uint256 public successfulCalls;
    uint256 public expectedFailures;
    uint256 public privilegedAttempts;

    string[14] private privileged = [
        "mint(address,uint256)",
        "mint(uint256)",
        "burn(uint256)",
        "burnFrom(address,uint256)",
        "pause()",
        "unpause()",
        "blacklist(address)",
        "freeze(address)",
        "seize(address)",
        "setOwner(address)",
        "transferOwnership(address)",
        "upgradeTo(address)",
        "initialize(address)",
        "setTransfersEnabled(bool)"
    ];

    constructor(VerdictToken token_, address[] memory actors_, address deployer_) {
        token = token_;
        actors = actors_;
        ghostBalance[deployer_] = token.totalSupply();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _deployer() internal view returns (address) {
        return actors[0];
    }

    // ---- expected to succeed --------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (from != to) {
            ghostMoved += amount;
            if (from == _deployer()) ghostTransferredOut += amount;
        }
        ++successfulCalls;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        ++successfulCalls;
    }

    function approveMax(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;
        ++successfulCalls;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        if (owner != to) {
            ghostMoved += amount;
            if (owner == _deployer()) ghostTransferredOut += amount;
        }
        ++successfulCalls;
    }

    // ---- expected to fail -----------------------------------------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - bal);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, bal, bal + excess));
        token.transfer(to, bal + excess);
        ++expectedFailures;
    }

    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return; // infinite allowance cannot be exceeded
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
        token.transferFrom(owner, to, allowed + excess);
        ++expectedFailures;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ++expectedFailures;
    }

    function privilegedCall(uint256 callerSeed, uint256 sigSeed, uint256 targetSeed) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        bytes memory data = abi.encodeWithSignature(privileged[sigSeed % privileged.length], target, type(uint128).max);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged selector exists");
        ++privilegedAttempts;
    }

    /// @dev Sending ether to the token must fail and leave it with none.
    function sendEther(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, 100 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ether");
        ++expectedFailures;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @notice Invariants over random sequences of the handler's calls, including the failing ones.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = true
contract VerdictTokenGhostInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    VerdictToken token;
    VerdictGhostHandler handler;
    address deployer;
    address[] actors;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new VerdictToken();

        actors.push(deployer);
        actors.push(makeAddr("distributor"));
        actors.push(makeAddr("poolManager"));
        actors.push(makeAddr("holder1"));
        actors.push(makeAddr("holder2"));
        actors.push(makeAddr("stranger"));

        handler = new VerdictGhostHandler(token, actors, deployer);
        targetContract(address(handler));
    }

    /// @dev The ledger the handler keeps agrees with the contract for every actor.
    function invariant_balancesMatchGhostLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance drifted from ledger");
        }
    }

    /// @dev Every allowance agrees with the ledger: spends decrement exactly, infinite stays infinite.
    function invariant_allowancesMatchGhostLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance drifted from ledger"
                );
            }
        }
    }

    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_actorBalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY);
    }

    /// @dev No actor ever holds more than the supply (so the library's unchecked add never wrapped).
    function invariant_noBalanceExceedsSupply() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(token.balanceOf(actors[i]), SUPPLY);
        }
    }

    /// @dev What the deployer no longer holds is exactly what it sent or let others pull, net of
    ///      what came back: its balance is never below supply minus everything that ever left it.
    function invariant_deployerBalanceAccountsForOutflows() public view {
        assertGe(token.balanceOf(deployer) + handler.ghostTransferredOut(), SUPPLY);
    }

    /// @dev Nothing leaks to the zero address, the token, the handler or the test.
    function invariant_noStrayBalances() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Metadata is immutable under any sequence.
    function invariant_metadataIsImmutable() public view {
        assertEq(token.name(), "Prediction Markets Run by AI Agents");
        assertEq(token.symbol(), "VERDICT");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev The runtime cannot change: there is no upgrade path and no selfdestruct.
    function invariant_runtimeCodeIsUnchanged() public view {
        assertEq(keccak256(address(token).code), keccak256(type(VerdictToken).runtimeCode));
    }
}
