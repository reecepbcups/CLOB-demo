#!/bin/bash

decode_order() {
    local hex_data="$1"

    if [ -z "$hex_data" ]; then
        echo "Usage: decode_order <hex_data>"
        echo "Example: decode_order 0x000000..."
        return 1
    fi

    # Remove 0x prefix if present
    hex_data=${hex_data#0x}

    # Extract each 64-character (32-byte) chunk
    local id_hex="0x${hex_data:0:64}"
    local trader_hex="0x${hex_data:88:40}"  # Skip 24 zeros, take 40 chars (20 bytes)
    local order_type_hex="0x${hex_data:128:64}"
    local base_token_hex="0x${hex_data:216:40}"  # Skip 24 zeros, take 40 chars
    local quote_token_hex="0x${hex_data:280:40}"  # Skip 24 zeros, take 40 chars
    local price_hex="0x${hex_data:320:64}"
    local amount_hex="0x${hex_data:384:64}"
    local filled_amount_hex="0x${hex_data:448:64}"
    local status_hex="0x${hex_data:512:64}"
    local timestamp_hex="0x${hex_data:576:64}"

    # Convert to decimal/addresses
    local id=$(cast to-dec "$id_hex")
    local trader="0x$trader_hex"
    local order_type=$(cast to-dec "$order_type_hex")
    local base_token="0x$base_token_hex"
    local quote_token="0x$quote_token_hex"
    local price_wei=$(cast to-dec "$price_hex")
    local amount_wei=$(cast to-dec "$amount_hex")
    local filled_amount_wei=$(cast to-dec "$filled_amount_hex")
    local status=$(cast to-dec "$status_hex")
    local timestamp=$(cast to-dec "$timestamp_hex")

    # Convert order type
    local order_type_str
    case $order_type in
        0) order_type_str="BUY" ;;
        1) order_type_str="SELL" ;;
        *) order_type_str="UNKNOWN($order_type)" ;;
    esac

    # Convert status
    local status_str
    case $status in
        0) status_str="OPEN" ;;
        1) status_str="PARTIALLY_FILLED" ;;
        2) status_str="FILLED" ;;
        3) status_str="CANCELLED" ;;
        *) status_str="UNKNOWN($status)" ;;
    esac

    # Convert wei to ETH
    local price_eth=$(cast from-wei "$price_wei")
    local amount_eth=$(cast from-wei "$amount_wei")
    local filled_amount_eth=$(cast from-wei "$filled_amount_wei")

    # Convert timestamp to date
    local date_str
    if command -v date >/dev/null 2>&1; then
        date_str=$(date -r "$timestamp" 2>/dev/null || echo "Invalid timestamp")
    else
        date_str="Timestamp: $timestamp"
    fi

    echo "=== Decoded Order #$id ==="
    echo "ID: $id"
    echo "Trader: $trader"
    echo "Order Type: $order_type_str ($order_type)"
    echo "Base Token: $base_token"
    echo "Quote Token: $quote_token"
    echo "Price: $price_eth ETH ($price_wei wei)"
    echo "Amount: $amount_eth ETH ($amount_wei wei)"
    echo "Filled Amount: $filled_amount_eth ETH ($filled_amount_wei wei)"
    echo "Status: $status_str ($status)"
    echo "Timestamp: $date_str"

    # Calculate fill percentage if amount > 0
    if [ "$amount_wei" != "0" ] && [ -n "$amount_wei" ]; then
        local fill_percentage=$(echo "scale=2; $filled_amount_wei * 100 / $amount_wei" | bc -l 2>/dev/null || echo "N/A")
        echo "Fill Percentage: ${fill_percentage}%"
    fi
}

decode_order "$1"
