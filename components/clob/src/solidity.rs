use alloy_sol_types::sol;

sol! {
    struct OrderMatch {
        uint256 buyOrderId;
        uint256 sellOrderId;
        uint256 matchAmount;
        uint256 matchPrice;
    }

    // Event definitions from CLOB.sol
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint8 orderType,
        address baseToken,
        address quoteToken,
        uint256 price,
        uint256 amount,
        uint256 timestamp
    );

    event CLOBTrigger(
        uint256 indexed orderId
    );
}
