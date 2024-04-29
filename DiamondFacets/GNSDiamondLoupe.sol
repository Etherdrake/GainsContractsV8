// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./GNSAddressStore.sol";

import "../../interfaces/IGNSDiamondLoupe.sol";

import "../../libraries/DiamondUtils.sol";

/**
 * @custom:version 8
 * @author Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
 * @author Gains Network
 * @dev Based on EIP-2535: Diamonds (https://eips.ethereum.org/EIPS/eip-2535)
 * @dev Follows diamond-3 implementation (https://github.com/mudgen/diamond-3-hardhat/)
 * @dev Returns useful information about the diamond and its facets.
 */
abstract contract GNSDiamondLoupe is IGNSDiamondLoupe {
    /// @notice Gets all facets and their selectors.
    /// @return facets_ Facet
    function facets() external view returns (Facet[] memory facets_) {
        IDiamondStorage.DiamondStorage storage s = DiamondUtils._getStorage();
        uint256 numFacets = s.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddress_ = s.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors = s.facetFunctionSelectors[facetAddress_].functionSelectors;
        }
    }

    /// @notice Gets all the function selectors provided by a facet.
    /// @param _facet The facet address.
    /// @return facetFunctionSelectors_ the function selectors.
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_) {
        IDiamondStorage.DiamondStorage storage s = DiamondUtils._getStorage();
        facetFunctionSelectors_ = s.facetFunctionSelectors[_facet].functionSelectors;
    }

    /// @notice Get all the facet addresses used by a diamond.
    /// @return facetAddresses_ the facet addresses
    function facetAddresses() external view returns (address[] memory facetAddresses_) {
        IDiamondStorage.DiamondStorage storage s = DiamondUtils._getStorage();
        facetAddresses_ = s.facetAddresses;
    }

    /// @notice Gets the facet that supports the given selector.
    /// @dev If facet is not found return address(0).
    /// @param _functionSelector The function selector.
    /// @return facetAddress_ The facet address.
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_) {
        IDiamondStorage.DiamondStorage storage s = DiamondUtils._getStorage();
        facetAddress_ = s.selectorToFacetAndPosition[_functionSelector].facetAddress;
    }
}