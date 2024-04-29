// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./GNSAddressStore.sol";

import "../../interfaces/IGNSDiamondCut.sol";

import "../../libraries/DiamondUtils.sol";

/**
 * @custom:version 8
 * @author Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
 * @author Gains Network
 * @dev Based on EIP-2535: Diamonds (https://eips.ethereum.org/EIPS/eip-2535)
 * @dev Follows diamond-3 implementation (https://github.com/mudgen/diamond-3-hardhat/)
 * @dev Manages all actions (calls, updates and initializations) related to the diamond and its facets.
 */
abstract contract GNSDiamondCut is GNSAddressStore, IGNSDiamondCut {
    /**
     * @dev Forwards call to the right facet using msg.sig using delegatecall. Reverts if signature is not known.
     */
    fallback() external payable {
        DiamondStorage storage s = DiamondUtils._getStorage();

        // get facet from function selector
        address facet = s.selectorToFacetAndPosition[msg.sig].facetAddress;

        if (facet == address(0)) revert NotFound();

        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /**
     * @dev Allows the contract to receive ether
     */
    receive() external payable {}

    /// @inheritdoc IGNSDiamondCut
    function diamondCut(
        FacetCut[] calldata _faceCut,
        address _init,
        bytes calldata _calldata
    ) external onlyRole(Role.ROLES_MANAGER) {
        _diamondCut(_faceCut, _init, _calldata);
    }

    /**
     * @dev Internal function for diamondCut()
     */
    function _diamondCut(FacetCut[] memory _facetCut, address _init, bytes memory _calldata) internal {
        for (uint256 facetIndex; facetIndex < _facetCut.length; facetIndex++) {
            FacetCutAction action = _facetCut[facetIndex].action;

            if (action == FacetCutAction.ADD) {
                _addFunctions(_facetCut[facetIndex].facetAddress, _facetCut[facetIndex].functionSelectors);
            } else if (action == FacetCutAction.REPLACE) {
                _replaceFunctions(_facetCut[facetIndex].facetAddress, _facetCut[facetIndex].functionSelectors);
            } else if (action == FacetCutAction.REMOVE) {
                _removeFunctions(_facetCut[facetIndex].facetAddress, _facetCut[facetIndex].functionSelectors);
            } else {
                revert InvalidFacetCutAction();
            }
        }

        emit DiamondCut(_facetCut, _init, _calldata);
        _initializeDiamondCut(_init, _calldata);
    }

    /**
     * @dev Adds the facet if it wasn't added yet, and adds its functions to the diamond
     * @param _facetAddress address of the facet contract
     * @param _functionSelectors array of function selectors
     */
    function _addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "LibDiamondCut: No selectors in facet to cut");
        DiamondStorage storage s = DiamondUtils._getStorage();
        require(_facetAddress != address(0), "LibDiamondCut: Add facet can't be address(0)");

        uint96 selectorPosition = uint96(s.facetFunctionSelectors[_facetAddress].functionSelectors.length);

        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            _addFacet(s, _facetAddress);
        }

        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = s.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacetAddress == address(0), "LibDiamondCut: Can't add function that already exists");
            _addFunction(s, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    /**
     * @dev Updates facet contract address for given function selectors
     * @param _facetAddress address of the facet contract
     * @param _functionSelectors array of function selectors
     */
    function _replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "LibDiamondCut: No selectors in facet to cut");
        DiamondStorage storage s = DiamondUtils._getStorage();
        require(_facetAddress != address(0), "LibDiamondCut: Add facet can't be address(0)");

        uint96 selectorPosition = uint96(s.facetFunctionSelectors[_facetAddress].functionSelectors.length);

        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            _addFacet(s, _facetAddress);
        }

        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = s.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacetAddress != _facetAddress, "LibDiamondCut: Can't replace function with same function");

            _removeFunction(s, oldFacetAddress, selector);
            _addFunction(s, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    /**
     * @dev Removes some function selectors of a facet from diamond
     * @param _facetAddress address of the facet contract
     * @param _functionSelectors array of function selectors
     */
    function _removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "LibDiamondCut: No selectors in facet to cut");
        DiamondStorage storage s = DiamondUtils._getStorage();
        // if function does not exist then do nothing and return
        require(_facetAddress == address(0), "LibDiamondCut: Remove facet address must be address(0)");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = s.selectorToFacetAndPosition[selector].facetAddress;
            _removeFunction(s, oldFacetAddress, selector);
        }
    }

    /**
     * @dev Adds a new facet contract address to the diamond
     * @param s diamond storage pointer
     * @param _facetAddress address of the new facet contract
     */
    function _addFacet(DiamondStorage storage s, address _facetAddress) internal {
        _enforceHasContractCode(_facetAddress);
        s.facetFunctionSelectors[_facetAddress].facetAddressPosition = s.facetAddresses.length;
        s.facetAddresses.push(_facetAddress);
    }

    /**
     * @dev Adds a new function to the diamond for a given facet contract
     * @param s diamond storage pointer
     * @param _selector function selector
     * @param _selectorPosition position of the function selector in the facet selectors array
     * @param _facetAddress address of the facet contract
     */
    function _addFunction(
        DiamondStorage storage s,
        bytes4 _selector,
        uint96 _selectorPosition,
        address _facetAddress
    ) internal {
        s.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        s.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        s.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    /**
     * @dev Removes a function from a facet of the diamond
     * @param s diamond storage pointer
     * @param _facetAddress address of the facet contract
     * @param _selector function selector
     */
    function _removeFunction(DiamondStorage storage s, address _facetAddress, bytes4 _selector) internal {
        require(_facetAddress != address(0), "LibDiamondCut: Can't remove function that doesn't exist");
        // an immutable function is a function defined directly in a diamond
        require(_facetAddress != address(this), "LibDiamondCut: Can't remove immutable function");

        // replace selector with last selector, then delete last selector
        uint256 selectorPosition = s.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = s.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;

        // if not the same then replace _selector with lastSelector
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = s.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            s.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            s.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }

        // delete the last selector
        s.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete s.selectorToFacetAndPosition[_selector];

        // if no more selectors for facet address then delete the facet address
        if (lastSelectorPosition == 0) {
            // replace facet address with last facet address and delete last facet address
            uint256 lastFacetAddressPosition = s.facetAddresses.length - 1;
            uint256 facetAddressPosition = s.facetFunctionSelectors[_facetAddress].facetAddressPosition;

            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = s.facetAddresses[lastFacetAddressPosition];
                s.facetAddresses[facetAddressPosition] = lastFacetAddress;
                s.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            s.facetAddresses.pop();
            delete s.facetFunctionSelectors[_facetAddress].facetAddressPosition;
        }
    }

    /**
     * @dev Initializes a facet after updating the diamond using delegatecall
     * @param _init address of the contract to execute _calldata
     * @param _calldata function call (selector and arguments)
     */
    function _initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            return;
        }
        _enforceHasContractCode(_init);

        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                // bubble up error
                /// @solidity memory-safe-assembly
                assembly {
                    let returndata_size := mload(error)
                    revert(add(32, error), returndata_size)
                }
            } else {
                revert InitializationFunctionReverted(_init, _calldata);
            }
        }
    }

    /**
     * @dev Reverts if the given address is not a contract
     * @param _contract address to check
     */
    function _enforceHasContractCode(address _contract) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }

        if (contractSize == 0) revert NotContract();
    }
}