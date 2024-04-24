// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IGNSTradingStorage.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IPausable.sol";

import "../misc/VotingDelegator.sol";

/**
 * @custom:version 7
 */
contract GNSTradingStorage is Initializable, VotingDelegator {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant PRECISION = 1e10;
    bytes32 public constant MINTER_ROLE = 0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6;
    IERC20 public dai; // @note Or any collateral like wETH, USDC, etc. (same for every var name where 'dai' is used)
    IERC20 public linkErc677;

    // Contracts (updatable)
    IGNSPriceAggregator public priceAggregator;
    address public pool; /// @custom:deprecated
    address public trading; /// @custom:deprecated
    address public callbacks;
    IERC20 public token;
    address[5] public nfts; /// @custom:deprecated
    address public vault;

    // Trading variables
    uint256 public maxTradesPerPair;
    uint256 public maxPendingMarketOrders;
    uint256 public nftSuccessTimelock; /// @custom:deprecated (blocks)
    uint256[5] public spreadReductionsP; /// @custom:deprecated (%)

    // Gov & dev addresses (updatable)
    address public gov;
    address public dev; /// @custom:deprecated

    // Gov & dev fees
    uint256 public devFeesToken; /// @custom:deprecated (1e18)
    uint256 public devFeesDai; /// @custom:deprecated (1e18)
    uint256 public govFeesToken; /// @custom:deprecated (1e18)
    uint256 public govFeesDai; /// @custom:deprecated (1e18)

    // Stats
    uint256 public tokensBurned; /// @custom:deprecated (1e18)
    uint256 public tokensMinted; /// @custom:deprecated (1e18)
    uint256 public nftRewards; /// @custom:deprecated (1e18)

    // Enums
    enum LimitOrder {
        TP,
        SL,
        LIQ,
        OPEN
    }

    // Structs
    struct Trade {
        address trader;
        uint256 pairIndex;
        uint256 index;
        uint256 initialPosToken; // 1e18
        uint256 positionSizeDai; // 1e18 | 1e6
        uint256 openPrice; // PRECISION
        bool buy;
        uint256 leverage;
        uint256 tp; // PRECISION
        uint256 sl; // PRECISION
    }
    struct TradeInfo {
        uint256 tokenId; /// @custom:deprecated
        uint256 tokenPriceDai; // PRECISION
        uint256 openInterestDai; // 1e18 | 1e6
        uint256 tpLastUpdated;
        uint256 slLastUpdated;
        bool beingMarketClosed;
    }
    struct OpenLimitOrder {
        address trader;
        uint256 pairIndex;
        uint256 index;
        uint256 positionSize; // 1e18 | 1e6
        uint256 spreadReductionP; /// @custom:deprecated
        bool buy;
        uint256 leverage;
        uint256 tp; // PRECISION (%)
        uint256 sl; // PRECISION (%)
        uint256 minPrice; // PRECISION
        uint256 maxPrice; // PRECISION
        uint256 block;
        uint256 tokenId; /// @custom:deprecated index in supportedTokens
    }
    struct PendingMarketOrder {
        Trade trade;
        uint256 block;
        uint256 wantedPrice; // PRECISION
        uint256 slippageP; // PRECISION (%)
        uint256 spreadReductionP;
        uint256 tokenId; /// @custom:deprecated index in supportedTokens
    }
    struct PendingNftOrder {
        address nftHolder;
        uint256 nftId;
        address trader;
        uint256 pairIndex;
        uint256 index;
        LimitOrder orderType;
    }

    // Supported tokens to open trades with
    address[] public supportedTokens; /// @custom:deprecated

    // Trades mappings
    mapping(address => mapping(uint256 => mapping(uint256 => Trade))) public openTrades;
    mapping(address => mapping(uint256 => mapping(uint256 => TradeInfo))) public openTradesInfo;
    mapping(address => mapping(uint256 => uint256)) public openTradesCount;

    // Limit orders mappings
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public openLimitOrderIds;
    mapping(address => mapping(uint256 => uint256)) public openLimitOrdersCount;
    OpenLimitOrder[] public openLimitOrders;

    // Pending orders mappings
    mapping(uint256 => PendingMarketOrder) public reqID_pendingMarketOrder;
    mapping(uint256 => PendingNftOrder) public reqID_pendingNftOrder;
    mapping(address => uint256[]) public pendingOrderIds;
    mapping(address => mapping(uint256 => uint256)) public pendingMarketOpenCount;
    mapping(address => mapping(uint256 => uint256)) public pendingMarketCloseCount;

    // List of open trades & limit orders
    mapping(uint256 => address[]) public pairTraders;
    mapping(address => mapping(uint256 => uint256)) public pairTradersId;

    // Current and max open interests for each pair
    mapping(uint256 => uint256[3]) public openInterestDai; /// 1e18 | 1e6 [long,short,@custom:deprecated max]

    // Restrictions & Timelocks
    mapping(uint256 => uint256) public nftLastSuccess; /// @custom:deprecated

    // List of allowed contracts => can update storage + mint/burn tokens
    mapping(address => bool) public isTradingContract;

    // Events
    event TradingContractAdded(address a);
    event TradingContractRemoved(address a);
    event AddressUpdated(string name, address a);
    event NumberUpdated(string name, uint256 value);
    event NumberUpdatedPair(string name, uint256 pairIndex, uint256 value);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _dai, IERC20 _linkErc677, IERC20 _token, address _gov) external initializer {
        require(
            address(_dai) != address(0) &&
                address(_linkErc677) != address(0) &&
                address(_token) != address(0) &&
                _gov != address(0),
            "WRONG_PARAMS"
        );

        dai = _dai;
        linkErc677 = _linkErc677;
        token = _token;
        gov = _gov;

        maxTradesPerPair = 3;
        maxPendingMarketOrders = 5;
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == gov);
        _;
    }

    modifier onlyTrading() {
        require(isTradingContract[msg.sender] && token.hasRole(MINTER_ROLE, msg.sender));
        _;
    }

    // Manage addresses
    function setGov(address _gov) external onlyGov {
        require(_gov != address(0));
        gov = _gov;
        emit AddressUpdated("gov", _gov);
    }

    function setDelegatee(address _delegatee) external onlyGov {
        require(_delegatee != address(0), "ADDRESS_0");

        _tryDelegate(address(dai), _delegatee);
    }

    // Trading + callbacks contracts
    function addTradingContract(address _trading) external onlyGov {
        require(token.hasRole(MINTER_ROLE, _trading), "NOT_MINTER");
        require(_trading != address(0));
        isTradingContract[_trading] = true;
        emit TradingContractAdded(_trading);
    }

    function removeTradingContract(address _trading) external onlyGov {
        require(_trading != address(0));
        isTradingContract[_trading] = false;
        emit TradingContractRemoved(_trading);
    }

    function setPriceAggregator(address _aggregator) external onlyGov {
        require(_aggregator != address(0));
        priceAggregator = IGNSPriceAggregator(_aggregator);
        emit AddressUpdated("priceAggregator", _aggregator);
    }

    function setVault(address _vault) external onlyGov {
        require(_vault != address(0));
        vault = _vault;
        emit AddressUpdated("vault", _vault);
    }

    function setCallbacks(address _callbacks) external onlyGov {
        require(_callbacks != address(0));
        callbacks = _callbacks;
        emit AddressUpdated("callbacks", _callbacks);
    }

    // Manage trading variables
    function setMaxTradesPerPair(uint256 _maxTradesPerPair) external onlyGov {
        require(_maxTradesPerPair > 0);
        maxTradesPerPair = _maxTradesPerPair;
        emit NumberUpdated("maxTradesPerPair", _maxTradesPerPair);
    }

    function setMaxPendingMarketOrders(uint256 _maxPendingMarketOrders) external onlyGov {
        require(_maxPendingMarketOrders > 0);
        maxPendingMarketOrders = _maxPendingMarketOrders;
        emit NumberUpdated("maxPendingMarketOrders", _maxPendingMarketOrders);
    }

    // Manage stored trades
    function storeTrade(Trade memory _trade, TradeInfo memory _tradeInfo) external onlyTrading {
        _trade.index = firstEmptyTradeIndex(_trade.trader, _trade.pairIndex);
        openTrades[_trade.trader][_trade.pairIndex][_trade.index] = _trade;

        openTradesCount[_trade.trader][_trade.pairIndex]++;

        if (openTradesCount[_trade.trader][_trade.pairIndex] == 1) {
            pairTradersId[_trade.trader][_trade.pairIndex] = pairTraders[_trade.pairIndex].length;
            pairTraders[_trade.pairIndex].push(_trade.trader);
        }

        _tradeInfo.beingMarketClosed = false;
        openTradesInfo[_trade.trader][_trade.pairIndex][_trade.index] = _tradeInfo;

        updateOpenInterestDai(_trade.pairIndex, _tradeInfo.openInterestDai, true, _trade.buy);
    }

    function unregisterTrade(address trader, uint256 pairIndex, uint256 index) external onlyTrading {
        Trade storage t = openTrades[trader][pairIndex][index];
        TradeInfo storage i = openTradesInfo[trader][pairIndex][index];
        if (t.leverage == 0) {
            return;
        }

        updateOpenInterestDai(pairIndex, i.openInterestDai, false, t.buy);

        if (openTradesCount[trader][pairIndex] == 1) {
            uint256 _pairTradersId = pairTradersId[trader][pairIndex];
            address[] storage p = pairTraders[pairIndex];

            p[_pairTradersId] = p[p.length - 1];
            pairTradersId[p[_pairTradersId]][pairIndex] = _pairTradersId;

            delete pairTradersId[trader][pairIndex];
            p.pop();
        }

        delete openTrades[trader][pairIndex][index];
        delete openTradesInfo[trader][pairIndex][index];

        openTradesCount[trader][pairIndex]--;
    }

    // Manage pending market orders
    function storePendingMarketOrder(PendingMarketOrder memory _order, uint256 _id, bool _open) external onlyTrading {
        pendingOrderIds[_order.trade.trader].push(_id);

        reqID_pendingMarketOrder[_id] = _order;
        reqID_pendingMarketOrder[_id].block = block.number;

        if (_open) {
            pendingMarketOpenCount[_order.trade.trader][_order.trade.pairIndex]++;
        } else {
            pendingMarketCloseCount[_order.trade.trader][_order.trade.pairIndex]++;
            openTradesInfo[_order.trade.trader][_order.trade.pairIndex][_order.trade.index].beingMarketClosed = true;
        }
    }

    function unregisterPendingMarketOrder(uint256 _id, bool _open) external onlyTrading {
        PendingMarketOrder memory _order = reqID_pendingMarketOrder[_id];
        uint256[] storage orderIds = pendingOrderIds[_order.trade.trader];

        for (uint256 i = 0; i < orderIds.length; ++i) {
            if (orderIds[i] == _id) {
                if (_open) {
                    pendingMarketOpenCount[_order.trade.trader][_order.trade.pairIndex]--;
                } else {
                    pendingMarketCloseCount[_order.trade.trader][_order.trade.pairIndex]--;
                    openTradesInfo[_order.trade.trader][_order.trade.pairIndex][_order.trade.index]
                        .beingMarketClosed = false;
                }

                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();

                delete reqID_pendingMarketOrder[_id];
                return;
            }
        }
    }

    // Manage open interest
    function updateOpenInterestDai(uint256 _pairIndex, uint256 _leveragedPosDai, bool _open, bool _long) private {
        uint256 index = _long ? 0 : 1;
        uint256[3] storage o = openInterestDai[_pairIndex];
        o[index] = _open ? o[index] + _leveragedPosDai : o[index] - _leveragedPosDai;
    }

    // Manage open limit orders
    function storeOpenLimitOrder(OpenLimitOrder memory o) external onlyTrading {
        o.index = firstEmptyOpenLimitIndex(o.trader, o.pairIndex);
        o.block = block.number;
        openLimitOrders.push(o);
        openLimitOrderIds[o.trader][o.pairIndex][o.index] = openLimitOrders.length - 1;
        openLimitOrdersCount[o.trader][o.pairIndex]++;
    }

    function updateOpenLimitOrder(OpenLimitOrder calldata _o) external onlyTrading {
        if (!hasOpenLimitOrder(_o.trader, _o.pairIndex, _o.index)) {
            return;
        }
        OpenLimitOrder storage o = openLimitOrders[openLimitOrderIds[_o.trader][_o.pairIndex][_o.index]];
        o.positionSize = _o.positionSize;
        o.buy = _o.buy;
        o.leverage = _o.leverage;
        o.tp = _o.tp;
        o.sl = _o.sl;
        o.minPrice = _o.minPrice;
        o.maxPrice = _o.maxPrice;
        o.block = block.number;
    }

    function unregisterOpenLimitOrder(address _trader, uint256 _pairIndex, uint256 _index) external onlyTrading {
        if (!hasOpenLimitOrder(_trader, _pairIndex, _index)) {
            return;
        }

        // Copy last order to deleted order => update id of this limit order
        uint256 id = openLimitOrderIds[_trader][_pairIndex][_index];
        openLimitOrders[id] = openLimitOrders[openLimitOrders.length - 1];
        openLimitOrderIds[openLimitOrders[id].trader][openLimitOrders[id].pairIndex][openLimitOrders[id].index] = id;

        // Remove
        delete openLimitOrderIds[_trader][_pairIndex][_index];
        openLimitOrders.pop();

        openLimitOrdersCount[_trader][_pairIndex]--;
    }

    // Manage NFT orders
    function storePendingNftOrder(PendingNftOrder memory _nftOrder, uint256 _orderId) external onlyTrading {
        reqID_pendingNftOrder[_orderId] = _nftOrder;
    }

    function unregisterPendingNftOrder(uint256 _order) external onlyTrading {
        delete reqID_pendingNftOrder[_order];
    }

    // Manage open trade
    function updateSl(address _trader, uint256 _pairIndex, uint256 _index, uint256 _newSl) external onlyTrading {
        Trade storage t = openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) {
            return;
        }
        t.sl = _newSl;
        i.slLastUpdated = block.number;
    }

    function updateTp(address _trader, uint256 _pairIndex, uint256 _index, uint256 _newTp) external onlyTrading {
        Trade storage t = openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) {
            return;
        }
        t.tp = _newTp;
        i.tpLastUpdated = block.number;
    }

    function updateTrade(Trade memory _t) external onlyTrading {
        // useful when partial adding/closing
        Trade storage t = openTrades[_t.trader][_t.pairIndex][_t.index];
        if (t.leverage == 0) {
            return;
        }
        t.initialPosToken = _t.initialPosToken;
        t.positionSizeDai = _t.positionSizeDai;
        t.openPrice = _t.openPrice;
        t.leverage = _t.leverage;
    }

    // Manage tokens
    function transferDai(address _from, address _to, uint256 _amount) external onlyTrading {
        if (_from == address(this)) {
            dai.safeTransfer(_to, _amount);
        } else {
            dai.safeTransferFrom(_from, _to, _amount);
        }
    }

    function transferLinkToAggregator(
        address _from,
        uint256 _pairIndex,
        uint256 _leveragedPosDai
    ) external onlyTrading {
        linkErc677.safeTransferFrom(
            _from,
            address(priceAggregator),
            priceAggregator.linkFee(_pairIndex, _leveragedPosDai)
        );
    }

    // View utils functions
    function firstEmptyTradeIndex(address trader, uint256 pairIndex) public view returns (uint256 index) {
        for (uint256 i = 0; i < maxTradesPerPair; ++i) {
            if (openTrades[trader][pairIndex][i].leverage == 0) {
                index = i;
                break;
            }
        }
    }

    function firstEmptyOpenLimitIndex(address trader, uint256 pairIndex) public view returns (uint256 index) {
        for (uint256 i = 0; i < maxTradesPerPair; ++i) {
            if (!hasOpenLimitOrder(trader, pairIndex, i)) {
                index = i;
                break;
            }
        }
    }

    function hasOpenLimitOrder(address trader, uint256 pairIndex, uint256 index) public view returns (bool) {
        if (openLimitOrders.length == 0) {
            return false;
        }
        OpenLimitOrder storage o = openLimitOrders[openLimitOrderIds[trader][pairIndex][index]];
        return o.trader == trader && o.pairIndex == pairIndex && o.index == index;
    }

    // Additional getters
    function pairTradersArray(uint256 _pairIndex) external view returns (address[] memory) {
        return pairTraders[_pairIndex];
    }

    function getPendingOrderIds(address _trader) external view returns (uint256[] memory) {
        return pendingOrderIds[_trader];
    }

    function pendingOrderIdsCount(address _trader) external view returns (uint256) {
        return pendingOrderIds[_trader].length;
    }

    function getOpenLimitOrder(
        address _trader,
        uint256 _pairIndex,
        uint256 _index
    ) external view returns (OpenLimitOrder memory) {
        require(hasOpenLimitOrder(_trader, _pairIndex, _index));
        return openLimitOrders[openLimitOrderIds[_trader][_pairIndex][_index]];
    }

    function getOpenLimitOrders() external view returns (OpenLimitOrder[] memory) {
        return openLimitOrders;
    }
}