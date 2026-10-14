// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice The subset of ERC-20 the launch floor depends on, declared here rather than inherited from
///         OpenZeppelin so the token is judged against the floor's own view of it.
interface IFloorToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Stands in for ProjectFactory: deploys the token through CREATE2, holds the supply and
///         performs the launch flows (swarm share, pool seed, remainder) itself. Everything a launch
///         does in one transaction is done here in one call, so no test depends on state that a
///         separate top-level call would have lost.
contract FactoryProbe {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    function deploy(bytes memory code, bytes32 salt) public onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    /// @dev Deploy and perform every launch flow in a single call, as `launchCustom` does.
    function launch(
        bytes memory code,
        bytes32 salt,
        uint256 expectedSupply,
        address distributor,
        uint256 swarmAmount,
        address pool,
        uint256 poolAmount,
        address remainderTo
    ) external onlyController returns (address deployed) {
        deployed = deploy(code, salt);
        IFloorToken token = IFloorToken(deployed);
        require(token.totalSupply() == expectedSupply, "manifest supply mismatch");
        require(token.balanceOf(address(this)) == expectedSupply, "supply not minted to the factory");
        require(token.transfer(distributor, swarmAmount), "swarm transfer returned false");
        require(token.transfer(pool, poolAmount), "pool seed returned false");
        uint256 remainder = token.balanceOf(address(this));
        require(token.transfer(remainderTo, remainder), "remainder transfer returned false");
    }

    function move(IFloorToken token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function call(address target, bytes memory data) external onlyController returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}

/// @notice Simulates the launch as the floor performs it and checks that every flow arrives whole,
///         that nothing the factory can call moves or freezes a holder, and that the CREATE2
///         deployment the factory uses is predictable and mints to the factory.
contract VerdictTokenLaunchTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000e18;
    uint256 constant SWARM_BPS = 1000;
    uint256 constant POOL_BPS = 8000;
    uint64 constant LAUNCH_NUMBER = 7;

    address constant DISTRIBUTOR = address(0xD157);
    address constant POOL_MANAGER = address(0x900C);
    address constant REMAINDER_TO = address(0x4E4D);
    address constant CLAIMANT = address(0xC1A1);
    address constant HOLDER = address(0x401D);
    address constant OTHER = address(0x07E5);
    address constant ATTACKER = address(0xBEEF);

    FactoryProbe probe;
    IFloorToken token;

    function setUp() public {
        probe = new FactoryProbe();
    }

    function _creationCode() internal pure returns (bytes memory) {
        return type(VerdictToken).creationCode;
    }

    function _salt() internal pure returns (bytes32) {
        return bytes32(uint256(LAUNCH_NUMBER));
    }

    function _predict(address deployer, bytes32 salt, bytes memory code) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(code))))));
    }

    // ------------------------------------------------------------------------------------------
    // Deployment through CREATE2 from a contract, as the factory does
    // ------------------------------------------------------------------------------------------

    function test_create2DeploymentLandsAtPredictedAddressAndMintsToFactory() public {
        address predicted = _predict(address(probe), _salt(), _creationCode());
        address deployed = probe.deploy(_creationCode(), _salt());
        assertEq(deployed, predicted, "CREATE2 address prediction");
        token = IFloorToken(deployed);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(probe)), EXPECTED_SUPPLY, "factory holds the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the harness received nothing");
        assertEq(uint256(token.decimals()), 18);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()), "supply agrees with decimals");
    }

    /// @dev Redeploying at the same salt must fail: the address is taken and CREATE2 reverts.
    ///      The first token is unaffected.
    function test_create2RedeploymentAtSameSaltFails() public {
        address first = probe.deploy(_creationCode(), _salt());
        vm.expectRevert(bytes("constructor failed"));
        probe.deploy(_creationCode(), _salt());
        assertEq(IFloorToken(first).balanceOf(address(probe)), EXPECTED_SUPPLY);
        assertEq(IFloorToken(first).totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev Two tokens deployed by the same factory at different salts are independent: each mints
    ///      its own full supply and neither sees the other's balances.
    function test_twoDeploymentsAreIndependent() public {
        address a = probe.deploy(_creationCode(), bytes32(uint256(1)));
        address b = probe.deploy(_creationCode(), bytes32(uint256(2)));
        assertTrue(a != b);
        assertEq(IFloorToken(a).totalSupply(), EXPECTED_SUPPLY);
        assertEq(IFloorToken(b).totalSupply(), EXPECTED_SUPPLY);
        probe.move(IFloorToken(a), HOLDER, 1e18);
        assertEq(IFloorToken(a).balanceOf(HOLDER), 1e18);
        assertEq(IFloorToken(b).balanceOf(HOLDER), 0, "balances do not leak across deployments");
        assertEq(IFloorToken(b).balanceOf(address(probe)), EXPECTED_SUPPLY);
    }

    function testFuzz_create2WorksForAnySalt(bytes32 salt) public {
        address predicted = _predict(address(probe), salt, _creationCode());
        address deployed = probe.deploy(_creationCode(), salt);
        assertEq(deployed, predicted);
        assertEq(IFloorToken(deployed).balanceOf(address(probe)), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // The launch flows, in one transaction
    // ------------------------------------------------------------------------------------------

    function test_launchFlowsArriveWholeInOneTransaction() public {
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (EXPECTED_SUPPLY * POOL_BPS) / 10_000;
        address deployed = probe.launch(
            _creationCode(), _salt(), EXPECTED_SUPPLY, DISTRIBUTOR, swarm, POOL_MANAGER, pool, REMAINDER_TO
        );
        token = IFloorToken(deployed);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), pool, "pool seed arrived short");
        assertEq(token.balanceOf(REMAINDER_TO), EXPECTED_SUPPLY - swarm - pool, "remainder arrived short");
        assertEq(token.balanceOf(address(probe)), 0, "the factory kept something back");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "launch flows changed the supply");
    }

    /// @dev Whatever split the manifest picks, the three flows together account for the supply exactly.
    function testFuzz_launchFlowsConserveSupplyForAnySplit(uint256 swarmBps, uint256 poolBps) public {
        swarmBps = bound(swarmBps, 0, 10_000);
        poolBps = bound(poolBps, 0, 10_000 - swarmBps);
        uint256 swarm = (EXPECTED_SUPPLY * swarmBps) / 10_000;
        uint256 pool = (EXPECTED_SUPPLY * poolBps) / 10_000;
        address deployed = probe.launch(
            _creationCode(), _salt(), EXPECTED_SUPPLY, DISTRIBUTOR, swarm, POOL_MANAGER, pool, REMAINDER_TO
        );
        token = IFloorToken(deployed);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(REMAINDER_TO), EXPECTED_SUPPLY - swarm - pool);
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO),
            EXPECTED_SUPPLY
        );
    }

    /// @dev A launch that tries to forward more than the supply fails as a whole: nothing is
    ///      partially distributed because the single call reverts.
    function test_launchRevertsAsAWholeWhenAFlowExceedsTheSupply() public {
        address predicted = _predict(address(probe), _salt(), _creationCode());
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(probe), EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        probe.launch(
            _creationCode(), _salt(), EXPECTED_SUPPLY, DISTRIBUTOR, EXPECTED_SUPPLY + 1, POOL_MANAGER, 0, REMAINDER_TO
        );
        assertEq(predicted.code.length, 0, "the reverted launch left no token behind");
    }

    function test_swarmShareIsClaimableWhole() public {
        token = IFloorToken(probe.deploy(_creationCode(), _salt()));
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(probe.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev Many small claims from the distributor add up exactly to the swarm share; the last
    ///      claimant is not shorted by any rounding or fee.
    function test_manyClaimsDrainTheDistributorExactly() public {
        token = IFloorToken(probe.deploy(_creationCode(), _salt()));
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        probe.move(token, DISTRIBUTOR, swarm);
        uint256 claimants = 37;
        uint256 each = swarm / claimants;
        uint256 last = swarm - each * (claimants - 1);
        for (uint256 i; i < claimants; ++i) {
            address who = address(uint160(0x1000 + i));
            uint256 amount = i == claimants - 1 ? last : each;
            vm.prank(DISTRIBUTOR);
            assertTrue(token.transfer(who, amount));
            assertEq(token.balanceOf(who), amount);
        }
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "something left after the last claim");
        vm.prank(DISTRIBUTOR);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DISTRIBUTOR, 0, 1));
        token.transfer(CLAIMANT, 1);
    }

    /// @dev A pool stand-in pulls tokens through transferFrom the way the PoolManager settles: the
    ///      amount pulled is exactly the amount requested, both ways round.
    function test_poolStyleTransferFromRoundTripIsExact() public {
        token = IFloorToken(probe.deploy(_creationCode(), _salt()));
        probe.move(token, HOLDER, 1000e18);
        vm.prank(HOLDER);
        VerdictToken(address(token)).approve(POOL_MANAGER, 400e18);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transferFrom(HOLDER, POOL_MANAGER, 400e18));
        assertEq(token.balanceOf(POOL_MANAGER), 400e18, "the pool received short");
        assertEq(token.balanceOf(HOLDER), 600e18);
        assertEq(VerdictToken(address(token)).allowance(HOLDER, POOL_MANAGER), 0, "allowance spent exactly");
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(HOLDER, 400e18));
        assertEq(token.balanceOf(HOLDER), 1000e18, "the round trip lost something");
        assertEq(token.balanceOf(POOL_MANAGER), 0);
    }

    // ------------------------------------------------------------------------------------------
    // No privileged hand, exactly as the floor probes it
    // ------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupply() public {
        token = IFloorToken(probe.deploy(_creationCode(), _salt()));
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("stranger reached: ", signatures[i]));
            (ok,) = probe.call(address(token), data);
            assertFalse(ok, string.concat("factory reached: ", signatures[i]));
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        token = IFloorToken(probe.deploy(_creationCode(), _salt()));
        probe.move(token, HOLDER, EXPECTED_SUPPLY / 1000);
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0);
        string[12] memory signatures = [
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
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            (bool ok,) = probe.call(address(token), data);
            assertFalse(ok, string.concat("factory reached: ", signatures[i]));
        }
        // The factory, which deployed the token, cannot pull a single unit without an allowance.
        (bool moved, bytes memory ret) = probe.call(
            address(token), abi.encodeWithSelector(IFloorToken.transferFrom.selector, HOLDER, address(probe), 1)
        );
        assertFalse(moved, "the factory pulled from a holder");
        assertEq(ret, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(probe), 0, 1));
        assertEq(token.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(OTHER), held / 2, "the holder's transfer delivered short");
        assertEq(token.balanceOf(HOLDER), held - held / 2);
    }

    /// @dev Burn, permit and the allowance helpers removed in OpenZeppelin v5 are absent too, so the
    ///      supply cannot shrink through the contract and integrators must use plain approve.
    function test_noBurnPermitOrAllowanceHelpers() public {
        token = IFloorToken(probe.deploy(_creationCode(), _salt()));
        probe.move(token, HOLDER, 10e18);
        string[9] memory signatures = [
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "nonces(address)",
            "DOMAIN_SEPARATOR()",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, 1e18);
            vm.prank(HOLDER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected function exists: ", signatures[i]));
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(HOLDER), 10e18);
    }

    /// @dev The runtime deployed through CREATE2 from a contract is byte-identical to one deployed
    ///      with CREATE from an EOA: no immutables or constructor-dependent code paths differ.
    function test_runtimeIsIdenticalRegardlessOfDeployer() public {
        address viaFactory = probe.deploy(_creationCode(), _salt());
        vm.prank(makeAddr("eoa"));
        VerdictToken viaEoa = new VerdictToken();
        assertEq(keccak256(viaFactory.code), keccak256(address(viaEoa).code));
        assertEq(keccak256(viaFactory.code), keccak256(type(VerdictToken).runtimeCode));
    }
}
