// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable, Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IGNSStaking.sol";
import "../interfaces/IERC20.sol";

import "../libraries/CollateralUtils.sol";

import "../misc/VotingDelegator.sol";

/**
 * @custom:version 7
 */
contract GNSStaking is Initializable, Ownable2StepUpgradeable, IGNSStaking, VotingDelegator {
    using SafeERC20 for IERC20;

    uint48 private constant MAX_UNLOCK_DURATION = 730 days; // 2 years in seconds
    uint128 private constant MIN_UNLOCK_GNS_AMOUNT = 1e18;

    IERC20 public gns;
    IERC20 public dai;

    uint128 public accDaiPerToken; // deprecated (old rewards)
    uint128 public gnsBalance;

    mapping(address => Staker) public stakers; // stakers.debtDai is deprecated (old dai rewards)
    mapping(address => UnlockSchedule[]) private unlockSchedules; // unlockSchedules.debtDai is deprecated (old dai rewards)
    mapping(address => bool) public unlockManagers; // addresses allowed to create vests for others

    address[] public rewardTokens;
    mapping(address => RewardState) public rewardTokenState;

    mapping(address => mapping(address => RewardInfo)) public userTokenRewards; // user => token => info
    mapping(address => mapping(address => mapping(uint256 => RewardInfo))) public userTokenUnlockRewards; // user => token => unlock ID => info

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Sets `owner` and initializes `dai` and `gns` state variables
     */
    function initialize(address _owner, IERC20 _gns, IERC20 _dai) external initializer {
        require(
            address(_owner) != address(0) && address(_gns) != address(0) && address(_dai) != address(0),
            "WRONG_PARAMS"
        );

        _transferOwnership(_owner);
        gns = _gns;
        dai = _dai;
    }

    /**
     * @dev Add `dai` as a reward token (old stakers.debtDai, unlockSchedules.debtDai and accDaiPerToken are deprecacted now)
     * Necessary to call right after contract is updated because otherwise distributeRewardDai() reverts.
     */
    function initializeV2() external reinitializer(2) {
        _addRewardToken(address(dai));
    }

    /**
     * @dev Modifier used for vest creation access control.
     * Users can create non-revocable vests for themselves only, `owner` and `unlockManagers` can create both types for anyone.
     */
    modifier onlyAuthorizedUnlockManager(address _staker, bool _revocable) {
        require(
            (_staker == msg.sender && !_revocable) || msg.sender == owner() || unlockManagers[msg.sender],
            "NO_AUTH"
        );
        _;
    }

    /**
     * @dev Modifier to reject any `_token` not configured as a reward token
     */
    modifier onlyRewardToken(address _token) {
        require(isRewardToken(_token), "INVALID_TOKEN");
        _;
    }

    /**
     * @dev Sets whether `_manager` is `_authorized` to create vests for other users.
     *
     * Emits {UnlockManagerUpdated}
     */
    function setUnlockManager(address _manager, bool _authorized) external onlyOwner {
        unlockManagers[_manager] = _authorized;

        emit UnlockManagerUpdated(_manager, _authorized);
    }

    /**
     * @dev Adds `_token` as a reward token, configures its precision delta.
     *
     * precisionDelta = 10^(18-decimals), eg. USDC 6 decimals => precisionDelta = 1e12
     * It is used to scale up from token amounts to 1e18 normalized accRewardPerGns/debtToken
     * and to scale down from accRewardPerGns/debtToken back to 'real' pending token amounts.
     *
     * Emits {RewardTokenAdded}
     */
    function _addRewardToken(address _token) private {
        require(_token != address(0), "ZERO_ADDRESS");
        require(!isRewardToken(_token), "DUPLICATE");

        rewardTokens.push(_token);

        uint128 precisionDelta = CollateralUtils.getCollateralConfig(_token).precisionDelta;
        rewardTokenState[_token].precisionDelta = precisionDelta;

        emit RewardTokenAdded(_token, rewardTokens.length - 1, precisionDelta);
    }

    /**
     * @dev Forwards call to {_addRewardToken}. Only callable by `owner`.
     */
    function addRewardToken(address _token) external onlyOwner {
        _addRewardToken(_token);
    }

    /**
     * @dev Attempts to set the delegatee of `_token` to `_delegatee`. `_token` must be a valid reward token.
     */
    function setDelegatee(address _token, address _delegatee) external onlyRewardToken(_token) onlyOwner {
        require(_delegatee != address(0), "ADDRESS_0");

        _tryDelegate(_token, _delegatee);
    }

    /**
     * @dev Returns the current debt (1e18 precision) for a token given `_stakedGns` and `_accRewardPerGns`
     */
    function _currentDebtToken(uint128 _stakedGns, uint128 _accRewardPerGns) private pure returns (uint128) {
        return uint128((uint256(_stakedGns) * _accRewardPerGns) / 1e18);
    }

    /**
     * @dev Returns the amount of pending token rewards (precision depends on token) given `_currDebtToken`, `_lastDebtToken` and `_precisionDelta`
     */
    function _pendingTokens(
        uint128 _currDebtToken,
        uint128 _lastDebtToken,
        uint128 _precisionDelta
    ) private pure returns (uint128) {
        return (_currDebtToken - _lastDebtToken) / _precisionDelta;
    }

    /**
     * @dev Returns the amount of pending token rewards (precision depends on token) given `_stakedGns`, `_lastDebtToken` and `_rewardState` for a token
     */
    function _pendingTokens(
        uint128 _stakedGns,
        uint128 _lastDebtToken,
        RewardState memory _rewardState
    ) private pure returns (uint128) {
        return
            _pendingTokens(
                _currentDebtToken(_stakedGns, _rewardState.accRewardPerGns),
                _lastDebtToken,
                _rewardState.precisionDelta
            );
    }

    /**
     * @dev returns pending old dai (1e18 precision) given `_currDebtDai` and `_lastDebtDai`
     * @custom:deprecated to be removed in version after v7
     */
    function _pendingDaiPure(uint128 _currDebtDai, uint128 _lastDebtDai) private pure returns (uint128) {
        return _pendingTokens(_currDebtDai, _lastDebtDai, 1);
    }

    /**
     * @dev returns pending old dai (1e18 precision) given `_stakedGns` amount and `_lastDebtDai`
     * @custom:deprecated to be removed in version after v7
     */
    function _pendingDai(uint128 _stakedGns, uint128 _lastDebtDai) private view returns (uint128) {
        return _pendingDaiPure(_currentDebtToken(_stakedGns, accDaiPerToken), _lastDebtDai);
    }

    /**
     * @dev returns pending old dai (1e18 precision) given `_schedule`
     * @custom:deprecated to be removed in version after v7
     */
    function _pendingDai(UnlockSchedule memory _schedule) private view returns (uint128) {
        return
            _pendingDaiPure(
                _currentDebtToken(_scheduleStakedGns(_schedule.totalGns, _schedule.claimedGns), accDaiPerToken),
                _schedule.debtDai
            );
    }

    /**
     * @dev returns staked gns (1e18 precision) given `_totalGns` and `_claimedGns`
     */
    function _scheduleStakedGns(uint128 _totalGns, uint128 _claimedGns) private pure returns (uint128) {
        return _totalGns - _claimedGns;
    }

    /**
     * @dev Returns the unlocked GNS tokens amount of `_schedule` at `_timestamp`.
     * Includes already claimed GNS tokens.
     */
    function unlockedGns(UnlockSchedule memory _schedule, uint48 _timestamp) public pure returns (uint128) {
        // if vest has ended return totalGns
        if (_timestamp >= _schedule.start + _schedule.duration) return _schedule.totalGns;

        // if unlock hasn't started or it's a cliff unlock return 0
        if (_timestamp < _schedule.start || _schedule.unlockType == UnlockType.CLIFF) return 0;

        return uint128((uint256(_schedule.totalGns) * (_timestamp - _schedule.start)) / _schedule.duration);
    }

    /**
     * @dev Returns the releasable GNS tokens amount (1e18 precision) of `_schedule` at `_timestamp`.
     * Doesn't include already claimed GNS tokens.
     */
    function releasableGns(UnlockSchedule memory _schedule, uint48 _timestamp) public pure returns (uint128) {
        return unlockedGns(_schedule, _timestamp) - _schedule.claimedGns;
    }

    /**
     * @dev Returns the owner of the contract.
     */
    function owner() public view override(IGNSStaking, OwnableUpgradeable) returns (address) {
        return super.owner();
    }

    /**
     * @dev Returns whether `_token` is a listed reward token.
     */
    function isRewardToken(address _token) public view returns (bool) {
        return rewardTokenState[_token].precisionDelta > 0;
    }

    /**
     * @dev Harvests `msg.sender`'s `_token` pending rewards for non-vested GNS.
     *
     * Handles updating `stake.debtToken` with new debt given `_stakedGns`.
     * Transfers pending `_token` rewards to `msg.sender`.
     *
     * Emits {RewardHarvested}
     */
    function _harvestToken(address _token, uint128 _stakedGns) private {
        RewardInfo storage userInfo = userTokenRewards[msg.sender][_token];
        RewardState memory rewardState = rewardTokenState[_token];

        uint128 newDebtToken = _currentDebtToken(_stakedGns, rewardState.accRewardPerGns);
        uint128 pendingTokens = _pendingTokens(newDebtToken, userInfo.debtToken, rewardState.precisionDelta);

        userInfo.debtToken = newDebtToken;

        IERC20(_token).safeTransfer(msg.sender, uint256(pendingTokens));

        emit RewardHarvested(msg.sender, _token, pendingTokens);
    }

    /**
     * @dev Harvest pending `_token` rewards of `_staker` for vests `_ids`.
     * `_isOldDai` allows to differentiate between the old dai rewards before v7 and the new ones.
     *
     * Emits {RewardHarvestedFromUnlock}
     */
    function _harvestFromUnlock(address _staker, address _token, uint256[] memory _ids, bool _isOldDai) private {
        require(_staker != address(0), "USER_EMPTY");

        if (_ids.length == 0) return;

        uint128 precisionDelta; // only used when _isOldDai == false
        uint128 accRewardPerGns;

        /// @custom:deprecated to be removed in version after v7 (only keep else part)
        if (_isOldDai) {
            accRewardPerGns = accDaiPerToken;
        } else {
            RewardState memory rewardState = rewardTokenState[_token];
            precisionDelta = rewardState.precisionDelta;
            accRewardPerGns = rewardState.accRewardPerGns;
        }

        uint128 pendingTokens;

        for (uint256 i; i < _ids.length; ) {
            uint256 unlockId = _ids[i];
            UnlockSchedule storage schedule = unlockSchedules[_staker][unlockId];

            uint128 newDebtToken = _currentDebtToken(
                _scheduleStakedGns(schedule.totalGns, schedule.claimedGns),
                accRewardPerGns
            );

            /// @custom:deprecated to be removed in version after v7 (only keep else part)
            if (_isOldDai) {
                pendingTokens += _pendingDaiPure(newDebtToken, schedule.debtDai);
                schedule.debtDai = newDebtToken;
            } else {
                RewardInfo storage unlockInfo = userTokenUnlockRewards[_staker][_token][unlockId];
                pendingTokens += _pendingTokens(newDebtToken, unlockInfo.debtToken, precisionDelta);
                unlockInfo.debtToken = newDebtToken;
            }

            unchecked {
                ++i;
            }
        }

        IERC20(_token).safeTransfer(_staker, uint256(pendingTokens));

        emit RewardHarvestedFromUnlock(_staker, _token, _isOldDai, _ids, pendingTokens);
    }

    /**
     * @dev Harvests the `_staker`'s vests `_ids` pending rewards for '_token'
     */
    function _harvestTokenFromUnlock(address _staker, address _token, uint256[] memory _ids) private {
        _harvestFromUnlock(_staker, _token, _ids, false);
    }

    /**
     * @dev Harvests the `_staker`'s vests `_ids` pending rewards for all supported reward tokens
     */
    function _harvestTokensFromUnlock(address _staker, address[] memory _rewardTokens, uint256[] memory _ids) private {
        for (uint256 i; i < _rewardTokens.length; ) {
            _harvestTokenFromUnlock(_staker, _rewardTokens[i], _ids);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Harvests the `_staker`'s vests `_ids` old dai pending rewards
     */
    function _harvestDaiFromUnlock(address _staker, uint256[] memory _ids) private {
        _harvestFromUnlock(_staker, address(dai), _ids, true);
    }

    /**
     * @dev Loops through all `rewardTokens` and syncs `debtToken`.
     * Used when staking or unstaking gns and only after claiming pending rewards.
     * If called before harvesting, all pending rewards will be lost.
     */
    function _syncRewardTokensDebt(address _staker, uint128 _stakedGns) private {
        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ) {
            address rewardToken = rewardTokens[i];

            userTokenRewards[_staker][rewardToken].debtToken = _currentDebtToken(
                _stakedGns,
                rewardTokenState[rewardToken].accRewardPerGns
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Loops through all `_rewardTokens` and syncs `debtToken`.
     * Used when creating a vest or when claiming unlocked GNS from a vest, after claiming pending rewards.
     * If called before harvesting, all pending rewards will be lost.
     */
    function _syncUnlockRewardTokensDebt(
        address _staker,
        address[] memory _rewardTokens,
        uint256 _unlockId,
        uint128 _stakedGns
    ) private {
        for (uint256 i; i < _rewardTokens.length; ) {
            address rewardToken = _rewardTokens[i];

            userTokenUnlockRewards[_staker][rewardToken][_unlockId].debtToken = _currentDebtToken(
                _stakedGns,
                rewardTokenState[rewardToken].accRewardPerGns
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Harvests old dai and all supported tokens pending rewards for vests `_ids` of `_staker`.
     *
     * Then calculates each vest's releasable `amountGns` given `_timestamp`, increases their 'claimedGns' by this amount,
     * and syncs old `debtDai` and all supported tokens debts.
     *
     * Finally transfers the total claimable GNS of all vests to `_staker`.
     *
     * Emits {GnsClaimed}
     */
    function _claimUnlockedGns(address _staker, uint256[] memory _ids, uint48 _timestamp) private {
        uint128 claimedGns;
        address[] memory rewardTokensArray = rewardTokens;

        _harvestDaiFromUnlock(_staker, _ids);
        _harvestTokensFromUnlock(_staker, rewardTokensArray, _ids);

        for (uint256 i; i < _ids.length; ) {
            uint256 unlockId = _ids[i];
            UnlockSchedule storage schedule = unlockSchedules[_staker][unlockId];

            // get gns amount being claimed for current vest
            uint128 amountGns = releasableGns(schedule, _timestamp);

            // make sure new vest total claimed amount is not more than total gns for vest
            uint128 scheduleNewClaimedGns = schedule.claimedGns + amountGns;
            uint128 scheduleTotalGns = schedule.totalGns;
            assert(scheduleNewClaimedGns <= scheduleTotalGns);

            // update vest claimed gns
            schedule.claimedGns = scheduleNewClaimedGns;

            // sync debts for all tokens
            uint128 newStakedGns = _scheduleStakedGns(scheduleTotalGns, scheduleNewClaimedGns);
            schedule.debtDai = _currentDebtToken(newStakedGns, accDaiPerToken); /// @custom:deprecated to be removed in version after v7
            _syncUnlockRewardTokensDebt(_staker, rewardTokensArray, unlockId, newStakedGns);

            claimedGns += amountGns;

            unchecked {
                ++i;
            }
        }

        gnsBalance -= claimedGns;
        gns.safeTransfer(_staker, uint256(claimedGns));

        emit GnsClaimed(_staker, _ids, claimedGns);
    }

    /**
     * @dev Transfers `_amountToken` of `_token` (valid reward token) from caller to this contract and updates `accRewardPerGns`.
     *
     * @dev Note: `accRewardPerGns` is normalized to 1e18 for all reward tokens (even those with less than 18 decimals)
     *
     * Emits {RewardDistributed}
     */
    function distributeReward(address _token, uint256 _amountToken) external override onlyRewardToken(_token) {
        require(gnsBalance > 0, "NO_GNS_STAKED");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amountToken);

        RewardState storage rewardState = rewardTokenState[_token];
        rewardState.accRewardPerGns += uint128((_amountToken * rewardState.precisionDelta * 1e18) / gnsBalance);

        emit RewardDistributed(_token, _amountToken);
    }

    /**
     * @dev Harvests the caller's regular pending `_token` rewards. `_token` must be a valid reward token.
     */
    function harvestToken(address _token) public onlyRewardToken(_token) {
        _harvestToken(_token, stakers[msg.sender].stakedGns);
    }

    /**
     * @dev Harvests the caller's pending `_token` rewards for vests `_ids`. `_token` must be a valid reward token.
     */
    function harvestTokenFromUnlock(address _token, uint[] calldata _ids) public onlyRewardToken(_token) {
        _harvestTokenFromUnlock(msg.sender, _token, _ids);
    }

    /**
     * @dev Harvests the caller's regular pending `_token` rewards and pending rewards for vests `_ids`.
     */
    function harvestTokenAll(address _token, uint[] calldata _ids) external {
        harvestToken(_token);
        harvestTokenFromUnlock(_token, _ids);
    }

    /**
     * @dev Harvests the caller's regular pending rewards for all supported reward tokens.
     */
    function harvestTokens() public {
        uint128 stakedGns = stakers[msg.sender].stakedGns;

        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ) {
            _harvestToken(rewardTokens[i], stakedGns);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Harvests the caller's pending rewards of vests `_ids` for all supported reward tokens.
     */
    function harvestTokensFromUnlock(uint[] calldata _ids) public {
        _harvestTokensFromUnlock(msg.sender, rewardTokens, _ids);
    }

    /**
     * @dev Harvests the caller's regular pending rewards and pending rewards of vests `_ids` for all supported reward tokens.
     */
    function harvestTokensAll(uint[] calldata _ids) public {
        harvestTokens();
        harvestTokensFromUnlock(_ids);
    }

    /**
     * @dev Harvests caller's old regular dai rewards.
     * @custom:deprecated to be removed in version after v7
     *
     * Emits {DaiHarvested}
     */
    function harvestDai() public {
        Staker storage staker = stakers[msg.sender];

        uint128 newDebtDai = _currentDebtToken(staker.stakedGns, accDaiPerToken);
        uint128 pendingDai = _pendingDaiPure(newDebtDai, staker.debtDai);

        staker.debtDai = newDebtDai;
        dai.safeTransfer(msg.sender, uint256(pendingDai));

        emit DaiHarvested(msg.sender, pendingDai);
    }

    /**
     * @dev Harvests caller's old dai rewards for vests `_ids`.
     * @custom:deprecated to be removed in version after v7
     */
    function harvestDaiFromUnlock(uint256[] calldata _ids) public {
        _harvestDaiFromUnlock(msg.sender, _ids);
    }

    /**
     * @dev Harvests caller's old regular dai rewards and old dai rewards of vests `_ids`.
     * @custom:deprecated to be removed in version after v7
     */
    function harvestDaiAll(uint256[] calldata _ids) public {
        harvestDai();
        harvestDaiFromUnlock(_ids);
    }

    /**
     * @dev Harvests the caller's regular pending rewards and pending rewards for vests `_ids` for all supported reward tokens (+ old DAI rewards).
     * @custom:deprecated to be removed in version after v7, can just use {harvestTokensAll}
     */
    function harvestAll(uint[] calldata _ids) external {
        harvestTokensAll(_ids);
        harvestDaiAll(_ids);
    }

    /**
     * @dev Stakes non-vested `_amountGns` from caller.
     *
     * Emits {GnsStaked}
     */
    function stakeGns(uint128 _amountGns) external {
        require(_amountGns > 0, "AMOUNT_ZERO");

        gns.safeTransferFrom(msg.sender, address(this), uint256(_amountGns));

        harvestDai();
        harvestTokens();

        Staker storage staker = stakers[msg.sender];
        uint128 newStakedGns = staker.stakedGns + _amountGns;

        staker.stakedGns = newStakedGns;

        /// @custom:deprecated to be removed in version after v7
        staker.debtDai = _currentDebtToken(newStakedGns, accDaiPerToken);

        // Update `.debtToken` for all reward tokens using newStakedGns
        _syncRewardTokensDebt(msg.sender, newStakedGns);

        gnsBalance += _amountGns;

        emit GnsStaked(msg.sender, _amountGns);
    }

    /**
     * @dev Unstakes non-vested `_amountGns` from caller.
     *
     * Emits {GnsUnstaked}
     */
    function unstakeGns(uint128 _amountGns) external {
        require(_amountGns > 0, "AMOUNT_ZERO");

        harvestDai();
        harvestTokens();

        Staker storage staker = stakers[msg.sender];
        uint128 newStakedGns = staker.stakedGns - _amountGns; // reverts if _amountGns > staker.stakedGns (underflow)

        staker.stakedGns = newStakedGns;

        /// @custom:deprecated to be removed in version after v7
        staker.debtDai = _currentDebtToken(newStakedGns, accDaiPerToken);

        // Update `.debtToken` for all reward tokens with current newStakedGns
        _syncRewardTokensDebt(msg.sender, newStakedGns);

        gnsBalance -= _amountGns;
        gns.safeTransfer(msg.sender, uint256(_amountGns));

        emit GnsUnstaked(msg.sender, _amountGns);
    }

    /**
     * @dev Claims caller's unlocked GNS from vests `_ids`.
     */
    function claimUnlockedGns(uint256[] memory _ids) external {
        _claimUnlockedGns(msg.sender, _ids, uint48(block.timestamp));
    }

    /**
     * @dev Creates vest for `_staker` given `_schedule` input parameters.
     * Restricted with onlyAuthorizedUnlockManager access control.
     *
     * Emits {UnlockScheduled}
     */
    function createUnlockSchedule(
        UnlockScheduleInput calldata _schedule,
        address _staker
    ) external override onlyAuthorizedUnlockManager(_staker, _schedule.revocable) {
        uint48 timestamp = uint48(block.timestamp);

        require(_schedule.start < timestamp + MAX_UNLOCK_DURATION, "TOO_FAR_IN_FUTURE");
        require(_schedule.duration > 0 && _schedule.duration <= MAX_UNLOCK_DURATION, "INCORRECT_DURATION");
        require(_schedule.totalGns >= MIN_UNLOCK_GNS_AMOUNT, "INCORRECT_AMOUNT");
        require(_staker != address(0), "ADDRESS_0");

        uint128 totalGns = _schedule.totalGns;

        // Requester has to pay the gns amount
        gns.safeTransferFrom(msg.sender, address(this), uint256(totalGns));

        UnlockSchedule memory schedule = UnlockSchedule({
            totalGns: totalGns,
            claimedGns: 0,
            debtDai: _currentDebtToken(totalGns, accDaiPerToken), /// @custom:deprecated to be removed in version after v7
            start: _schedule.start >= timestamp ? _schedule.start : timestamp, // accept time in the future
            duration: _schedule.duration,
            unlockType: _schedule.unlockType,
            revocable: _schedule.revocable,
            __placeholder: 0
        });

        unlockSchedules[_staker].push(schedule);
        gnsBalance += totalGns;

        uint256 unlockId = unlockSchedules[_staker].length - 1;

        // Set `.debtToken` for all available rewardTokens
        _syncUnlockRewardTokensDebt(_staker, rewardTokens, unlockId, totalGns);

        emit UnlockScheduled(_staker, unlockId, schedule);
    }

    /**
     * @dev Revokes vest `_id` for `_staker`. Sends the unlocked GNS to `_staker` and sends the remaining locked GNS to `owner`.
     * Only callable by `owner`.
     *
     * Emits {UnlockScheduleRevoked}
     */
    function revokeUnlockSchedule(address _staker, uint256 _id) external onlyOwner {
        UnlockSchedule storage schedule = unlockSchedules[_staker][_id];
        require(schedule.revocable, "NOT_REVOCABLE");

        uint256[] memory ids = new uint256[](1);
        ids[0] = _id;

        // claims unlocked gns and harvests pending rewards
        _claimUnlockedGns(_staker, ids, uint48(block.timestamp));

        // store remaining gns staked before resetting schedule
        uint128 lockedAmountGns = _scheduleStakedGns(schedule.totalGns, schedule.claimedGns);

        // resets vest so no more claims or harvests are possible
        schedule.totalGns = schedule.claimedGns;
        schedule.duration = 0;
        schedule.start = 0;
        schedule.debtDai = 0; /// @custom:deprecated to be removed in version after v7

        // reset all other reward tokens `debtToken` to 0 (by passing _stakedGns = 0)
        _syncUnlockRewardTokensDebt(_staker, rewardTokens, _id, 0);

        gnsBalance -= lockedAmountGns;
        gns.safeTransfer(owner(), uint256(lockedAmountGns));

        emit UnlockScheduleRevoked(_staker, _id);
    }

    /**
     * @dev Returns the pending `_token` rewards (precision depends on token) for `_staker`.
     */
    function pendingRewardToken(address _staker, address _token) public view returns (uint128) {
        if (!isRewardToken(_token)) return 0;

        return
            _pendingTokens(
                stakers[_staker].stakedGns,
                userTokenRewards[_staker][_token].debtToken,
                rewardTokenState[_token]
            );
    }

    /**
     * @dev Returns an array of `_staker`'s pending rewards (precision depends on token) for all supported tokens.
     */
    function pendingRewardTokens(address _staker) external view returns (uint128[] memory pendingTokens) {
        uint256 len = rewardTokens.length;
        pendingTokens = new uint128[](len);

        for (uint256 i; i < len; ++i) {
            pendingTokens[i] = pendingRewardToken(_staker, rewardTokens[i]);
        }

        return pendingTokens;
    }

    /**
     * @dev Returns an array of `_staker`'s pending rewards (precision depends on token) from vests `_ids` for all supported tokens.
     */
    function pendingRewardTokensFromUnlocks(
        address _staker,
        uint256[] calldata _ids
    ) external view returns (uint128[] memory pendingTokens) {
        address[] memory rewardTokensArray = rewardTokens;
        pendingTokens = new uint128[](rewardTokensArray.length);

        for (uint256 i; i < _ids.length; ++i) {
            UnlockSchedule storage schedule = unlockSchedules[_staker][_ids[i]];
            uint128 stakedGns = _scheduleStakedGns(schedule.totalGns, schedule.claimedGns);

            for (uint256 j; j < rewardTokensArray.length; ++j) {
                address rewardToken = rewardTokensArray[j];

                pendingTokens[j] += _pendingTokens(
                    stakedGns,
                    userTokenUnlockRewards[_staker][rewardToken][_ids[i]].debtToken,
                    rewardTokenState[rewardToken]
                );
            }
        }
    }

    /**
     * @dev Returns `_staker`'s pending old dai rewards (1e18 precision).
     * @custom:deprecated to be removed in version after v7
     */
    function pendingRewardDai(address _staker) external view returns (uint128) {
        Staker memory staker = stakers[_staker];
        return _pendingDai(staker.stakedGns, staker.debtDai);
    }

    /**
     * @dev Returns `_staker`'s pending old dai rewards (1e18 precision) from vests `_ids`.
     * @custom:deprecated to be removed in version after v7
     */
    function pendingRewardDaiFromUnlocks(
        address _staker,
        uint256[] calldata _ids
    ) external view returns (uint128 pending) {
        for (uint256 i; i < _ids.length; ++i) {
            pending += _pendingDai(unlockSchedules[_staker][_ids[i]]);
        }
    }

    /**
     * @dev Returns `_staker's` total non-vested and vested GNS staked (1e18 precision)
     */
    function totalGnsStaked(address _staker) external view returns (uint128) {
        uint128 totalGns = stakers[_staker].stakedGns;
        UnlockSchedule[] memory stakerUnlocks = unlockSchedules[_staker];

        for (uint256 i; i < stakerUnlocks.length; ++i) {
            UnlockSchedule memory schedule = stakerUnlocks[i];
            totalGns += _scheduleStakedGns(schedule.totalGns, schedule.claimedGns);
        }

        return totalGns;
    }

    /**
     * @dev Returns all `_staker's` vests.
     */
    function getUnlockSchedules(address _staker) external view returns (UnlockSchedule[] memory) {
        return unlockSchedules[_staker];
    }

    /**
     * @dev Returns `_staker's` vest at `_index'`
     */
    function getUnlockSchedules(address _staker, uint256 _index) external view returns (UnlockSchedule memory) {
        return unlockSchedules[_staker][_index];
    }

    /**
     * @dev Returns the address of all supported reward tokens
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }
}