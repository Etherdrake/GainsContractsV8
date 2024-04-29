// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSDiamond.sol";

import "./abstract/GNSAddressStore.sol";
import "./abstract/GNSDiamondStorage.sol";
import "./abstract/GNSDiamondCut.sol";
import "./abstract/GNSDiamondLoupe.sol";

/**
 * @custom:version 8
 * @dev Diamond that contains all code for the gTrade leverage trading platform
 */
contract GNSMultiCollatDiamond is
    GNSAddressStore, // base: Initializable + global storage, always first
    GNSDiamondStorage, // storage for each facet
    GNSDiamondCut, // diamond management
    GNSDiamondLoupe, // diamond getters
    IGNSDiamond // diamond interface (types only), always last
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
}