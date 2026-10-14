// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Prediction Markets Run by AI Agents (VERDICT)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
///         deployer (`msg.sender`). There is no owner, no minter, no pause, no blacklist, no fee
///         and no burn hook: after construction the contract has no privileged functions at all.
/// @dev The contract name is the launch manifest's Solidity identifier (at most 32 characters);
///      the token's human-readable name and symbol are returned by `name()` and `symbol()`.
///
///      The deployer is whatever address creates the contract. Under the IdentityMD launch that is
///      ProjectFactory, which then distributes the supply (swarm share, pool seed, remainder) itself.
///      Nothing here is allocated, reserved or sent anywhere by the constructor other than that
///      single mint.
contract VerdictToken is ERC20 {
    /// @notice ERC-20 `name()`.
    string public constant TOKEN_NAME = "Prediction Markets Run by AI Agents";

    /// @notice ERC-20 `symbol()`.
    string public constant TOKEN_SYMBOL = "VERDICT";

    /// @notice Decimals; `decimals()` returns the OpenZeppelin default of 18.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice Total supply in whole tokens: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice Total supply in minor units: 1,000,000,000 * 10^18. This is the manifest's
    ///         `token.totalSupply` and can never change.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** TOKEN_DECIMALS;

    /// @notice Emitted once, when the supply is minted to the deployer.
    /// @param deployer The address that created the contract and received the whole supply.
    /// @param amount   The amount minted, always `TOTAL_SUPPLY`.
    event SupplyMinted(address indexed deployer, uint256 amount);

    /// @notice Mints the entire fixed supply to the deployer.
    /// @dev Takes no arguments and makes no external calls, so it deploys on an empty chain.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }
}
