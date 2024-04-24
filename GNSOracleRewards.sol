// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IGNSOracleRewards.sol";
import "../interfaces/IGNSTradingStorage.sol";
import "../interfaces/IChainlinkOracle.sol";
import "../interfaces/IERC20.sol";

import "../libraries/ChainUtils.sol";

/**
 * @custom:version 7
 */
contract GNSOracleRewards is Initializable, IGNSOracleRewards {
    using SafeERC20 for IERC20;

    // Constants
    uint256 private constant MIN_TRIGGER_TIMEOUT = 1;

    // Addresses (constant)
    IGNSTradingStorage public storageT;
    mapping(uint256 => address) public nftRewardsOldByChainId; /// @custom:deprecated

    // Params (adjustable)
    uint256 public triggerTimeout; // blocks
    address[] public oracles; // oracles rewarded

    // State
    mapping(address => uint256) public pendingRewardsGns;
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(IGNSTradingStorage.LimitOrder => uint256))))
        public triggeredLimits;
    mapping(address => mapping(uint256 => mapping(uint256 => OpenLimitOrderType))) public openLimitOrderTypes;

    bool public stateCopied; /// @custom:deprecated

    // v7
    IGNSMultiCollatDiamond public multiCollatDiamond;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IGNSTradingStorage _storageT,
        uint256 _triggerTimeout,
        uint256 _oraclesCount
    ) external initializer {
        require(
            address(_storageT) != address(0) && _triggerTimeout >= MIN_TRIGGER_TIMEOUT && _oraclesCount > 0,
            "WRONG_PARAMS"
        );

        storageT = _storageT;
        triggerTimeout = _triggerTimeout;

        _updateOracles(_oraclesCount);
    }

    function initializeV2(IGNSMultiCollatDiamond _multiCollatDiamond) external reinitializer(2) {
        require(address(_multiCollatDiamond) != address(0), "WRONG_PARAMS");

        multiCollatDiamond = _multiCollatDiamond;
    }

    // Modifiers
    modifier onlyGov() {
        require(multiCollatDiamond.hasRole(msg.sender, IAddressStoreUtils.Role.GOV), "GOV_ONLY");
        _;
    }
    modifier onlyTrading() {
        require(multiCollatDiamond.hasRole(msg.sender, IAddressStoreUtils.Role.TRADING), "TRADING_ONLY");
        _;
    }
    modifier onlyCallbacks() {
        require(multiCollatDiamond.hasRole(msg.sender, IAddressStoreUtils.Role.CALLBACKS), "CALLBACKS_ONLY");
        _;
    }

    // Manage params
    function updateTriggerTimeout(uint256 _triggerTimeout) external onlyGov {
        require(_triggerTimeout >= MIN_TRIGGER_TIMEOUT, "BELOW_MIN");

        triggerTimeout = _triggerTimeout;

        emit TriggerTimeoutUpdated(_triggerTimeout);
    }

    function _updateOracles(uint256 _oraclesCount) private {
        require(_oraclesCount > 0, "VALUE_ZERO");

        delete oracles;

        IGNSPriceAggregator aggregator = storageT.priceAggregator();

        for (uint256 i; i < _oraclesCount; ) {
            oracles.push(aggregator.nodes(i));

            unchecked {
                ++i;
            }
        }

        emit OraclesUpdated(_oraclesCount);
    }

    function updateOracles(uint256 _oraclesCount) external onlyGov {
        _updateOracles(_oraclesCount);
    }

    // Triggers
    function storeTrigger(TriggeredLimitId calldata _id) external onlyTrading {
        triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order] = ChainUtils.getBlockNumber();

        emit TriggeredFirst(_id);
    }

    function unregisterTrigger(TriggeredLimitId calldata _id) external onlyCallbacks {
        delete triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];

        emit TriggerUnregistered(_id);
    }

    // Distribute oracle rewards
    function distributeOracleReward(TriggeredLimitId calldata _id, uint256 _reward) external onlyCallbacks {
        require(triggered(_id), "NOT_TRIGGERED");

        uint256 oraclesCount = oracles.length;
        uint256 rewardPerOracle = _reward / oraclesCount;

        for (uint256 i; i < oraclesCount; ) {
            pendingRewardsGns[oracles[i]] += rewardPerOracle;

            unchecked {
                ++i;
            }
        }

        IERC20(storageT.token()).mint(address(this), _reward);

        emit TriggerRewarded(_id, _reward, rewardPerOracle, oraclesCount);
    }

    // Claim oracle rewards
    function claimRewards(address _oracle) external {
        IChainlinkOracle _o = IChainlinkOracle(_oracle);

        // msg.sender must either be the oracle owner or an authorized fulfiller
        require(_o.owner() == msg.sender || _o.getAuthorizationStatus(msg.sender), "NOT_AUTHORIZED");

        uint256 amountGns = pendingRewardsGns[_oracle];

        pendingRewardsGns[_oracle] = 0;
        IERC20(storageT.token()).safeTransfer(msg.sender, amountGns);

        emit RewardsClaimed(_oracle, amountGns);
    }

    // Manage open limit order types
    function setOpenLimitOrderType(
        address _trader,
        uint256 _pairIndex,
        uint256 _index,
        OpenLimitOrderType _type
    ) external onlyTrading {
        openLimitOrderTypes[_trader][_pairIndex][_index] = _type;

        emit OpenLimitOrderTypeSet(_trader, _pairIndex, _index, _type);
    }

    // Getters
    function triggered(TriggeredLimitId calldata _id) public view returns (bool) {
        return triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order] > 0;
    }

    function timedOut(TriggeredLimitId calldata _id) external view returns (bool) {
        uint256 triggerBlock = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];

        return triggerBlock > 0 && ChainUtils.getBlockNumber() - triggerBlock >= triggerTimeout;
    }

    function getOracles() external view returns (address[] memory) {
        return oracles;
    }
}