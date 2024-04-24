// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IGNSPriceAggregator.sol";
import "../interfaces/IGNSMultiCollatDiamond.sol";
import "../interfaces/IChainlinkFeed.sol";
import "../interfaces/IGNSTradingStorage.sol";
import "../interfaces/IERC20.sol";

import "../libraries/PackingUtils.sol";

import "../misc/ChainlinkClient.sol";
import "../misc/TWAPPriceGetter.sol";

/**
 * @custom:version 7
 * @custom:oz-upgrades-unsafe-allow external-library-linking
 */
contract GNSPriceAggregator is Initializable, ChainlinkClient, IGNSPriceAggregator, TWAPPriceGetter {
    using Chainlink for Chainlink.Request;
    using PackingUtils for uint256;
    using SafeERC20 for IERC20;

    // Contracts (constant)
    IGNSTradingStorage public storageT;

    // Contracts (adjustable)
    IGNSMultiCollatDiamond public multiCollatDiamond;
    IChainlinkFeed public linkUsdPriceFeed;
    IChainlinkFeed public collateralUsdPriceFeed;

    // Params (constant)
    uint256 private constant PRECISION = 1e10;
    uint256 private constant MAX_ORACLE_NODES = 20;
    uint256 private constant MIN_ANSWERS = 3;

    // Params (adjustable)
    uint256 public minAnswers;

    // State
    address[] public nodes;
    bytes32[2] public jobIds;

    mapping(uint256 => Order) public orders;
    mapping(bytes32 => uint256) public orderIdByRequest;
    mapping(uint256 => uint256[]) public ordersAnswers;
    mapping(uint256 => LookbackOrderAnswer[]) public lookbackOrderAnswers;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _linkToken,
        IUniswapV3Pool _tokenDaiLp,
        uint32 _twapInterval,
        IGNSTradingStorage _storageT,
        IGNSMultiCollatDiamond _multiCollatDiamond,
        IChainlinkFeed _linkPriceFeed,
        IChainlinkFeed _collateralPriceFeed,
        uint256 _minAnswers,
        address[] memory _nodes,
        bytes32[2] memory _jobIds
    ) external initializer {
        __TWAPPriceGetter_init_unchained(_tokenDaiLp, address(_storageT.token()), _twapInterval, _storageT.dai());

        require(
            address(_storageT) != address(0) &&
                address(_multiCollatDiamond) != address(0) &&
                address(_linkPriceFeed) != address(0) &&
                address(_collateralPriceFeed) != address(0) &&
                _minAnswers >= MIN_ANSWERS &&
                _minAnswers % 2 == 1 &&
                _nodes.length > 0 &&
                _linkToken != address(0),
            "WRONG_PARAMS"
        );

        storageT = _storageT;

        multiCollatDiamond = _multiCollatDiamond;
        linkUsdPriceFeed = _linkPriceFeed;
        collateralUsdPriceFeed = _collateralPriceFeed;

        minAnswers = _minAnswers;
        nodes = _nodes;
        jobIds = _jobIds;

        setChainlinkToken(_linkToken);
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

    // Manage contracts
    function updateLinkPriceFeed(IChainlinkFeed value) external onlyGov {
        require(address(value) != address(0), "VALUE_0");

        linkUsdPriceFeed = value;

        emit LinkPriceFeedUpdated(address(value));
    }

    function updateCollateralPriceFeed(IChainlinkFeed value) external onlyGov {
        require(address(value) != address(0), "VALUE_0");

        collateralUsdPriceFeed = value;

        emit CollateralPriceFeedUpdated(address(value));
    }

    // Manage TWAP variables
    function updateUniV3Pool(IUniswapV3Pool _uniV3Pool) external onlyGov {
        _updateUniV3Pool(_uniV3Pool);
    }

    function updateTwapInterval(uint32 _twapInterval) external onlyGov {
        _updateTwapInterval(_twapInterval);
    }

    // Manage params
    function updateMinAnswers(uint256 value) external onlyGov {
        require(value >= MIN_ANSWERS, "MIN_ANSWERS");
        require(value % 2 == 1, "EVEN");

        minAnswers = value;

        emit MinAnswersUpdated(value);
    }

    // Manage nodes
    function addNode(address a) external onlyGov {
        require(a != address(0), "VALUE_0");
        require(nodes.length < MAX_ORACLE_NODES, "MAX_ORACLE_NODES");

        for (uint256 i; i < nodes.length; ++i) {
            require(nodes[i] != a, "ALREADY_LISTED");
        }

        nodes.push(a);

        emit NodeAdded(nodes.length - 1, a);
    }

    function replaceNode(uint256 index, address a) external onlyGov {
        require(index < nodes.length, "WRONG_INDEX");
        require(a != address(0), "VALUE_0");

        emit NodeReplaced(index, nodes[index], a);

        nodes[index] = a;
    }

    function removeNode(uint256 index) external onlyGov {
        require(index < nodes.length, "WRONG_INDEX");

        emit NodeRemoved(index, nodes[index]);

        nodes[index] = nodes[nodes.length - 1];
        nodes.pop();
    }

    function setMarketJobId(bytes32 jobId) external onlyGov {
        require(jobId != bytes32(0), "VALUE_0");

        jobIds[0] = jobId;

        emit JobIdUpdated(0, jobId);
    }

    function setLimitJobId(bytes32 jobId) external onlyGov {
        require(jobId != bytes32(0), "VALUE_0");

        jobIds[1] = jobId;

        emit JobIdUpdated(1, jobId);
    }

    // On-demand price request to oracles network
    function getPrice(
        uint256 pairIndex,
        OrderType orderType,
        uint256 leveragedPosDai,
        uint256 fromBlock
    ) external onlyTrading returns (uint256) {
        require(pairIndex <= type(uint16).max, "PAIR_OVERFLOW");

        bool isLookback = orderType == OrderType.LIMIT_OPEN || orderType == OrderType.LIMIT_CLOSE;
        bytes32 job = isLookback ? jobIds[1] : jobIds[0];

        Chainlink.Request memory linkRequest = buildChainlinkRequest(job, address(this), this.fulfill.selector);

        uint256 orderId;
        {
            (string memory from, string memory to, , uint256 _orderId) = multiCollatDiamond.pairJob(pairIndex);
            orderId = _orderId;

            linkRequest.add("from", from);
            linkRequest.add("to", to);

            if (isLookback) {
                linkRequest.addUint("fromBlock", fromBlock);
            }
        }

        uint256 length;
        uint256 linkFeePerNode;
        {
            address[] memory _nodes = nodes;
            length = _nodes.length;
            linkFeePerNode = linkFee(pairIndex, leveragedPosDai) / length;

            require(linkFeePerNode <= type(uint112).max, "LINK_OVERFLOW");

            orders[orderId] = Order(uint16(pairIndex), uint112(linkFeePerNode), orderType, true, isLookback);

            for (uint256 i; i < length; ) {
                orderIdByRequest[sendChainlinkRequestTo(_nodes[i], linkRequest, linkFeePerNode)] = orderId;
                unchecked {
                    ++i;
                }
            }
        }

        emit PriceRequested(orderId, job, pairIndex, orderType, length, linkFeePerNode, fromBlock, isLookback);

        return orderId;
    }

    // Fulfill on-demand price requests
    function fulfill(bytes32 requestId, uint256 priceData) external recordChainlinkFulfillment(requestId) {
        uint256 orderId = orderIdByRequest[requestId];
        delete orderIdByRequest[requestId];

        Order memory r = orders[orderId];
        bool usedInMedian = false;

        IGNSMultiCollatDiamond.Feed memory f = multiCollatDiamond.pairFeed(r.pairIndex);
        uint256 feedPrice = fetchFeedPrice(f);

        if (r.active) {
            if (r.isLookback) {
                LookbackOrderAnswer memory newAnswer;
                (newAnswer.open, newAnswer.high, newAnswer.low, newAnswer.ts) = priceData.unpack256To64();

                require(
                    (newAnswer.high == 0 && newAnswer.low == 0) ||
                        (newAnswer.high >= newAnswer.open && newAnswer.low <= newAnswer.open && newAnswer.low > 0),
                    "INVALID_CANDLE"
                );

                if (
                    isPriceWithinDeviation(newAnswer.high, feedPrice, f.maxDeviationP) &&
                    isPriceWithinDeviation(newAnswer.low, feedPrice, f.maxDeviationP)
                ) {
                    usedInMedian = true;

                    LookbackOrderAnswer[] storage answers = lookbackOrderAnswers[orderId];
                    answers.push(newAnswer);

                    if (answers.length == minAnswers) {
                        IGNSTradingCallbacks.AggregatorAnswer memory a;
                        a.orderId = orderId;
                        (a.open, a.high, a.low) = medianLookbacks(answers);
                        a.spreadP = multiCollatDiamond.pairSpreadP(r.pairIndex);

                        IGNSTradingCallbacks c = IGNSTradingCallbacks(storageT.callbacks());

                        if (r.orderType == OrderType.LIMIT_OPEN) {
                            c.executeNftOpenOrderCallback(a);
                        } else {
                            c.executeNftCloseOrderCallback(a);
                        }

                        emit CallbackExecuted(a, r.orderType);

                        orders[orderId].active = false;
                        delete lookbackOrderAnswers[orderId];
                    }
                }
            } else {
                (uint64 price, , , ) = priceData.unpack256To64();

                if (isPriceWithinDeviation(price, feedPrice, f.maxDeviationP)) {
                    usedInMedian = true;

                    uint256[] storage answers = ordersAnswers[orderId];
                    answers.push(price);

                    if (answers.length == minAnswers) {
                        IGNSTradingCallbacks.AggregatorAnswer memory a;

                        a.orderId = orderId;
                        a.price = median(answers);
                        a.spreadP = multiCollatDiamond.pairSpreadP(r.pairIndex);

                        IGNSTradingCallbacks c = IGNSTradingCallbacks(storageT.callbacks());

                        if (r.orderType == OrderType.MARKET_OPEN) {
                            c.openTradeMarketCallback(a);
                        } else {
                            c.closeTradeMarketCallback(a);
                        }

                        emit CallbackExecuted(a, r.orderType);

                        orders[orderId].active = false;
                        delete ordersAnswers[orderId];
                    }
                }
            }
        }

        emit PriceReceived(
            requestId,
            orderId,
            msg.sender,
            r.pairIndex,
            priceData,
            feedPrice,
            r.linkFeePerNode,
            r.isLookback,
            usedInMedian
        );
    }

    // Calculate LINK fee for each request
    function linkFee(uint256 pairIndex, uint256 leveragedPosDai) public view returns (uint256) {
        (, int256 linkPriceUsd, , , ) = linkUsdPriceFeed.latestRoundData();

        // NOTE: all [token / USD] feeds are 8 decimals
        return
            (getUsdNormalizedValue(multiCollatDiamond.pairOracleFeeP(pairIndex) * leveragedPosDai) * 1e8) /
            uint256(linkPriceUsd) /
            PRECISION /
            100;
    }

    // Get {collateral}/USD price (8 decimal precision)
    function getCollateralPriceUsd() public view returns (uint256) {
        (, int256 collateralPriceUsd, , , ) = collateralUsdPriceFeed.latestRoundData();

        return uint256(collateralPriceUsd);
    }

    // Normalize {collateral} value to USD (18 decimal precision)
    function getUsdNormalizedValue(
        uint256 collateralValue // 1e18 | 1e6
    ) public view returns (uint256) {
        return (collateralValue * collateralConfig.precisionDelta * getCollateralPriceUsd()) / 1e8;
    }

    // Denormalizes {normalizedValue} to {collateral} value and precision
    function getCollateralFromUsdNormalizedValue(
        uint256 normalizedValue // (1e18 USD)
    ) external view returns (uint256) {
        return (normalizedValue * 1e8) / getCollateralPriceUsd() / collateralConfig.precisionDelta;
    }

    // Derive GNS/USD value from GNS/{collateral} and {collateral}/USD (10 decimal precision)
    function getTokenPriceUsd() external view returns (uint256) {
        return getTokenPriceUsd(tokenPriceDai());
    }

    // Derive GNS/USD value from {tokenPriceCollateral} and {collateral}/USD (10 decimal precision)
    function getTokenPriceUsd(
        uint256 tokenPriceCollateral // 1e10
    ) public view returns (uint256) {
        return (tokenPriceCollateral * getCollateralPriceUsd()) / 1e8;
    }

    // Claim back LINK tokens (if contract will be replaced for example)
    function claimBackLink() external onlyGov {
        IERC20 link = IERC20(storageT.linkErc677());

        link.safeTransfer(storageT.gov(), link.balanceOf(address(this)));
    }

    // Utils
    function fetchFeedPrice(IGNSMultiCollatDiamond.Feed memory f) private view returns (uint256) {
        if (f.feed1 == address(0)) {
            return 0;
        }

        uint256 feedPrice;
        (, int256 feedPrice1, , , ) = IChainlinkFeed(f.feed1).latestRoundData();

        if (f.feedCalculation == IPairsStorageUtils.FeedCalculation.DEFAULT) {
            feedPrice = uint256((feedPrice1 * int256(PRECISION)) / 1e8);
        } else if (f.feedCalculation == IPairsStorageUtils.FeedCalculation.INVERT) {
            feedPrice = uint256((int256(PRECISION) * 1e8) / feedPrice1);
        } else {
            (, int256 feedPrice2, , , ) = IChainlinkFeed(f.feed2).latestRoundData();
            feedPrice = uint256((feedPrice1 * int256(PRECISION)) / feedPrice2);
        }

        return feedPrice;
    }

    function isPriceWithinDeviation(
        uint256 price,
        uint256 feedPrice,
        uint256 maxDeviationP
    ) private pure returns (bool) {
        return
            price == 0 ||
            feedPrice == 0 ||
            ((price >= feedPrice ? price - feedPrice : feedPrice - price) * PRECISION * 100) / feedPrice <=
            maxDeviationP;
    }

    // Median function
    function _swap(uint256[] memory array, uint256 i, uint256 j) private pure {
        (array[i], array[j]) = (array[j], array[i]);
    }

    function _sort(uint256[] memory array, uint256 begin, uint256 end) private pure {
        if (begin >= end) {
            return;
        }

        uint256 j = begin;
        uint256 pivot = array[j];

        for (uint256 i = begin + 1; i < end; ++i) {
            if (array[i] < pivot) {
                _swap(array, i, ++j);
            }
        }

        _swap(array, begin, j);
        _sort(array, begin, j);
        _sort(array, j + 1, end);
    }

    function median(uint256[] memory array) private pure returns (uint256) {
        _sort(array, 0, array.length);

        return
            array.length % 2 == 0
                ? (array[array.length / 2 - 1] + array[array.length / 2]) / 2
                : array[array.length / 2];
    }

    function medianLookbacks(
        LookbackOrderAnswer[] memory array
    ) private pure returns (uint256 open, uint256 high, uint256 low) {
        uint256 length = array.length;

        uint256[] memory opens = new uint256[](length);
        uint256[] memory highs = new uint256[](length);
        uint256[] memory lows = new uint256[](length);

        for (uint256 i; i < length; ) {
            opens[i] = array[i].open;
            highs[i] = array[i].high;
            lows[i] = array[i].low;

            unchecked {
                ++i;
            }
        }

        _sort(opens, 0, length);
        _sort(highs, 0, length);
        _sort(lows, 0, length);

        bool isLengthEven = length % 2 == 0;
        uint256 halfLength = length / 2;

        open = isLengthEven ? (opens[halfLength - 1] + opens[halfLength]) / 2 : opens[halfLength];
        high = isLengthEven ? (highs[halfLength - 1] + highs[halfLength]) / 2 : highs[halfLength];
        low = isLengthEven ? (lows[halfLength - 1] + lows[halfLength]) / 2 : lows[halfLength];
    }

    // Override
    function tokenPriceDai() public view override(IGNSPriceAggregator, TWAPPriceGetter) returns (uint256) {
        return TWAPPriceGetter.tokenPriceDai();
    }
}