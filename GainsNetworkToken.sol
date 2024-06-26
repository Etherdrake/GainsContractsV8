// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC20, ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract GainsNetworkToken is ERC20Capped, AccessControlEnumerable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    bool public initialized = false;

    constructor(address admin) ERC20Capped(100_000_000e18) ERC20("Gains Network", "GNS") {
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setupRoles(
        address tradingStorage,
        address oracleRewards,
        address diamond,
        address trading,
        address callbacks,
        address vault,
        address compensationHandler
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            tradingStorage != address(0) &&
                oracleRewards != address(0) &&
                diamond != address(0) &&
                trading != address(0) &&
                callbacks != address(0) &&
                vault != address(0) &&
                compensationHandler != address(0),
            "WRONG_ADDRESSES"
        );

        require(initialized == false, "INITIALIZED");
        initialized = true;

        _setupRole(MINTER_ROLE, tradingStorage);
        _setupRole(BURNER_ROLE, tradingStorage);

        _setupRole(MINTER_ROLE, oracleRewards);
        _setupRole(MINTER_ROLE, diamond);
        _setupRole(MINTER_ROLE, trading);
        _setupRole(MINTER_ROLE, callbacks);
        _setupRole(MINTER_ROLE, compensationHandler);

        _setupRole(MINTER_ROLE, vault);
        _setupRole(BURNER_ROLE, vault);
    }

    // Mint tokens (called by our ecosystem contracts)
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // Burn tokens (called by our ecosystem contracts)
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
}