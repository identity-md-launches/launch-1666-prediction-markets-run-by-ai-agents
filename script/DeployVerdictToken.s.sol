// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @title Local deployment helper for VerdictToken
/// @notice The production launch is performed by IdentityMD's ProjectFactory from the attested
///         bytecode; nobody runs this script against mainnet. It exists so the token can be deployed
///         to a local Anvil for manual inspection, and so tests can exercise the exact deployment
///         path through `deploy()`.
/// @dev The token takes no constructor arguments, so there is no configuration to read. `run()`
///      deliberately reads no environment variables: the broadcaster is whoever signs the
///      transaction, and that address receives the whole supply.
contract DeployVerdictToken is Script {
    /// @notice Deploys a new VerdictToken. The caller receives the entire supply.
    function deploy() public returns (VerdictToken token) {
        token = new VerdictToken();
    }

    /// @notice Broadcast entry point for local use: `forge script script/DeployVerdictToken.s.sol
    ///         --rpc-url <anvil> --broadcast --private-key <local key>`.
    function run() external returns (VerdictToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
