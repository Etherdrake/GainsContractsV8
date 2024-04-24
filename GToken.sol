// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20Upgradeable, IERC20Upgradeable, IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable, SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../misc/VotingDelegator.sol";

import "../interfaces/IGToken.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IGTokenLockedDepositNft.sol";
import "../interfaces/IGTokenOpenPnlFeed.sol";

import "../libraries/ChainUtils.sol";
import "../libraries/CollateralUtils.sol";

/**
 * @custom:version 8
 * @dev GToken vault contract, direct counterparty to trades happening on gTrade
 */
contract GToken is ERC20Upgradeable, ERC4626Upgradeable, OwnableUpgradeable, VotingDelegator, IGToken {
    using MathUpgradeable for uint256;

    // Contracts & Addresses (constant)
    address public gnsToken;
    IGTokenLockedDepositNft public lockedDepositNft;

    // Contracts & Addresses (adjustable)
    address public manager; // 3-day timelock contract
    address public admin; // bypasses timelock, access to emergency functions

    address public pnlHandler;
    IGTokenOpenPnlFeed public openTradesPnlFeed;
    GnsPriceProvider public gnsPriceProvider;

    // Parameters (constant)
    uint256 constant PRECISION_18 = 1e18;
    uint256 constant PRECISION_10 = 1e10; // 10 decimals (gns/asset oracle)
    uint256 constant MIN_DAILY_ACC_PNL_DELTA = PRECISION_18 / 10; // 0.1, price delta (1e18)
    uint256 constant MAX_SUPPLY_INCREASE_DAILY_P = 50 * PRECISION_18; // 50% / day, when under collat (1e18)
    uint256 constant MAX_LOSSES_BURN_P = 25 * PRECISION_18; // 25% of all losses (1e18)
    uint256 constant MAX_GNS_SUPPLY_MINT_DAILY_P = PRECISION_18 / 20; // 0.05% / day => 18.25% / yr max (1e18)
    uint256 constant MAX_DISCOUNT_P = 10 * PRECISION_18; // 10% (1e18)
    uint256 public MIN_LOCK_DURATION; // min locked asset deposit duration
    uint256 constant MAX_LOCK_DURATION = 365 days; // max locked asset deposit duration
    uint256[] WITHDRAW_EPOCHS_LOCKS; // epochs withdraw locks at over collat thresholds

    // Parameters (adjustable)
    uint256 public maxAccOpenPnlDelta; // PRECISION_18 (max price delta on new epochs from open pnl)
    uint256 public maxDailyAccPnlDelta; // PRECISION_18 (max daily price delta from closed pnl)
    uint256[2] public withdrawLockThresholdsP; // PRECISION_18 (% of over collat, used with WITHDRAW_EPOCHS_LOCKS)
    uint256 public maxSupplyIncreaseDailyP; // PRECISION_18 (% per day, when under collat)
    uint256 public lossesBurnP; // PRECISION_18 (% of all losses)
    uint256 public maxGnsSupplyMintDailyP; // PRECISION_18 (% of gns supply)
    uint256 public maxDiscountP; // PRECISION_18 (%, maximum discount for locked deposits)
    uint256 public maxDiscountThresholdP; // PRECISION_18 (maximum collat %, for locked deposits)

    // Price state
    uint256 public shareToAssetsPrice; // PRECISION_18
    int256 public accPnlPerTokenUsed; // PRECISION_18 (snapshot of accPnlPerToken)
    int256 public accPnlPerToken; // PRECISION_18 (updated in real-time)
    uint256 public accRewardsPerToken; // PRECISION_18

    // Closed Pnl state
    int256 public dailyAccPnlDelta; // PRECISION_18
    uint256 public lastDailyAccPnlDeltaReset; // timestamp

    // Epochs state (withdrawals)
    uint256 public currentEpoch; // global id
    uint256 public currentEpochStart; // timestamp
    uint256 public currentEpochPositiveOpenPnl; // 1e18

    // Deposit / Withdraw state
    uint256 public currentMaxSupply; // collateralConfig.precision
    uint256 public lastMaxSupplyUpdate; // timestamp
    mapping(address => mapping(uint256 => uint256)) public withdrawRequests; // owner => unlock epoch => shares

    // Locked deposits state
    uint256 public lockedDepositsCount; // global id
    mapping(uint256 => LockedDeposit) public lockedDeposits;

    // Deplete / Refill state
    uint256 public assetsToDeplete; // collateralConfig.precision
    uint256 public dailyMintedGns; // 1e18
    uint256 public lastDailyMintedGnsReset; // timestamp

    // Statistics (not used for contract logic)
    uint256 public totalDeposited; // collateralConfig.precision (assets)
    int256 public totalClosedPnl; // collateralConfig.precision (assets)
    uint256 public totalRewards; // collateralConfig.precision (assets)
    int256 public totalLiability; // collateralConfig.precision (assets)
    uint256 public totalLockedDiscounts; // collateralConfig.precision (assets)
    uint256 public totalDiscounts; // collateralConfig.precision (assets)
    uint256 public totalDepleted; // collateralConfig.precision (assets)
    uint256 public totalDepletedGns; // 1e18 (gns)
    uint256 public totalRefilled; // collateralConfig.precision (assets)
    uint256 public totalRefilledGns; // 1e18 (gns)

    /// @custom:deprecated acc values
    uint256 public accBlockWeightedMarketCap;
    uint256 public accBlockWeightedMarketCapLastStored;

    // Multi-Collat support
    CollateralUtils.CollateralConfig public collateralConfig;

    // Initializer function called when this contract is deployed
    function initialize(
        Meta memory _meta,
        ContractAddresses memory _contractAddresses,
        uint256 _MIN_LOCK_DURATION,
        uint256 _maxAccOpenPnlDelta,
        uint256 _maxDailyAccPnlDelta,
        uint256[2] memory _withdrawLockThresholdsP,
        uint256 _maxSupplyIncreaseDailyP,
        uint256 _lossesBurnP,
        uint256 _maxGnsSupplyMintDailyP,
        uint256 _maxDiscountP,
        uint256 _maxDiscountThresholdP
    ) external initializer {
        if (
            !(_contractAddresses.asset != address(0) &&
                _contractAddresses.owner != address(0) &&
                _contractAddresses.manager != address(0) &&
                _contractAddresses.admin != address(0) &&
                _contractAddresses.owner != _contractAddresses.manager &&
                _contractAddresses.manager != _contractAddresses.admin &&
                _contractAddresses.gnsToken != address(0) &&
                _contractAddresses.lockedDepositNft != address(0) &&
                _contractAddresses.pnlHandler != address(0) &&
                _contractAddresses.openTradesPnlFeed != address(0) &&
                _contractAddresses.gnsPriceProvider.addr != address(0) &&
                _contractAddresses.gnsPriceProvider.signature.length > 0 &&
                _maxDailyAccPnlDelta >= MIN_DAILY_ACC_PNL_DELTA &&
                _withdrawLockThresholdsP[1] > _withdrawLockThresholdsP[0] &&
                _maxSupplyIncreaseDailyP <= MAX_SUPPLY_INCREASE_DAILY_P &&
                _lossesBurnP <= MAX_LOSSES_BURN_P &&
                _maxGnsSupplyMintDailyP <= MAX_GNS_SUPPLY_MINT_DAILY_P &&
                _maxDiscountP <= MAX_DISCOUNT_P &&
                _maxDiscountThresholdP >= 100 * PRECISION_18)
        ) {
            revert WrongValues();
        }

        __ERC20_init(_meta.name, _meta.symbol);
        __ERC4626_init(IERC20MetadataUpgradeable(_contractAddresses.asset));
        _transferOwnership(_contractAddresses.owner);

        gnsToken = _contractAddresses.gnsToken;
        lockedDepositNft = IGTokenLockedDepositNft(_contractAddresses.lockedDepositNft);
        manager = _contractAddresses.manager;
        admin = _contractAddresses.admin;
        pnlHandler = _contractAddresses.pnlHandler;
        openTradesPnlFeed = IGTokenOpenPnlFeed(_contractAddresses.openTradesPnlFeed);
        gnsPriceProvider = _contractAddresses.gnsPriceProvider;

        MIN_LOCK_DURATION = _MIN_LOCK_DURATION;

        maxAccOpenPnlDelta = _maxAccOpenPnlDelta;
        maxDailyAccPnlDelta = _maxDailyAccPnlDelta;
        withdrawLockThresholdsP = _withdrawLockThresholdsP;
        maxSupplyIncreaseDailyP = _maxSupplyIncreaseDailyP;
        lossesBurnP = _lossesBurnP;
        maxGnsSupplyMintDailyP = _maxGnsSupplyMintDailyP;
        maxDiscountP = _maxDiscountP;
        maxDiscountThresholdP = _maxDiscountThresholdP;

        shareToAssetsPrice = PRECISION_18;
        currentEpoch = 1;
        currentEpochStart = block.timestamp;
        WITHDRAW_EPOCHS_LOCKS = [3, 2, 1];
    }

    function initializeV3() external reinitializer(3) {
        collateralConfig = CollateralUtils.getCollateralConfig(asset());
    }

    // Modifiers
    modifier onlyManager() {
        _onlyManager();
        _;
    }

    modifier checks(uint256 assetsOrShares) {
        _checks(assetsOrShares);
        _;
    }

    modifier validDiscount(uint256 lockDuration) {
        _validDiscount(lockDuration);
        _;
    }

    // Modifier helpers - saves bytecode size
    function _onlyManager() private view {
        if (_msgSender() != manager) revert OnlyManager();
    }

    function _checks(uint256 assetsOrShares) private view {
        if (shareToAssetsPrice == 0) revert PriceZero();
        if (assetsOrShares == 0) revert ValueZero();
    }

    function _validDiscount(uint256 lockDuration) private view {
        if (maxDiscountP == 0) revert NoActiveDiscount();
        if (lockDuration < MIN_LOCK_DURATION) revert BelowMin();
        if (lockDuration > MAX_LOCK_DURATION) revert AboveMax();
    }

    // Manage addresses
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        if (newOwner == manager || newOwner == admin) revert WrongValue();
        _transferOwnership(newOwner);
    }

    function updateManager(address newValue) external onlyOwner {
        if (newValue == address(0)) revert AddressZero();
        if (newValue == owner() || newValue == admin) revert WrongValue();
        manager = newValue;
        emit ManagerUpdated(newValue);
    }

    function updateAdmin(address newValue) external onlyManager {
        if (newValue == address(0)) revert AddressZero();
        if (newValue == owner() || newValue == manager) revert WrongValue();
        admin = newValue;
        emit AdminUpdated(newValue);
    }

    function updatePnlHandler(address newValue) external onlyOwner {
        if (newValue == address(0)) revert AddressZero();
        pnlHandler = newValue;
        emit PnlHandlerUpdated(newValue);
    }

    function updateGnsPriceProvider(GnsPriceProvider memory newValue) external onlyManager {
        if (newValue.addr == address(0)) revert AddressZero();
        if (newValue.signature.length == 0) revert BytesZero();
        gnsPriceProvider = newValue;
        emit GnsPriceProviderUpdated(newValue);
    }

    function updateOpenTradesPnlFeed(address newValue) external onlyOwner {
        if (newValue == address(0)) revert AddressZero();
        openTradesPnlFeed = IGTokenOpenPnlFeed(newValue);
        emit OpenTradesPnlFeedUpdated(newValue);
    }

    function updateDelegatee(address _delegatee) external onlyManager {
        if (_delegatee == address(0)) revert AddressZero();
        _tryDelegate(asset(), _delegatee);
    }

    // Manage parameters
    function updateMaxAccOpenPnlDelta(uint256 newValue) external onlyOwner {
        maxAccOpenPnlDelta = newValue;
        emit MaxAccOpenPnlDeltaUpdated(newValue);
    }

    function updateMaxDailyAccPnlDelta(uint256 newValue) external onlyManager {
        if (newValue < MIN_DAILY_ACC_PNL_DELTA) revert BelowMin();
        maxDailyAccPnlDelta = newValue;
        emit MaxDailyAccPnlDeltaUpdated(newValue);
    }

    function updateWithdrawLockThresholdsP(uint256[2] memory newValue) external onlyOwner {
        if (newValue[1] <= newValue[0]) revert WrongValues();
        withdrawLockThresholdsP = newValue;
        emit WithdrawLockThresholdsPUpdated(newValue);
    }

    function updateMaxSupplyIncreaseDailyP(uint256 newValue) external onlyManager {
        if (newValue > MAX_SUPPLY_INCREASE_DAILY_P) revert AboveMax();
        maxSupplyIncreaseDailyP = newValue;
        emit MaxSupplyIncreaseDailyPUpdated(newValue);
    }

    function updateLossesBurnP(uint256 newValue) external onlyManager {
        if (newValue > MAX_LOSSES_BURN_P) revert AboveMax();
        lossesBurnP = newValue;
        emit LossesBurnPUpdated(newValue);
    }

    function updateMaxGnsSupplyMintDailyP(uint256 newValue) external onlyManager {
        if (newValue > MAX_GNS_SUPPLY_MINT_DAILY_P) revert AboveMax();
        maxGnsSupplyMintDailyP = newValue;
        emit MaxGnsSupplyMintDailyPUpdated(newValue);
    }

    function updateMaxDiscountP(uint256 newValue) external onlyManager {
        if (newValue > MAX_DISCOUNT_P) revert AboveMax();
        maxDiscountP = newValue;
        emit MaxDiscountPUpdated(newValue);
    }

    function updateMaxDiscountThresholdP(uint256 newValue) external onlyManager {
        if (newValue < 100 * PRECISION_18) revert BelowMin();
        maxDiscountThresholdP = newValue;
        emit MaxDiscountThresholdPUpdated(newValue);
    }

    // View helper functions
    function maxAccPnlPerToken() public view returns (uint256) {
        // PRECISION_18
        return PRECISION_18 + accRewardsPerToken;
    }

    function collateralizationP() public view returns (uint256) {
        // PRECISION_18 (%)
        uint256 _maxAccPnlPerToken = maxAccPnlPerToken();
        return
            ((
                accPnlPerTokenUsed > 0
                    ? (_maxAccPnlPerToken - uint256(accPnlPerTokenUsed))
                    : (_maxAccPnlPerToken + uint256(accPnlPerTokenUsed * (-1)))
            ) *
                100 *
                PRECISION_18) / _maxAccPnlPerToken;
    }

    function gnsTokenToAssetsPrice() public view returns (uint256 price) {
        // PRECISION_10
        (bool success, bytes memory result) = gnsPriceProvider.addr.staticcall(
            abi.encodeWithSelector(bytes4(gnsPriceProvider.signature), asset())
        );

        if (!success) revert GnsPriceCallFailed();

        (price) = abi.decode(result, (uint256));

        if (price == 0) revert GnsTokenPriceZero();
    }

    function withdrawEpochsTimelock() public view returns (uint256) {
        uint256 collatP = collateralizationP();
        uint256 overCollatP = (collatP - MathUpgradeable.min(collatP, 100 * PRECISION_18));

        return
            overCollatP > withdrawLockThresholdsP[1]
                ? WITHDRAW_EPOCHS_LOCKS[2]
                : (overCollatP > withdrawLockThresholdsP[0] ? WITHDRAW_EPOCHS_LOCKS[1] : WITHDRAW_EPOCHS_LOCKS[0]);
    }

    function lockDiscountP(uint256 collatP, uint256 lockDuration) public view returns (uint256) {
        return
            ((
                collatP <= 100 * PRECISION_18
                    ? maxDiscountP
                    : (
                        collatP <= maxDiscountThresholdP
                            ? (maxDiscountP * (maxDiscountThresholdP - collatP)) /
                                (maxDiscountThresholdP - 100 * PRECISION_18)
                            : 0
                    )
            ) * lockDuration) / MAX_LOCK_DURATION;
    }

    function totalSharesBeingWithdrawn(address owner) public view returns (uint256 shares) {
        for (uint256 i = currentEpoch; i <= currentEpoch + WITHDRAW_EPOCHS_LOCKS[0]; ++i) {
            shares += withdrawRequests[owner][i];
        }
    }

    // Public helper functions
    function tryUpdateCurrentMaxSupply() public {
        if (block.timestamp - lastMaxSupplyUpdate >= 24 hours) {
            currentMaxSupply = (totalSupply() * (PRECISION_18 * 100 + maxSupplyIncreaseDailyP)) / (PRECISION_18 * 100);
            lastMaxSupplyUpdate = block.timestamp;

            emit CurrentMaxSupplyUpdated(currentMaxSupply);
        }
    }

    function tryResetDailyAccPnlDelta() public {
        if (block.timestamp - lastDailyAccPnlDeltaReset >= 24 hours) {
            dailyAccPnlDelta = 0;
            lastDailyAccPnlDeltaReset = block.timestamp;

            emit DailyAccPnlDeltaReset();
        }
    }

    function tryNewOpenPnlRequestOrEpoch() public {
        // Fault tolerance so that activity can continue anyway
        (bool success, ) = address(openTradesPnlFeed).call(abi.encodeWithSignature("newOpenPnlRequestOrEpoch()"));
        if (!success) {
            emit OpenTradesPnlFeedCallFailed();
        }
    }

    // Private helper functions
    function updateShareToAssetsPrice() private {
        shareToAssetsPrice = maxAccPnlPerToken() - (accPnlPerTokenUsed > 0 ? uint256(accPnlPerTokenUsed) : uint256(0)); // PRECISION_18
        emit ShareToAssetsPriceUpdated(shareToAssetsPrice);
    }

    function _assetIERC20() private view returns (IERC20Upgradeable) {
        return IERC20Upgradeable(asset());
    }

    // Override ERC-20 functions (prevent sending to address that is withdrawing)
    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, IERC20Upgradeable) returns (bool) {
        address sender = _msgSender();
        if (totalSharesBeingWithdrawn(sender) > balanceOf(sender) - amount) revert PendingWithdrawal();

        _transfer(sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20Upgradeable, IERC20Upgradeable) returns (bool) {
        if (totalSharesBeingWithdrawn(from) > balanceOf(from) - amount) revert PendingWithdrawal();

        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        return true;
    }

    // Override ERC-4626 view functions
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return ERC4626Upgradeable.decimals();
    }

    function _convertToShares(
        uint256 assets,
        MathUpgradeable.Rounding rounding
    ) internal view override returns (uint256 shares) {
        return assets.mulDiv(PRECISION_18, shareToAssetsPrice, rounding);
    }

    function _convertToAssets(
        uint256 shares,
        MathUpgradeable.Rounding rounding
    ) internal view override returns (uint256 assets) {
        // Prevent overflow when called from maxDeposit with maxMint = uint256.max
        if (shares == type(uint256).max && shareToAssetsPrice >= PRECISION_18) {
            return shares;
        }
        return shares.mulDiv(shareToAssetsPrice, PRECISION_18, rounding);
    }

    function maxMint(address) public view override returns (uint256) {
        return
            accPnlPerTokenUsed > 0
                ? currentMaxSupply - MathUpgradeable.min(currentMaxSupply, totalSupply())
                : type(uint256).max;
    }

    function maxDeposit(address owner) public view override returns (uint256) {
        return _convertToAssets(maxMint(owner), MathUpgradeable.Rounding.Down);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return
            openTradesPnlFeed.nextEpochValuesRequestCount() == 0
                ? MathUpgradeable.min(withdrawRequests[owner][currentEpoch], totalSupply() - 1)
                : 0;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssets(maxRedeem(owner), MathUpgradeable.Rounding.Down);
    }

    // Override ERC-4626 interactions (call scaleVariables on every deposit / withdrawal)
    function deposit(uint256 assets, address receiver) public override checks(assets) returns (uint256) {
        if (assets > maxDeposit(receiver)) revert ERC4626ExceededMaxDeposit();

        uint256 shares = previewDeposit(assets);
        scaleVariables(shares, assets, true);

        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override checks(shares) returns (uint256) {
        if (shares > maxMint(receiver)) revert ERC4626ExceededMaxMint();

        uint256 assets = previewMint(shares);
        scaleVariables(shares, assets, true);

        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override checks(assets) returns (uint256) {
        if (assets > maxWithdraw(owner)) revert ERC4626ExceededMaxWithdraw();

        uint256 shares = previewWithdraw(assets);
        withdrawRequests[owner][currentEpoch] -= shares;

        scaleVariables(shares, assets, false);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override checks(shares) returns (uint256) {
        if (shares > maxRedeem(owner)) revert ERC4626ExceededMaxRedeem();

        withdrawRequests[owner][currentEpoch] -= shares;

        uint256 assets = previewRedeem(shares);
        scaleVariables(shares, assets, false);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
    }

    function scaleVariables(uint256 shares, uint256 assets, bool isDeposit) private {
        uint256 supply = totalSupply();

        if (accPnlPerToken < 0) {
            accPnlPerToken =
                (accPnlPerToken * int256(supply)) /
                (isDeposit ? int256(supply + shares) : int256(supply - shares));
        } else if (accPnlPerToken > 0) {
            totalLiability +=
                ((int256(shares) * totalLiability) / int256(supply)) *
                (isDeposit ? int256(1) : int256(-1));
        }

        totalDeposited = isDeposit ? totalDeposited + assets : totalDeposited - assets;
    }

    // Withdraw requests (need to be done before calling 'withdraw' / 'redeem')
    function makeWithdrawRequest(uint256 shares, address owner) external {
        if (openTradesPnlFeed.nextEpochValuesRequestCount() > 0) revert EndOfEpoch();

        address sender = _msgSender();
        uint256 allowance = allowance(owner, sender);

        if (sender != owner && (allowance == 0 || allowance < shares)) revert NotAllowed();

        if (totalSharesBeingWithdrawn(owner) + shares > balanceOf(owner)) revert AboveMax();

        uint256 unlockEpoch = currentEpoch + withdrawEpochsTimelock();
        withdrawRequests[owner][unlockEpoch] += shares;

        emit WithdrawRequested(sender, owner, shares, currentEpoch, unlockEpoch);
    }

    function cancelWithdrawRequest(uint256 shares, address owner, uint256 unlockEpoch) external {
        if (shares > withdrawRequests[owner][unlockEpoch]) revert AboveMax();

        address sender = _msgSender();
        uint256 allowance = allowance(owner, sender);

        if (sender != owner && (allowance == 0 || allowance < shares)) revert NotAllowed();

        withdrawRequests[owner][unlockEpoch] -= shares;

        emit WithdrawCanceled(sender, owner, shares, currentEpoch, unlockEpoch);
    }

    // Locked and discounted deposits
    function depositWithDiscountAndLock(
        uint256 assets,
        uint256 lockDuration,
        address receiver
    ) external checks(assets) validDiscount(lockDuration) returns (uint256) {
        uint256 simulatedAssets = (assets * (PRECISION_18 * 100 + lockDiscountP(collateralizationP(), lockDuration))) /
            (PRECISION_18 * 100);

        if (simulatedAssets > maxDeposit(receiver)) revert AboveMax();

        return
            _executeDiscountAndLock(simulatedAssets, assets, previewDeposit(simulatedAssets), lockDuration, receiver);
    }

    function mintWithDiscountAndLock(
        uint256 shares,
        uint256 lockDuration,
        address receiver
    ) external checks(shares) validDiscount(lockDuration) returns (uint256) {
        if (shares > maxMint(receiver)) revert AboveMax();
        uint256 assets = previewMint(shares);

        return
            _executeDiscountAndLock(
                assets,
                (assets * (PRECISION_18 * 100)) /
                    (PRECISION_18 * 100 + lockDiscountP(collateralizationP(), lockDuration)),
                shares,
                lockDuration,
                receiver
            );
    }

    function _executeDiscountAndLock(
        uint256 assets,
        uint256 assetsDeposited,
        uint256 shares,
        uint256 lockDuration,
        address receiver
    ) private returns (uint256) {
        if (assets <= assetsDeposited) revert NoDiscount();

        uint256 depositId = ++lockedDepositsCount;
        uint256 assetsDiscount = assets - assetsDeposited;

        LockedDeposit storage d = lockedDeposits[depositId];
        d.owner = receiver;
        d.shares = shares;
        d.assetsDeposited = assetsDeposited;
        d.assetsDiscount = assetsDiscount;
        d.atTimestamp = block.timestamp;
        d.lockDuration = lockDuration;

        scaleVariables(shares, assetsDeposited, true);
        address sender = _msgSender();
        _deposit(sender, address(this), assetsDeposited, shares);

        totalDiscounts += assetsDiscount;
        totalLockedDiscounts += assetsDiscount;

        lockedDepositNft.mint(receiver, depositId);

        emit DepositLocked(sender, d.owner, depositId, d);
        return depositId;
    }

    function unlockDeposit(uint256 depositId, address receiver) external {
        LockedDeposit storage d = lockedDeposits[depositId];

        address sender = _msgSender();
        address owner = lockedDepositNft.ownerOf(depositId);

        if (
            owner != sender &&
            lockedDepositNft.getApproved(depositId) != sender &&
            !lockedDepositNft.isApprovedForAll(owner, sender)
        ) revert NotAllowed();

        if (block.timestamp < d.atTimestamp + d.lockDuration) revert NotUnlocked();

        int256 accPnlDelta = int256(
            d.assetsDiscount.mulDiv(
                collateralConfig.precisionDelta * collateralConfig.precision,
                totalSupply(),
                MathUpgradeable.Rounding.Up
            )
        );

        accPnlPerToken += accPnlDelta;

        if (accPnlPerToken > int256(maxAccPnlPerToken())) revert NotEnoughAssets();

        lockedDepositNft.burn(depositId);

        accPnlPerTokenUsed += accPnlDelta;
        updateShareToAssetsPrice();

        totalLiability += int256(d.assetsDiscount);
        totalLockedDiscounts -= d.assetsDiscount;

        _transfer(address(this), receiver, d.shares);

        emit DepositUnlocked(sender, receiver, owner, depositId, d);
    }

    // Distributes a reward evenly to all stakers of the vault
    function distributeReward(uint256 assets) external {
        address sender = _msgSender();
        SafeERC20Upgradeable.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        accRewardsPerToken += (assets * collateralConfig.precisionDelta * collateralConfig.precision) / totalSupply();
        updateShareToAssetsPrice();

        totalRewards += assets;
        totalDeposited += assets;

        emit RewardDistributed(sender, assets);
    }

    // PnL interactions (happens often, so also used to trigger other actions)
    function sendAssets(uint256 assets, address receiver) external {
        address sender = _msgSender();
        if (sender != pnlHandler) revert OnlyTradingPnlHandler();

        int256 accPnlDelta = int256(
            assets.mulDiv(
                collateralConfig.precisionDelta * collateralConfig.precision,
                totalSupply(),
                MathUpgradeable.Rounding.Up
            )
        );

        accPnlPerToken += accPnlDelta;
        if (accPnlPerToken > int256(maxAccPnlPerToken())) revert NotEnoughAssets();

        tryResetDailyAccPnlDelta();
        dailyAccPnlDelta += accPnlDelta;
        if (dailyAccPnlDelta > int256(maxDailyAccPnlDelta)) revert MaxDailyPnl();

        totalLiability += int256(assets);
        totalClosedPnl += int256(assets);

        tryNewOpenPnlRequestOrEpoch();
        tryUpdateCurrentMaxSupply();

        SafeERC20Upgradeable.safeTransfer(_assetIERC20(), receiver, assets);

        emit AssetsSent(sender, receiver, assets);
    }

    function receiveAssets(uint256 assets, address user) external {
        address sender = _msgSender();
        SafeERC20Upgradeable.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        uint256 assetsLessDeplete = assets;

        if (accPnlPerTokenUsed < 0 && accPnlPerToken < 0) {
            uint256 depleteAmount = (assets * lossesBurnP) / PRECISION_18 / 100;
            assetsToDeplete += depleteAmount;
            assetsLessDeplete -= depleteAmount;
        }

        int256 accPnlDelta = int256(
            (assetsLessDeplete * collateralConfig.precisionDelta * collateralConfig.precision) / totalSupply()
        );
        accPnlPerToken -= accPnlDelta;

        tryResetDailyAccPnlDelta();
        dailyAccPnlDelta -= accPnlDelta;

        totalLiability -= int256(assetsLessDeplete);
        totalClosedPnl -= int256(assetsLessDeplete);

        tryNewOpenPnlRequestOrEpoch();
        tryUpdateCurrentMaxSupply();

        emit AssetsReceived(sender, user, assets, assetsLessDeplete);
    }

    // GNS mint / burn mechanism
    function deplete(uint256 assets) external {
        if (assets > assetsToDeplete) revert AboveMax();
        assetsToDeplete -= assets;

        uint256 amountGns = assets.mulDiv(
            collateralConfig.precisionDelta * PRECISION_10,
            gnsTokenToAssetsPrice(),
            MathUpgradeable.Rounding.Up
        );

        address sender = _msgSender();
        IERC20(gnsToken).burn(sender, amountGns);

        totalDepleted += assets;
        totalDepletedGns += amountGns;

        SafeERC20Upgradeable.safeTransfer(_assetIERC20(), sender, assets);

        emit Depleted(sender, assets, amountGns);
    }

    function refill(uint256 assets) external {
        if (accPnlPerTokenUsed <= 0) revert NotUnderCollateralized();

        uint256 supply = totalSupply();
        if (assets > (uint256(accPnlPerTokenUsed) * supply) / PRECISION_18) revert AboveMax();

        if (block.timestamp - lastDailyMintedGnsReset >= 24 hours) {
            dailyMintedGns = 0;
            lastDailyMintedGnsReset = block.timestamp;
        }

        uint256 amountGns = (assets * collateralConfig.precisionDelta * PRECISION_10) / gnsTokenToAssetsPrice();
        dailyMintedGns += amountGns;

        if (dailyMintedGns > (maxGnsSupplyMintDailyP * IERC20Upgradeable(gnsToken).totalSupply()) / PRECISION_18 / 100)
            revert AboveInflationLimit();

        address sender = _msgSender();
        SafeERC20Upgradeable.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        int256 accPnlDelta = int256((assets * PRECISION_18) / supply);
        accPnlPerToken -= accPnlDelta;
        accPnlPerTokenUsed -= accPnlDelta;
        updateShareToAssetsPrice();

        totalRefilled += assets;
        totalRefilledGns += amountGns;

        IERC20(gnsToken).mint(sender, amountGns);

        emit Refilled(sender, assets, amountGns);
    }

    // Updates shareToAssetsPrice based on the new PnL and starts a new epoch
    function updateAccPnlPerTokenUsed(
        uint256 prevPositiveOpenPnl, // 1e18
        uint256 newPositiveOpenPnl // 1e18
    ) external returns (uint256) {
        address sender = _msgSender();
        if (sender != address(openTradesPnlFeed)) revert OnlyPnlFeed();

        int256 delta = int256(newPositiveOpenPnl) - int256(prevPositiveOpenPnl); // 1e18
        uint256 supply = totalSupply();

        int256 maxDelta = int256(
            MathUpgradeable.min(
                (uint256(int256(maxAccPnlPerToken()) - accPnlPerToken) * supply) / collateralConfig.precision,
                (maxAccOpenPnlDelta * supply) / collateralConfig.precision
            )
        ); // PRECISION_18

        delta = delta > maxDelta ? maxDelta : delta;

        accPnlPerToken += (delta * int256(uint256(collateralConfig.precision))) / int256(supply);
        totalLiability += delta / int256(uint256(collateralConfig.precisionDelta));

        accPnlPerTokenUsed = accPnlPerToken;
        updateShareToAssetsPrice();

        currentEpoch++;
        currentEpochStart = block.timestamp;
        currentEpochPositiveOpenPnl = uint256(int256(prevPositiveOpenPnl) + delta);

        tryUpdateCurrentMaxSupply();

        emit AccPnlPerTokenUsedUpdated(
            sender,
            currentEpoch,
            prevPositiveOpenPnl,
            newPositiveOpenPnl,
            currentEpochPositiveOpenPnl,
            accPnlPerTokenUsed
        );

        return currentEpochPositiveOpenPnl;
    }

    // Getters
    function getLockedDeposit(uint256 depositId) external view returns (LockedDeposit memory) {
        return lockedDeposits[depositId];
    }

    function tvl() public view returns (uint256) {
        return (maxAccPnlPerToken() * totalSupply()) / PRECISION_18; // collateralConfig.precision
    }

    function availableAssets() public view returns (uint256) {
        return (uint256(int256(maxAccPnlPerToken()) - accPnlPerTokenUsed) * totalSupply()) / PRECISION_18; // collateralConfig.precision
    }

    function marketCap() public view returns (uint256) {
        return (totalSupply() * shareToAssetsPrice) / PRECISION_18; // collateralConfig.precision
    }
}