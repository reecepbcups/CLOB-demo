// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";

contract CLOB is IWavsServiceHandler {
    using SafeERC20 for IERC20;

    enum OrderType {
        BUY,
        SELL
    }

    enum OrderStatus {
        OPEN,
        PARTIALLY_FILLED,
        FILLED,
        CANCELLED
    }

    struct Order {
        uint256 id;
        address trader;
        OrderType orderType;
        address baseToken;
        address quoteToken;
        uint256 price;
        uint256 amount;
        uint256 filledAmount;
        OrderStatus status;
        uint256 timestamp;
    }

    struct OrderMatch {
        uint256 buyOrderId;
        uint256 sellOrderId;
        uint256 matchAmount;
        uint256 matchPrice;
    }

    IWavsServiceManager private _serviceManager;
    uint256 public nextOrderId = 1;

    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userOrders;
    mapping(bytes32 => uint256[]) public orderBook;

    mapping(address => mapping(address => uint256)) public escrowBalances;

    // Track processed envelopes to prevent replay
    mapping(bytes32 => bool) public processedEnvelopes;

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType,
        address baseToken,
        address quoteToken,
        uint256 price,
        uint256 amount,
        uint256 timestamp
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed trader,
        uint256 remainingAmount
    );

    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address indexed baseToken,
        address quoteToken,
        uint256 price,
        uint256 amount,
        uint256 timestamp
    );

    event OrderPartiallyFilled(
        uint256 indexed orderId,
        uint256 filledAmount,
        uint256 remainingAmount
    );

    event FundsDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event FundsWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event CLOBTrigger(
        uint256 indexed orderId
    );

    constructor(IWavsServiceManager serviceManager) {
        _serviceManager = serviceManager;
    }

    modifier validOrder(uint256 _orderId) {
        require(orders[_orderId].id != 0, "Order does not exist");
        _;
    }

    function placeOrder(
        OrderType _orderType,
        address _baseToken,
        address _quoteToken,
        uint256 _price,
        uint256 _amount
    ) external  returns (uint256) { // nonReentrant
        require(_baseToken != address(0), "Invalid base token");
        require(_quoteToken != address(0), "Invalid quote token");
        require(_price > 0, "Price must be greater than 0");
        require(_amount > 0, "Amount must be greater than 0");

        uint256 orderId = nextOrderId++;

        uint256 requiredAmount;
        address requiredToken;

        if (_orderType == OrderType.BUY) {
            uint256 quoteAmount = (_amount * _price) / 1e18;
            requiredAmount = quoteAmount;
            requiredToken = _quoteToken;
        } else {
            requiredAmount = _amount;
            requiredToken = _baseToken;
        }

        IERC20(requiredToken).safeTransferFrom(
            msg.sender,
            address(this),
            requiredAmount
        );

        escrowBalances[msg.sender][requiredToken] += requiredAmount;

        Order memory newOrder = Order({
            id: orderId,
            trader: msg.sender,
            orderType: _orderType,
            baseToken: _baseToken,
            quoteToken: _quoteToken,
            price: _price,
            amount: _amount,
            filledAmount: 0,
            status: OrderStatus.OPEN,
            timestamp: block.timestamp
        });

        orders[orderId] = newOrder;
        userOrders[msg.sender].push(orderId);

        bytes32 bookKey = getOrderBookKey(_baseToken, _quoteToken);
        orderBook[bookKey].push(orderId);

        emit OrderPlaced(
            orderId,
            msg.sender,
            _orderType,
            _baseToken,
            _quoteToken,
            _price,
            _amount,
            block.timestamp
        );

        emit FundsDeposited(msg.sender, requiredToken, requiredAmount);

        // Emit trigger event for WAVS to process order matching off-chain
        emit CLOBTrigger(orderId);

        return orderId;
    }

    function cancelOrder(uint256 _orderId) external validOrder(_orderId) { // nonReentrant
        Order storage order = orders[_orderId];
        require(order.trader == msg.sender, "Not order owner");
        require(
            order.status == OrderStatus.OPEN ||
            order.status == OrderStatus.PARTIALLY_FILLED,
            "Order cannot be cancelled"
        );

        uint256 remainingAmount = order.amount - order.filledAmount;

        uint256 refundAmount;
        address refundToken;

        if (order.orderType == OrderType.BUY) {
            refundAmount = (remainingAmount * order.price) / 1e18;
            refundToken = order.quoteToken;
        } else {
            refundAmount = remainingAmount;
            refundToken = order.baseToken;
        }

        order.status = OrderStatus.CANCELLED;

        if (refundAmount > 0 && escrowBalances[msg.sender][refundToken] >= refundAmount) {
            escrowBalances[msg.sender][refundToken] -= refundAmount;

            IERC20(refundToken).safeTransfer(msg.sender, refundAmount);

            emit FundsWithdrawn(msg.sender, refundToken, refundAmount);
        }

        emit OrderCancelled(_orderId, msg.sender, remainingAmount);
    }

    function withdrawFunds(address _token, uint256 _amount) external { // nonReentrant
        require(_token != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be greater than 0");
        require(
            escrowBalances[msg.sender][_token] >= _amount,
            "Insufficient escrow balance"
        );

        escrowBalances[msg.sender][_token] -= _amount;

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit FundsWithdrawn(msg.sender, _token, _amount);
    }

    /// @inheritdoc IWavsServiceHandler
    function handleSignedEnvelope(
        Envelope calldata envelope,
        SignatureData calldata signatureData
    ) external {
        // Validate the envelope signature using WAVS service manager
        _serviceManager.validate(envelope, signatureData);

        // Prevent replay attacks
        bytes32 envelopeHash = keccak256(abi.encode(envelope));
        require(!processedEnvelopes[envelopeHash], "Envelope already processed");
        processedEnvelopes[envelopeHash] = true;

        // Decode the order match data from the envelope
        OrderMatch[] memory matches = abi.decode(
            envelope.payload,
            (OrderMatch[])
        );

        // Execute all order matches
        for (uint256 i = 0; i < matches.length; i++) {
            executeMatch(matches[i]);
        }
    }

    function executeMatch(
        OrderMatch memory matchData
    ) internal {
        Order storage buyOrder = orders[matchData.buyOrderId];
        Order storage sellOrder = orders[matchData.sellOrderId];

        // Validate orders exist and are valid
        require(buyOrder.id != 0, "Buy order does not exist");
        require(sellOrder.id != 0, "Sell order does not exist");
        require(buyOrder.orderType == OrderType.BUY, "Invalid buy order");
        require(sellOrder.orderType == OrderType.SELL, "Invalid sell order");

        // Check order status
        require(
            buyOrder.status == OrderStatus.OPEN || buyOrder.status == OrderStatus.PARTIALLY_FILLED,
            "Buy order not open"
        );
        require(
            sellOrder.status == OrderStatus.OPEN || sellOrder.status == OrderStatus.PARTIALLY_FILLED,
            "Sell order not open"
        );

        // Validate match parameters
        uint256 remainingBuy = buyOrder.amount - buyOrder.filledAmount;
        uint256 remainingSell = sellOrder.amount - sellOrder.filledAmount;
        require(matchData.matchAmount <= remainingBuy, "Match amount exceeds buy order");
        require(matchData.matchAmount <= remainingSell, "Match amount exceeds sell order");

        // Update order states
        buyOrder.filledAmount += matchData.matchAmount;
        sellOrder.filledAmount += matchData.matchAmount;

        if (buyOrder.filledAmount == buyOrder.amount) {
            buyOrder.status = OrderStatus.FILLED;
        } else {
            buyOrder.status = OrderStatus.PARTIALLY_FILLED;
            emit OrderPartiallyFilled(buyOrder.id, matchData.matchAmount, buyOrder.amount - buyOrder.filledAmount);
        }

        if (sellOrder.filledAmount == sellOrder.amount) {
            sellOrder.status = OrderStatus.FILLED;
        } else {
            sellOrder.status = OrderStatus.PARTIALLY_FILLED;
            emit OrderPartiallyFilled(sellOrder.id, matchData.matchAmount, sellOrder.amount - sellOrder.filledAmount);
        }

        // Calculate quote amount based on match price
        uint256 quoteAmount = (matchData.matchAmount * matchData.matchPrice) / 1e18;

        // Update escrow balances
        escrowBalances[buyOrder.trader][buyOrder.quoteToken] -= quoteAmount;
        escrowBalances[sellOrder.trader][sellOrder.baseToken] -= matchData.matchAmount;

        escrowBalances[buyOrder.trader][buyOrder.baseToken] += matchData.matchAmount;
        escrowBalances[sellOrder.trader][sellOrder.quoteToken] += quoteAmount;

        // Emit match event
        emit OrderMatched(
            buyOrder.id,
            sellOrder.id,
            buyOrder.baseToken,
            buyOrder.quoteToken,
            matchData.matchPrice,
            matchData.matchAmount,
            block.timestamp
        );
    }

    function getOrderBookKey(
        address _baseToken,
        address _quoteToken
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_baseToken, _quoteToken));
    }

    function getOrder(uint256 _orderId) external view returns (Order memory) {
        return orders[_orderId];
    }

    function getUserOrders(address _user) external view returns (uint256[] memory) {
        return userOrders[_user];
    }

    function getEscrowBalance(address _user, address _token) external view returns (uint256) {
        return escrowBalances[_user][_token];
    }

    function getOrderBookOrders(
        address _baseToken,
        address _quoteToken
    ) external view returns (uint256[] memory) {
        bytes32 bookKey = getOrderBookKey(_baseToken, _quoteToken);
        return orderBook[bookKey];
    }

    function getServiceManager() external view returns (address) {
        return address(_serviceManager);
    }
}
