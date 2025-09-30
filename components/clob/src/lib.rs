#[rustfmt::skip]
pub mod bindings;
pub mod solidity;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use trigger::{
    encode_matches_output, parse_clob_trigger, parse_order_placed_event, MatchResult, Order,
    OrderBookEntry, OrderStatus, OrderType,
};
use wavs_wasi_utils::evm::alloy_primitives::{hex, Address, U256};
use wstd::runtime::block_on;

struct Component;
export!(Component with_types_in bindings);

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OrderBook {
    buy_orders: BTreeMap<String, Vec<OrderBookEntry>>, // price -> orders
    sell_orders: BTreeMap<String, Vec<OrderBookEntry>>, // price -> orders
}

impl OrderBook {
    fn new() -> Self {
        Self { buy_orders: BTreeMap::new(), sell_orders: BTreeMap::new() }
    }

    fn load_from_file(file_path: &str) -> Self {
        if Path::new(file_path).exists() {
            match fs::read_to_string(file_path) {
                Ok(contents) => match serde_json::from_str::<OrderBook>(&contents) {
                    Ok(order_book) => {
                        println!("📂 Loaded order book from file with {} buy price levels, {} sell price levels", 
                                order_book.buy_orders.len(), order_book.sell_orders.len());
                        return order_book;
                    }
                    Err(e) => println!("⚠️ Failed to parse order book file: {}", e),
                },
                Err(e) => println!("⚠️ Failed to read order book file: {}", e),
            }
        } else {
            println!("📁 Order book file not found, creating new order book");
        }
        Self::new()
    }

    fn save_to_file(&self, file_path: &str) -> Result<()> {
        let contents = serde_json::to_string_pretty(self)?;
        fs::write(file_path, contents)?;
        println!(
            "💾 Saved order book to file with {} buy price levels, {} sell price levels",
            self.buy_orders.len(),
            self.sell_orders.len()
        );
        Ok(())
    }

    fn add_order(&mut self, order: Order) {
        let remaining = order.amount - order.filled_amount;
        if remaining == U256::ZERO {
            return;
        }

        let entry = OrderBookEntry { order: order.clone(), remaining_amount: remaining };

        let price_key = order.price.to_string();

        match order.order_type {
            OrderType::Buy => {
                self.buy_orders.entry(price_key).or_insert_with(Vec::new).push(entry);
            }
            OrderType::Sell => {
                self.sell_orders.entry(price_key).or_insert_with(Vec::new).push(entry);
            }
        }
    }

