#!/bin/bash

# Initialize variables
ALB_URL=${ALB_URL:-""}
API_PATH=${API_PATH:-"/apps/cart"}

# Simple logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1: $2"
}

# Send single request
send_request() {
    local data="{
        \"id\": \"$(uuidgen)\",
        \"items\": [{
            \"id\": \"$(uuidgen)\",
            \"name\": \"Test Book\",
            \"price\": 29.99,
            \"quantity\": 1,
            \"product\": {
                \"id\": \"$(uuidgen)\",
                \"title\": \"Test Book\",
                \"author\": \"Test Author\",
                \"year\": 2024
            }
        }]
    }"
    
    local response=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "Host: ${ALB_URL}" \
        -d "$data" \
        "http://${ALB_URL}${API_PATH}/cart")
        
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | sed '$d')
    
    if [[ $http_code == 2* ]]; then
        log "SUCCESS" "Request successful: $http_code"
        #log "DEBUG" "Response: $response_body"
    else
        log "ERROR" "Request failed: $http_code"
    fi
}

# High load function (10 requests per second)
high_load() {
    log "INFO" "Switching to high load mode (10 requests/second)"
    local end_time=$((SECONDS + 60))  # Run for 60 seconds
    
    while [ $SECONDS -lt $end_time ]; do
        for i in {1..10}; do  # Send 10 requests in parallel
            send_request &
        done
        wait  # Wait for all requests to complete
        sleep 1  # Wait 1 second before next batch
    done
}

# Normal load function (1 request per second)
normal_load() {
    log "INFO" "Switching to normal load mode (1 request/second)"
    local end_time=$((SECONDS + 60))  # Run for 60 seconds
    
    while [ $SECONDS -lt $end_time ]; do
        send_request
        sleep 1
    done
}

# Main loop
log "INFO" "Starting load generator"
log "INFO" "ALB URL: $ALB_URL"
log "INFO" "API Path: $API_PATH"

while true; do
    high_load   # Run high load for 1 minute
    normal_load # Run normal load for 1 minute
done
