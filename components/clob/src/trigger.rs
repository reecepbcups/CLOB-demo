use crate::solidity;
use alloy_sol_types::SolValue;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use wavs_wasi_utils::decode_event_log_data;
use wavs_wasi_utils::evm::alloy_primitives::{Address, U256};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub id: u64,
    pub trader: Address,
    pub order_type: OrderType,
    pub base_token: Address,
    pub quote_token: Address,
    pub price: U256,
    pub amount: U256,
    pub filled_amount: U256,
    pub status: OrderStatus,
    pub timestamp: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrderType {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrderStatus {
    Open,
    PartiallyFilled,
    Filled,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderBookEntry {
    pub order: Order,
    pub remaining_amount: U256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchResult {
    pub buy_order_id: U256,
    pub sell_order_id: U256,
    pub match_amount: U256,
    pub match_price: U256,
}

impl MatchResult {
    pub fn to_solidity(&self) -> solidity::OrderMatch {
        solidity::OrderMatch {
            buyOrderId: self.buy_order_id,
            sellOrderId: self.sell_order_id,
            matchAmount: self.match_amount,
            matchPrice: self.match_price,
        }
    }
}

/// Encode the matched orders for submission to the CLOB contract
pub fn encode_matches_output(matches: &[MatchResult]) -> Result<Vec<u8>> {
    let sol_matches: Vec<solidity::OrderMatch> = matches.iter().map(|m| m.to_solidity()).collect();
    Ok(sol_matches.abi_encode())
}

/// Parse CLOBTrigger event to get order ID
pub fn parse_clob_trigger(
    log_data: crate::bindings::wavs::types::chain::EvmEventLogData,
) -> Result<U256> {
    let event: solidity::CLOBTrigger = decode_event_log_data!(log_data)?;
    Ok(event.orderId)
}

/// Parse OrderPlaced event data from contract events
pub fn parse_order_placed_event(
    log_data: crate::bindings::wavs::types::chain::EvmEventLogData,
) -> Result<Order> {
    // Decode the OrderPlaced event using the macro
    let event: solidity::OrderPlaced = decode_event_log_data!(log_data)?;

    // Convert event data to our Order struct
    let order_type = match event.orderType {
        0 => OrderType::Buy,
        1 => OrderType::Sell,
        _ => return Err(anyhow::anyhow!("Invalid order type: {}", event.orderType)),
    };

    Ok(Order {
        id: event.orderId.to::<u64>(),
        trader: event.trader,
        order_type,
        base_token: event.baseToken,
        quote_token: event.quoteToken,
        price: event.price,
        amount: event.amount,
        filled_amount: U256::ZERO, // New orders start unfilled
        status: OrderStatus::Open,
        timestamp: event.timestamp.to::<u64>(),
    })
}
