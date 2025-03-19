#!/bin/bash

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize global variables
BATCH_SIZE=${BATCH_SIZE:-10}
CART_API_URL=""
STATS_INTERVAL=${STATS_INTERVAL:-60}
METRICS_FILE="/tmp/load_test_metrics.txt"

# Clear metrics file
> "$METRICS_FILE"

# Print colorized message
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Check ALB health
check_alb_health() {
    if ! curl -s -f "http://${CART_API_URL}/apps/cart/healthz" &>/dev/null; then
        print_message "$RED" "ALB health check failed"
        return 1
    fi
    return 0
}

# Verify ingress configuration
verify_ingress() {
    if ! kubectl get ingress apps-ingress &>/dev/null; then
        print_message "$RED" "Ingress 'apps-ingress' not found"
        exit 1
    fi

    # Check ingressClassName instead of annotation
    local ingress_class=$(kubectl get ingress apps-ingress -o jsonpath='{.spec.ingressClassName}')
    if [ "$ingress_class" != "alb" ]; then
        print_message "$RED" "Ingress is not configured to use ALB"
        exit 1
    fi

    # Wait for ALB address to be assigned
    print_message "$YELLOW" "Waiting for ALB address..."
    local max_attempts=12
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        ALB_ADDRESS=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        if [ -n "$ALB_ADDRESS" ]; then
            print_message "$GREEN" "ALB address found: $ALB_ADDRESS"
            return 0
        fi
        print_message "$YELLOW" "Waiting for ALB address... (Attempt $attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done

    print_message "$RED" "Timed out waiting for ALB address"
    exit 1
}


get_cart_api_url() {
    print_message "$YELLOW" "Getting Cart API URL..."
    
    if ! command -v kubectl &> /dev/null; then
        print_message "$RED" "kubectl is required but not installed"
        exit 1
    fi

    CART_API_URL=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$CART_API_URL" ]; then
        print_message "$RED" "Failed to get ALB URL. Is the ingress controller running?"
        exit 1
    fi

    # Test the endpoint
    print_message "$YELLOW" "Testing ALB endpoint..."
    if curl -s -f "http://${CART_API_URL}/apps/cart/healthz" &>/dev/null; then
        print_message "$GREEN" "ALB endpoint is accessible"
    else
        print_message "$YELLOW" "Waiting for ALB endpoint to become available..."
        sleep 10
    fi

    print_message "$GREEN" "ALB URL: $CART_API_URL"
}


# Send HTTP request
send_request() {
    local id=$1
    local start_time=$(date +%s.%N)
    
    # Generate cart ID and item ID
    local cart_id=$(uuidgen)
    local item_id=$(uuidgen)
    local product_id=$(uuidgen)
    
    # Create request payload
    local data="{
        \"id\": \"$cart_id\",
        \"items\": [{
            \"id\": \"$item_id\",
            \"name\": \"Test Book\",
            \"price\": 29.99,
            \"quantity\": 1,
            \"product\": {
                \"id\": \"$product_id\",
                \"title\": \"Test Book\",
                \"author\": \"Test Author\",
                \"year\": 2024
            }
        }]
    }"
    
    # Send POST request with retries
    local max_retries=3
    local retry=0
    local success=false
    
    while [ $retry -lt $max_retries ] && [ "$success" = false ]; do
        local response=$(curl -s -w "\n%{http_code}" \
            -H "Content-Type: application/json" \
            -H "Host: ${CART_API_URL}" \
            -d "$data" \
            "http://${CART_API_URL}/apps/cart/cart" 2>/dev/null)
        
        local http_code=$(echo "$response" | tail -n1)
        
        if [[ $http_code == 2* ]]; then
            success=true
        else
            ((retry++))
            if [ $retry -lt $max_retries ]; then
                sleep 1
            fi
        fi
    done
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Track metrics with minimal error reporting
    if [ "$success" = true ]; then
        echo "$id,$duration,$(date +%s),$http_code" >> "$METRICS_FILE"
        print_message "$GREEN" "Request $id successful: $http_code (duration: ${duration}s)"
    else
        print_message "$RED" "Request $id failed with status $http_code (after $retry retries). Check CloudWatch App Signals for details."
    fi
}


# Print statistics
print_statistics() {
    local current_time=$(date +%s)
    local window_start=$((current_time - STATS_INTERVAL))
    local window_requests=0
    local window_total_time=0
    local successful_requests=0
    
    while IFS=, read -r id duration timestamp status; do
        if [ "$timestamp" -ge "$window_start" ]; then
            ((window_requests++))
            window_total_time=$(echo "$window_total_time + $duration" | bc)
            if [[ $status == 2* ]]; then
                ((successful_requests++))
            fi
        fi
    done < "$METRICS_FILE"
    
    if [ "$window_requests" -gt 0 ]; then
        local avg_response_time=$(echo "scale=3; $window_total_time / $window_requests" | bc)
        local requests_per_second=$(echo "scale=2; $window_requests / $STATS_INTERVAL" | bc)
        local success_rate=$(echo "scale=2; $successful_requests * 100 / $window_requests" | bc)
        
        print_message "$GREEN" "\nLast ${STATS_INTERVAL} seconds statistics:"
        print_message "$GREEN" "Total Requests: $window_requests"
        print_message "$GREEN" "Successful Requests: $successful_requests"
        print_message "$GREEN" "Success Rate: ${success_rate}%"
        print_message "$GREEN" "Requests/second: $requests_per_second"
        print_message "$GREEN" "Average Response Time: ${avg_response_time}s"

        # Add ALB status check
        if check_alb_health; then
            print_message "$GREEN" "ALB Status: Healthy"
        else
            print_message "$YELLOW" "ALB Status: Degraded"
        fi
    fi
    
    # Clean up old entries
    tmp_file=$(mktemp)
    while IFS=, read -r id duration timestamp status; do
        if [ "$timestamp" -ge "$window_start" ]; then
            echo "$id,$duration,$timestamp,$status" >> "$tmp_file"
        fi
    done < "$METRICS_FILE"
    mv "$tmp_file" "$METRICS_FILE"
}

# Main execution
main() {
    print_message "$YELLOW" "Starting load generator..."
    print_message "$YELLOW" "Batch size: $BATCH_SIZE requests"
    print_message "$YELLOW" "Stats interval: $STATS_INTERVAL seconds"
    print_message "$YELLOW" "Auto-retry: 3 attempts"

    verify_ingress
    get_cart_api_url

    # Initialize counters
    request_id=0
    last_stats_time=$SECONDS
    last_health_check=$SECONDS

    print_message "$GREEN" "Load test starting. Press Ctrl+C to stop."

    while true; do
        current_time=$SECONDS
        
        # Periodic health check
        if ((current_time - last_health_check >= 30)); then
            if ! check_alb_health; then
                print_message "$RED" "ALB health check failed, waiting for recovery..."
                sleep 5
                continue
            fi
            last_health_check=$current_time
        fi

        for ((i=1; i<=BATCH_SIZE; i++)); do
            send_request $request_id &
            ((request_id++))
        done
        
        wait
        
        if ((current_time - last_stats_time >= STATS_INTERVAL)); then
            print_statistics
            last_stats_time=$current_time
        fi
        
        sleep 1
    done
}

# Handle script interruption
cleanup() {
    print_message "$YELLOW" "\nLoad test stopped."
    print_statistics
    print_message "$GREEN" "Final results saved to: $METRICS_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Run main function
main