    fn match_orders(&mut self) -> Vec<MatchResult> {
        let mut matches = Vec::new();

        // Get best buy price (highest)
        let best_buy = self.buy_orders.keys().rev().next().cloned();
        // Get best sell price (lowest)
        let best_sell = self.sell_orders.keys().next().cloned();

        if let (Some(buy_price_str), Some(sell_price_str)) = (best_buy, best_sell) {
            let buy_price = U256::from_str_radix(&buy_price_str, 10).unwrap_or(U256::ZERO);
            let sell_price = U256::from_str_radix(&sell_price_str, 10).unwrap_or(U256::MAX);

            // Check if prices cross (buy price >= sell price)
            if buy_price >= sell_price {
                // Get orders at these price levels
                let buy_orders = self.buy_orders.get_mut(&buy_price_str);
                let sell_orders = self.sell_orders.get_mut(&sell_price_str);

                if let (Some(buys), Some(sells)) = (buy_orders, sell_orders) {
                    if !buys.is_empty() && !sells.is_empty() {
                        let buy_order = &buys[0];
                        let sell_order = &sells[0];

                        // Calculate match amount
                        let match_amount =
                            buy_order.remaining_amount.min(sell_order.remaining_amount);

                        if match_amount > U256::ZERO {
                            // Use the sell price as the match price (price-time priority)
                            let match_price = sell_price;

                            matches.push(MatchResult {
                                buy_order_id: U256::from(buy_order.order.id),
                                sell_order_id: U256::from(sell_order.order.id),
                                match_amount,
                                match_price,
                            });

                            // Update remaining amounts
                            buys[0].remaining_amount -= match_amount;
                            sells[0].remaining_amount -= match_amount;

                            // Remove filled orders
                            if buys[0].remaining_amount == U256::ZERO {
                                buys.remove(0);
                            }
                            if sells[0].remaining_amount == U256::ZERO {
                                sells.remove(0);
                            }

                            // Clean up empty price levels
                            if buys.is_empty() {
                                self.buy_orders.remove(&buy_price_str);
                            }
                            if sells.is_empty() {
                                self.sell_orders.remove(&sell_price_str);
                            }
                        }
                    }
                }
            }
        }

        matches
    }
}

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Option<WasmResponse>, String> {
        println!("🚀 Starting CLOB component execution");

        // Get contract address from config
        // let clob_address = bindings::host::config_var("clob_address")
        //     .ok_or_else(|| "CLOB contract address not configured".to_string())?;

        // println!("📋 CLOB Contract: {}", clob_address);

        // Process the trigger event
        let result = block_on(async {
            match process_trigger(&action).await {
                Ok(matches) if !matches.is_empty() => {
                    println!("✅ Found {} order matches", matches.len());

                    // Encode matches for contract
                    let encoded = encode_matches_output(&matches)
                        .map_err(|e| format!("Failed to encode matches: {}", e))?;

                    // Return the encoded matches as the response
                    Ok(Some(WasmResponse {
                        payload: encoded,
                        ordering: None,
                        // envelope_payload_hash: Vec::new(), // Will be computed by WAVS
                    }))
                }
                Ok(_) => {
                    println!("ℹ️ No matches found in current order book");
                    Ok(None)
                }
                Err(e) => {
                    println!("❌ Error processing trigger: {}", e);
                    Err(e.to_string())
                }
            }
        });

        result
    }
}

async fn process_trigger(action: &TriggerAction) -> Result<Vec<MatchResult>> {
    // Extract event data from the trigger
    let event = match &action.data {
        bindings::wavs::types::events::TriggerData::EvmContractEvent(event) => {
            println!("📊 Processing EVM contract event");
            event
        }
        _ => {
            println!("⚠️ Unexpected trigger type");
            return Ok(Vec::new());
        }
    };

    // Load existing order book from file
    const ORDER_BOOK_FILE: &str = "clob_order_book.json";
    let mut order_book = OrderBook::load_from_file(ORDER_BOOK_FILE);

    // Determine which event we're processing based on event topics
    let matches = if !event.log.data.topics.is_empty() {
        let event_signature = hex::encode(&event.log.data.topics[0]);

        if event_signature.starts_with("7fc72616") {
            // CLOBTrigger event signature
            println!("🎯 Processing CLOBTrigger event");
            let order_id = parse_clob_trigger(event.log.data.clone())?;
            println!("🔄 CLOBTrigger received for order ID: {}", order_id);
            // For CLOBTrigger events, we might want to process all pending orders
            // For now, just return empty matches
            Vec::new()
        } else if event_signature.starts_with("f860599f") {
            // OrderPlaced event signature
            println!("📋 Processing OrderPlaced event");
            let order = parse_order_placed_event(event.log.data.clone())?;
            println!(
                "✅ Parsed order: ID={}, Type={:?}, Price={}, Amount={}",
                order.id, order.order_type, order.price, order.amount
            );

            // Add the new order to the book
            order_book.add_order(order.clone());

            // Run matching algorithm to find any matches
            let matches = order_book.match_orders();

            if !matches.is_empty() {
                println!("🎯 Found {} matches!", matches.len());
                for m in &matches {
                    println!(
                        "   💹 Match: Buy Order {} <-> Sell Order {}, Amount: {}, Price: {}",
                        m.buy_order_id, m.sell_order_id, m.match_amount, m.match_price
                    );
                }
            }

            matches
        } else {
            println!("⚠️ Unknown event signature: {}", event_signature);
            Vec::new()
        }
    } else {
        println!("⚠️ Event has no topics");
        Vec::new()
    };

    // Save the updated order book back to file
    if let Err(e) = order_book.save_to_file(ORDER_BOOK_FILE) {
        println!("⚠️ Failed to save order book: {}", e);
    }

    Ok(matches)
}
