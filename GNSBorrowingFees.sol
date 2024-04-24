// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IGNSBorrowingFees.sol";
import "../interfaces/IGNSTradingStorage.sol";

import "../libraries/ChainUtils.sol";
import "../libraries/CollateralUtils.sol";
import "../libraries/BorrowingFeesUtils.sol";

/**
 * @custom:version 7
 * @custom:oz-upgrades-unsafe-allow external-library-linking
 */
contract GNSBorrowingFees is Initializable, IGNSBorrowingFees {
    // Constants
    uint256 private constant P_1 = 1e10;

    // Addresses
    IGNSTradingStorage public storageT;
    address public pairInfos; /// @custom:deprecated

    // State
    mapping(uint16 => Group) public groups;
    mapping(uint256 => Pair) public pairs;
    mapping(address => mapping(uint256 => mapping(uint256 => InitialAccFees))) public initialAccFees;
    mapping(uint256 => PairOi) public pairOis;
    mapping(uint256 => uint48) public groupFeeExponents;

    // v6.4.2 Storage
    _OiWindowsStorage private oiWindowsStorage; /// @custom:deprecated

    // v7 Multi-Collat
    CollateralUtils.CollateralConfig public collateralConfig;
    IGNSMultiCollatDiamond public multiCollatDiamond;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IGNSTradingStorage _storageT) external initializer {
        if (address(_storageT) == address(0)) {
            revert WrongParams();
        }

        storageT = _storageT;
    }

    // v2 initializer deprecated
    function initializeV3(IGNSMultiCollatDiamond _multiCollatDiamond) external reinitializer(3) {
        if (address(_multiCollatDiamond) == address(0)) {
            revert WrongParams();
        }

        pairInfos = address(0);

        collateralConfig = CollateralUtils.getCollateralConfig(storageT.dai());
        multiCollatDiamond = _multiCollatDiamond;
    }

    // Modifiers
    modifier onlyManager() {
        if (!multiCollatDiamond.hasRole(msg.sender, IAddressStoreUtils.Role.MANAGER)) {
            revert WrongAccess();
        }
        _;
    }

    modifier onlyCallbacks() {
        if (!multiCollatDiamond.hasRole(msg.sender, IAddressStoreUtils.Role.CALLBACKS)) {
            revert WrongAccess();
        }
        _;
    }

    // Manage pair params
    function setPairParams(uint256 pairIndex, PairParams calldata value) external onlyManager {
        _setPairParams(pairIndex, value);
    }

    function setPairParamsArray(uint256[] calldata indices, PairParams[] calldata values) external onlyManager {
        uint256 len = indices.length;
        if (len != values.length) {
            revert WrongLength();
        }

        for (uint256 i; i < len; ) {
            _setPairParams(indices[i], values[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _setPairParams(uint256 pairIndex, PairParams calldata value) private {
        if (value.feeExponent < 1 || value.feeExponent > 3) {
            revert WrongExponent();
        }

        Pair storage p = pairs[pairIndex];

        uint16 prevGroupIndex = getPairGroupIndex(pairIndex);
        uint256 currentBlock = ChainUtils.getBlockNumber();

        _setPairPendingAccFees(pairIndex, currentBlock);

        if (value.groupIndex != prevGroupIndex) {
            _setGroupPendingAccFees(prevGroupIndex, currentBlock);
            _setGroupPendingAccFees(value.groupIndex, currentBlock);

            (uint256 oiLong, uint256 oiShort) = getPairOpenInterestDai(pairIndex);

            // Only remove OI from old group if old group is not 0
            _setGroupOi(prevGroupIndex, true, false, oiLong);
            _setGroupOi(prevGroupIndex, false, false, oiShort);

            // Add OI to new group if it's not group 0 (even if old group is 0)
            // So when we assign a pair to a group, it takes into account its OI
            // And group 0 OI will always be 0 but it doesn't matter since it's not used
            _setGroupOi(value.groupIndex, true, true, oiLong);
            _setGroupOi(value.groupIndex, false, true, oiShort);

            Group memory newGroup = groups[value.groupIndex];
            Group memory prevGroup = groups[prevGroupIndex];

            p.groups.push(
                PairGroup(
                    value.groupIndex,
                    ChainUtils.getUint48BlockNumber(currentBlock),
                    newGroup.accFeeLong,
                    newGroup.accFeeShort,
                    prevGroup.accFeeLong,
                    prevGroup.accFeeShort,
                    p.accFeeLong,
                    p.accFeeShort,
                    0 // placeholder
                )
            );

            emit PairGroupUpdated(pairIndex, prevGroupIndex, value.groupIndex);
        }

        p.feePerBlock = value.feePerBlock;
        p.feeExponent = value.feeExponent;
        pairOis[pairIndex].max = value.maxOi;

        emit PairParamsUpdated(pairIndex, value.groupIndex, value.feePerBlock, value.feeExponent, value.maxOi);
    }

    // Manage group params
    function setGroupParams(uint16 groupIndex, GroupParams calldata value) external onlyManager {
        _setGroupParams(groupIndex, value);
    }

    function setGroupParamsArray(uint16[] calldata indices, GroupParams[] calldata values) external onlyManager {
        uint256 len = indices.length;
        if (len != values.length) {
            revert WrongLength();
        }

        for (uint256 i; i < len; ) {
            _setGroupParams(indices[i], values[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _setGroupParams(uint16 groupIndex, GroupParams calldata value) private {
        if (groupIndex == 0) {
            revert ZeroGroup();
        }
        if (value.feeExponent < 1 || value.feeExponent > 3) {
            revert WrongExponent();
        }

        _setGroupPendingAccFees(groupIndex, ChainUtils.getBlockNumber());

        Group storage g = groups[groupIndex];
        g.feePerBlock = value.feePerBlock;
        g.maxOi = uint80(value.maxOi);
        groupFeeExponents[groupIndex] = value.feeExponent;

        emit GroupUpdated(groupIndex, value.feePerBlock, value.maxOi, value.feeExponent);
    }

    // Group OI setter
    function _setGroupOi(
        uint16 groupIndex,
        bool long,
        bool increase,
        uint256 amount // 1e18 | 1e6
    ) private {
        Group storage group = groups[groupIndex];
        uint112 amountFinal;

        if (groupIndex > 0) {
            amount = (amount * P_1) / collateralConfig.precision; // 1e10
            if (amount > type(uint112).max) {
                revert Overflow();
            }

            amountFinal = uint112(amount);

            if (long) {
                group.oiLong = increase
                    ? group.oiLong + amountFinal
                    : group.oiLong - (group.oiLong > amountFinal ? amountFinal : group.oiLong);
            } else {
                group.oiShort = increase
                    ? group.oiShort + amountFinal
                    : group.oiShort - (group.oiShort > amountFinal ? amountFinal : group.oiShort);
            }
        }

        emit GroupOiUpdated(groupIndex, long, increase, amountFinal, group.oiLong, group.oiShort);
    }

    // Acc fees getters for pairs and groups
    function getPendingAccFees(
        PendingAccFeesInput memory input
    ) public pure returns (uint64 newAccFeeLong, uint64 newAccFeeShort, uint64 delta) {
        return BorrowingFeesUtils.getPendingAccFees(input);
    }

    function getPairGroupAccFeesDeltas(
        uint256 i,
        PairGroup[] memory pairGroups,
        InitialAccFees memory initialFees,
        uint256 pairIndex,
        bool long,
        uint256 currentBlock
    ) public view returns (uint64 deltaGroup, uint64 deltaPair, bool beforeTradeOpen) {
        PairGroup memory group = pairGroups[i];

        beforeTradeOpen = group.block < initialFees.block;

        if (i == pairGroups.length - 1) {
            // Last active group
            deltaGroup = getGroupPendingAccFee(group.groupIndex, currentBlock, long);
            deltaPair = getPairPendingAccFee(pairIndex, currentBlock, long);
        } else {
            // Previous groups
            PairGroup memory nextGroup = pairGroups[i + 1];

            // If it's not the first group to be before the trade was opened then fee is 0
            if (beforeTradeOpen && nextGroup.block <= initialFees.block) {
                return (0, 0, beforeTradeOpen);
            }

            deltaGroup = long ? nextGroup.prevGroupAccFeeLong : nextGroup.prevGroupAccFeeShort;
            deltaPair = long ? nextGroup.pairAccFeeLong : nextGroup.pairAccFeeShort;
        }

        if (beforeTradeOpen) {
            deltaGroup -= initialFees.accGroupFee;
            deltaPair -= initialFees.accPairFee;
        } else {
            deltaGroup -= (long ? group.initialAccFeeLong : group.initialAccFeeShort);
            deltaPair -= (long ? group.pairAccFeeLong : group.pairAccFeeShort);
        }
    }

    // Pair acc fees helpers
    function getPairPendingAccFees(
        uint256 pairIndex,
        uint256 currentBlock
    ) public view returns (uint64 accFeeLong, uint64 accFeeShort, uint64 pairAccFeeDelta) {
        Pair memory pair = pairs[pairIndex];

        (uint256 pairOiLong, uint256 pairOiShort) = getPairOpenInterestDai(pairIndex);

        (accFeeLong, accFeeShort, pairAccFeeDelta) = getPendingAccFees(
            PendingAccFeesInput(
                pair.accFeeLong,
                pair.accFeeShort,
                pairOiLong,
                pairOiShort,
                pair.feePerBlock,
                currentBlock,
                pair.accLastUpdatedBlock,
                pairOis[pairIndex].max,
                pair.feeExponent,
                collateralConfig.precision
            )
        );
    }

    function getPairPendingAccFee(
        uint256 pairIndex,
        uint256 currentBlock,
        bool long
    ) public view returns (uint64 accFee) {
        (uint64 accFeeLong, uint64 accFeeShort, ) = getPairPendingAccFees(pairIndex, currentBlock);
        return long ? accFeeLong : accFeeShort;
    }

    function _setPairPendingAccFees(
        uint256 pairIndex,
        uint256 currentBlock
    ) private returns (uint64 accFeeLong, uint64 accFeeShort) {
        (accFeeLong, accFeeShort, ) = getPairPendingAccFees(pairIndex, currentBlock);

        Pair storage pair = pairs[pairIndex];

        (pair.accFeeLong, pair.accFeeShort) = (accFeeLong, accFeeShort);
        pair.accLastUpdatedBlock = ChainUtils.getUint48BlockNumber(currentBlock);

        emit PairAccFeesUpdated(pairIndex, currentBlock, pair.accFeeLong, pair.accFeeShort);
    }

    // Group acc fees helpers
    function getGroupPendingAccFees(
        uint16 groupIndex,
        uint256 currentBlock
    ) public view returns (uint64 accFeeLong, uint64 accFeeShort, uint64 groupAccFeeDelta) {
        Group memory group = groups[groupIndex];
        uint128 _collateralPrecision = collateralConfig.precision;

        (accFeeLong, accFeeShort, groupAccFeeDelta) = getPendingAccFees(
            PendingAccFeesInput(
                group.accFeeLong,
                group.accFeeShort,
                (uint256(group.oiLong) * _collateralPrecision) / P_1,
                (uint256(group.oiShort) * _collateralPrecision) / P_1,
                group.feePerBlock,
                currentBlock,
                group.accLastUpdatedBlock,
                uint72(group.maxOi),
                groupFeeExponents[groupIndex],
                _collateralPrecision
            )
        );
    }

    function getGroupPendingAccFee(
        uint16 groupIndex,
        uint256 currentBlock,
        bool long
    ) public view returns (uint64 accFee) {
        (uint64 accFeeLong, uint64 accFeeShort, ) = getGroupPendingAccFees(groupIndex, currentBlock);
        return long ? accFeeLong : accFeeShort;
    }

    function _setGroupPendingAccFees(
        uint16 groupIndex,
        uint256 currentBlock
    ) private returns (uint64 accFeeLong, uint64 accFeeShort) {
        (accFeeLong, accFeeShort, ) = getGroupPendingAccFees(groupIndex, currentBlock);

        Group storage group = groups[groupIndex];

        (group.accFeeLong, group.accFeeShort) = (accFeeLong, accFeeShort);
        group.accLastUpdatedBlock = ChainUtils.getUint48BlockNumber(currentBlock);

        emit GroupAccFeesUpdated(groupIndex, currentBlock, group.accFeeLong, group.accFeeShort);
    }

    // Interaction with callbacks
    function handleTradeAction(
        address trader,
        uint256 pairIndex,
        uint256 index,
        uint256 positionSizeDai, // 1e18 | 1e6 (collateral * leverage)
        bool open,
        bool long
    ) external override onlyCallbacks {
        uint16 groupIndex = getPairGroupIndex(pairIndex);
        uint256 currentBlock = ChainUtils.getBlockNumber();

        (uint64 pairAccFeeLong, uint64 pairAccFeeShort) = _setPairPendingAccFees(pairIndex, currentBlock);
        (uint64 groupAccFeeLong, uint64 groupAccFeeShort) = _setGroupPendingAccFees(groupIndex, currentBlock);

        _setGroupOi(groupIndex, long, open, positionSizeDai);

        if (open) {
            InitialAccFees memory initialFees = InitialAccFees(
                long ? pairAccFeeLong : pairAccFeeShort,
                long ? groupAccFeeLong : groupAccFeeShort,
                ChainUtils.getUint48BlockNumber(currentBlock),
                0 // placeholder
            );

            initialAccFees[trader][pairIndex][index] = initialFees;

            emit TradeInitialAccFeesStored(trader, pairIndex, index, initialFees.accPairFee, initialFees.accGroupFee);
        }

        emit TradeActionHandled(trader, pairIndex, index, open, long, positionSizeDai);
    }

    // Important trade getters
    function getTradeBorrowingFee(BorrowingFeeInput memory input) public view returns (uint256 fee) {
        InitialAccFees memory initialFees = initialAccFees[input.trader][input.pairIndex][input.index];
        PairGroup[] memory pairGroups = pairs[input.pairIndex].groups;

        uint256 currentBlock = ChainUtils.getBlockNumber();

        PairGroup memory firstPairGroup;
        if (pairGroups.length > 0) {
            firstPairGroup = pairGroups[0];
        }

        // If pair has had no group after trade was opened, initialize with pair borrowing fee
        if (pairGroups.length == 0 || firstPairGroup.block > initialFees.block) {
            fee = ((
                pairGroups.length == 0
                    ? getPairPendingAccFee(input.pairIndex, currentBlock, input.long)
                    : (input.long ? firstPairGroup.pairAccFeeLong : firstPairGroup.pairAccFeeShort)
            ) - initialFees.accPairFee);
        }

        // Sum of max(pair fee, group fee) for all groups the pair was in while trade was open
        for (uint256 i = pairGroups.length; i > 0; ) {
            (uint64 deltaGroup, uint64 deltaPair, bool beforeTradeOpen) = getPairGroupAccFeesDeltas(
                i - 1,
                pairGroups,
                initialFees,
                input.pairIndex,
                input.long,
                currentBlock
            );

            fee += (deltaGroup > deltaPair ? deltaGroup : deltaPair);

            // Exit loop at first group before trade was open
            if (beforeTradeOpen) break;
            unchecked {
                --i;
            }
        }

        fee = (input.collateral * input.leverage * fee) / P_1 / 100; // 1e18 | 1e6 (DAI)
    }

    function getTradeLiquidationPrice(LiqPriceInput calldata input) external view returns (uint256) {
        return
            BorrowingFeesUtils.getTradeLiquidationPrice(
                input.openPrice,
                input.long,
                input.collateral,
                input.leverage,
                getTradeBorrowingFee(
                    BorrowingFeeInput(
                        input.trader,
                        input.pairIndex,
                        input.index,
                        input.long,
                        input.collateral,
                        input.leverage
                    )
                ),
                collateralConfig.precisionDelta
            );
    }

    // Public getters
    function getPairOpenInterestDai(uint256 pairIndex) public view returns (uint256, uint256) {
        return (storageT.openInterestDai(pairIndex, 0), storageT.openInterestDai(pairIndex, 1));
    }

    function getPairGroupIndex(uint256 pairIndex) public view returns (uint16 groupIndex) {
        PairGroup[] memory pairGroups = pairs[pairIndex].groups;
        return pairGroups.length == 0 ? 0 : pairGroups[pairGroups.length - 1].groupIndex;
    }

    // External getters
    function withinMaxGroupOi(
        uint256 pairIndex,
        bool long,
        uint256 positionSizeDai // 1e18 | 1e6
    ) external view returns (bool) {
        Group memory g = groups[getPairGroupIndex(pairIndex)];
        return
            (g.maxOi == 0) ||
            ((long ? g.oiLong : g.oiShort) + (positionSizeDai * P_1) / collateralConfig.precision <= g.maxOi);
    }

    function getGroup(uint16 groupIndex) external view returns (Group memory, uint48) {
        return (groups[groupIndex], groupFeeExponents[groupIndex]);
    }

    function getPair(uint256 pairIndex) external view returns (Pair memory, PairOi memory) {
        return (pairs[pairIndex], pairOis[pairIndex]);
    }

    function getAllPairs() external view returns (Pair[] memory, PairOi[] memory) {
        uint256 len = multiCollatDiamond.pairsCount();
        Pair[] memory p = new Pair[](len);
        PairOi[] memory pairOi = new PairOi[](len);

        for (uint256 i; i < len; ) {
            p[i] = pairs[i];
            pairOi[i] = pairOis[i];
            unchecked {
                ++i;
            }
        }

        return (p, pairOi);
    }

    function getGroups(uint16[] calldata indices) external view returns (Group[] memory, uint48[] memory) {
        Group[] memory g = new Group[](indices.length);
        uint48[] memory e = new uint48[](indices.length);
        uint256 len = indices.length;

        for (uint256 i; i < len; ) {
            g[i] = groups[indices[i]];
            e[i] = groupFeeExponents[indices[i]];
            unchecked {
                ++i;
            }
        }

        return (g, e);
    }

    function getPairMaxOi(uint256 pairIndex) external view returns (uint256) {
        return pairOis[pairIndex].max;
    }

    function getCollateralPairMaxOi(uint256 pairIndex) external view returns (uint256) {
        return (uint256(collateralConfig.precision) * pairOis[pairIndex].max) / P_1;
    }
}