// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VerdictToken} from "../src/VerdictToken.sol";
import {DeployVerdictToken} from "../script/DeployVerdictToken.s.sol";

/// @notice Behavioural tests for VerdictToken: metadata, the one-time mint, ERC-20 transfers and
///         allowances (success and failure), the absence of any privileged surface, and the
///         bytecode properties the launch floor checks.
contract VerdictTokenTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18

    /// @dev Stands in for the factory: a contract that deploys the token and so receives the supply.
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    VerdictToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed deployer, uint256 amount);

    function setUp() public {
        vm.prank(deployer);
        token = new VerdictToken();
    }

    // ------------------------------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Prediction Markets Run by AI Agents");
        assertEq(token.symbol(), "VERDICT");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), token.name());
        assertEq(token.TOKEN_SYMBOL(), token.symbol());
        assertEq(uint256(token.TOKEN_DECIMALS()), uint256(token.decimals()));
    }

    function test_constantsAgreeWithEachOther() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), token.SUPPLY_WHOLE_TOKENS() * 10 ** token.TOKEN_DECIMALS());
    }

    function test_wholeSupplyMintedToDeployerOnce() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "total supply");
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, "deployer holds everything");
        assertEq(token.balanceOf(address(this)), 0, "the test contract received nothing");
        assertEq(token.balanceOf(address(token)), 0, "the token holds none of itself");
    }

    function test_constructorEmitsTransferFromZeroAndSupplyMinted() public {
        address other = makeAddr("otherDeployer");
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), other, EXPECTED_SUPPLY);
        vm.expectEmit(true, false, false, true);
        emit SupplyMinted(other, EXPECTED_SUPPLY);
        vm.prank(other);
        new VerdictToken();
    }

    /// @dev The supply goes to whoever deploys, not to a hard-coded address: the launch factory
    ///      deploys it and must receive it.
    function testFuzz_supplyGoesToWhoeverDeploys(address who) public {
        vm.assume(who != address(0));
        vm.assume(who.code.length == 0);
        vm.prank(who);
        VerdictToken fresh = new VerdictToken();
        assertEq(fresh.balanceOf(who), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev A contract deployer (as the factory is) receives the supply exactly like an EOA.
    function test_contractDeployerReceivesSupply() public {
        DeployVerdictToken deployScript = new DeployVerdictToken();
        VerdictToken fresh = deployScript.deploy();
        assertEq(fresh.balanceOf(address(deployScript)), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // Transfers: success
    // ------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234_567 ether;
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "transfers never change supply");
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice); // alice holds nothing
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfIsANoOp() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_chainedTransfersArriveWholeAndConserveSupply() public {
        uint256 amount = 100_000_000 ether; // the 10% swarm-sized flow
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(carol, amount / 2);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount / 2);
        assertEq(token.balanceOf(carol), amount / 2);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol),
            EXPECTED_SUPPLY
        );
    }

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // Transfers: failure
    // ------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 excess) public {
        excess = bound(excess, 1, type(uint256).max - EXPECTED_SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + excess
            )
        );
        token.transfer(alice, EXPECTED_SUPPLY + excess);
    }

    // ------------------------------------------------------------------------------------------
    // Allowances and transferFrom
    // ------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit Approval(deployer, alice, 42 ether);
        assertTrue(token.approve(alice, 42 ether));
        assertEq(token.allowance(deployer, alice), 42 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 42 ether);
        token.approve(alice, 7 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 7 ether);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 100 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(deployer, bob, 60 ether);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, alice), 40 ether);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrement() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1 ether, 1 ether + 1)
        );
        token.transferFrom(deployer, bob, 1 ether + 1);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooLow() public {
        // alice approves more than she holds; the spender hits the balance check, not the allowance.
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        token.transferFrom(alice, carol, 6 ether);
    }

    function testFuzz_transferFromNeverExceedsAllowance(uint256 allowed, uint256 spend) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (spend > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, spend)
            );
            token.transferFrom(deployer, bob, spend);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spend));
            assertEq(token.balanceOf(bob), spend);
            assertEq(token.allowance(deployer, alice), allowed - spend);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // No privileged surface
    // ------------------------------------------------------------------------------------------

    /// @dev The common admin entry points a launch floor probes. None exists here: each call must
    ///      revert (no fallback, unknown selector) and nothing may change for anyone.
    function test_noAdminFunctionExistsOrChangesState() public {
        vm.prank(deployer);
        token.transfer(alice, 1000 ether);
        uint256 aliceBefore = token.balanceOf(alice);

        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        address[2] memory callers = [deployer, address(0xBEEF)];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, string.concat("unexpected function exists: ", signatures[i]));
            }
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply unchanged");
        assertEq(token.balanceOf(alice), aliceBefore, "holder balance unchanged");
        assertEq(token.balanceOf(address(0xBEEF)), 0, "attacker received nothing");

        // The holder can still move funds afterwards.
        vm.prank(alice);
        assertTrue(token.transfer(bob, aliceBefore));
        assertEq(token.balanceOf(bob), aliceBefore);
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------------------------------
    // Bytecode properties the launch relies on
    // ------------------------------------------------------------------------------------------

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F); // skip PUSH data
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    /// @dev `bytecode_hash = "none"` and `cbor_metadata = false`: the runtime must not end in a
    ///      CBOR metadata trailer, so the launch can reproduce the deployed bytes exactly.
    function test_runtimeHasNoMetadataTrailer() public view {
        bytes memory runtime = address(token).code;
        uint256 n = runtime.length;
        // With CBOR metadata the last two bytes encode the trailer length (typically 0x0033/0x0035
        // for ipfs or 0x0014 for none+solc). Without metadata the last byte is the final opcode of the
        // code, so we check that the declared "length" does not point to a valid CBOR map header.
        uint16 declared = (uint16(uint8(runtime[n - 2])) << 8) | uint16(uint8(runtime[n - 1]));
        bool looksLikeTrailer = declared > 0 && declared + 2 <= n && (uint8(runtime[n - 2 - declared]) & 0xE0) == 0xA0;
        assertFalse(looksLikeTrailer, "runtime ends in a CBOR metadata trailer");
    }

    function test_creationCodeIsDeterministic() public pure {
        bytes memory a = type(VerdictToken).creationCode;
        bytes memory b = type(VerdictToken).creationCode;
        assertEq(keccak256(a), keccak256(b));
        assertGt(a.length, 0);
    }

    function test_implementsIERC20() public view {
        IERC20 erc20 = IERC20(address(token));
        assertEq(erc20.totalSupply(), EXPECTED_SUPPLY);
        assertEq(erc20.balanceOf(deployer), EXPECTED_SUPPLY);
    }
}
