// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../interfaces/IGNSTradingStorage.sol";
import "../interfaces/IERC721.sol";
import "../interfaces/IERC20.sol";

/**
 * @custom:version 6.3
 */
contract TradingBackend {
    IGNSTradingStorage public immutable storageT;

    constructor(IGNSTradingStorage _storageT) {
        storageT = _storageT;
    }

    function backend(
        address _trader
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256[] memory,
            IGNSTradingStorage.PendingMarketOrder[] memory,
            uint256[][5] memory
        )
    {
        uint256[] memory pendingIds = storageT.getPendingOrderIds(_trader);

        IGNSTradingStorage.PendingMarketOrder[] memory pendingMarket = new IGNSTradingStorage.PendingMarketOrder[](
            pendingIds.length
        );

        for (uint256 i = 0; i < pendingIds.length; ++i) {
            pendingMarket[i] = storageT.reqID_pendingMarketOrder(pendingIds[i]);
        }

        uint256[][5] memory nftIds;

        /*for (uint256 j = 0; j < 5; j++) {
            uint256 nftsCount = IERC721(storageT.nfts(j)).balanceOf(_trader);
            nftIds[j] = new uint256[](nftsCount);

            for (uint256 i = 0; i < nftsCount; ++i) {
                nftIds[j][i] = IERC721(storageT.nfts(j)).tokenOfOwnerByIndex(_trader, i);
            }
        }*/

        return (
            IERC20(storageT.dai()).allowance(_trader, address(storageT)),
            IERC20(storageT.dai()).balanceOf(_trader),
            IERC20(storageT.linkErc677()).allowance(_trader, address(storageT)),
            pendingIds,
            pendingMarket,
            nftIds
        );
    }
}