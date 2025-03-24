#!/bin/bash
set -eo pipefail

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
DEBUG_COLOR='\033[0;37m'
NO_COLOR='\033[0m'

# Initialize global variables
BATCH_SIZE=${BATCH_SIZE:-5}
CART_API_URL=""
STATS_INTERVAL=${STATS_INTERVAL:-60}
METRICS_FILE="/tmp/load_test_metrics.txt"

# Clear metrics file
> "$METRICS_FILE"

# Logging function
log() {
    local level=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    local message="$2"
    local color
    
    case $level in
        ERROR)   color=$ERROR_COLOR ;;
        SUCCESS) color=$SUCCESS_COLOR ;;
        WARNING) color=$WARNING_COLOR ;;
        INFO)    color=$INFO_COLOR ;;
        DEBUG)   color=$DEBUG_COLOR ;;
        *)       color=$INFO_COLOR ;;
    esac
    
    echo -e "${color}${level}: ${message}${NO_COLOR}"
}

# Error handling
handle_error() {
    log "ERROR" "$1"
    exit 1
}

trap 'handle_error "Error occurred on line $LINENO"' ERR

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    local required_tools="kubectl curl bc uuidgen"
    local missing_tools=()

    for tool in $required_tools; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        handle_error "Missing required tools: ${missing_tools[*]}"
    fi

    log "SUCCESS" "Prerequisites check passed"
}

# Check ALB health
check_alb_health() {
    if ! curl -s -f "http://${CART_API_URL}/apps/cart/healthz" &>/dev/null; then
        log "ERROR" "ALB health check failed"
        return 1
    fi
    log "DEBUG" "ALB health check passed"
    return 0
}

# Verify ingress configuration
verify_ingress() {
    log "INFO" "Verifying ingress configuration..."

    if ! kubectl get ingress apps-ingress &>/dev/null; then
        handle_error "Ingress 'apps-ingress' not found"
    fi

    local ingress_class=$(kubectl get ingress apps-ingress -o jsonpath='{.spec.ingressClassName}')
    if [ "$ingress_class" != "alb" ]; then
        handle_error "Ingress is not configured to use ALB"
    fi

    log "INFO" "Waiting for ALB address..."
    local max_attempts=12
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        ALB_ADDRESS=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        if [ -n "$ALB_ADDRESS" ]; then
            log "SUCCESS" "ALB address found: $ALB_ADDRESS"
            return 0
        fi
        log "INFO" "Waiting for ALB address... (Attempt $attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done

    handle_error "Timed out waiting for ALB address"
}

get_cart_api_url() {
    log "INFO" "Getting Cart API URL..."
    
    CART_API_URL=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$CART_API_URL" ]; then
        handle_error "Failed to get ALB URL. Is the ingress controller running?"
    fi

    log "INFO" "Testing ALB endpoint..."
    if curl -s -f "http://${CART_API_URL}/apps/cart/healthz" &>/dev/null; then
        log "SUCCESS" "ALB endpoint is accessible"
    else
        log "WARNING" "Waiting for ALB endpoint to become available..."
        sleep 10
    fi

    log "SUCCESS" "Cart API URL: $CART_API_URL"
}

# Send HTTP request
send_request() {
    local id=$1
    local start_time=$(date +%s.%N)
    
    # Generate IDs
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
    
    if [ "$success" = true ]; then
        echo "$id,$duration,$(date +%s),$http_code" >> "$METRICS_FILE"
        log "DEBUG" "Request $id successful: $http_code (duration: ${duration}s)"
    else
        log "ERROR" "Request $id failed with status $http_code (after $retry retries)"
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
        
        log "SUCCESS" "\n=== Performance Statistics (Last ${STATS_INTERVAL}s) ==="
        log "INFO" "Total Requests: $window_requests"
        log "INFO" "Successful Requests: $successful_requests"
        log "INFO" "Success Rate: ${success_rate}%"
        log "INFO" "Requests/second: $requests_per_second"
        log "INFO" "Average Response Time: ${avg_response_time}s"

        if check_alb_health; then
            log "SUCCESS" "ALB Status: Healthy"
        else
            log "WARNING" "ALB Status: Degraded"
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

# Cleanup handler
cleanup() {
    log "WARNING" "\nLoad test stopped"
    print_statistics
    log "INFO" "Final results saved to: $METRICS_FILE"
    exit 0
}

# Main execution
main() {
    log "INFO" "Starting load test with the following parameters:"
    log "INFO" "- Batch size: $BATCH_SIZE requests"
    log "INFO" "- Stats interval: $STATS_INTERVAL seconds"
    log "INFO" "- Auto-retry: 3 attempts"

    check_prerequisites
    verify_ingress
    get_cart_api_url

    # Initialize counters
    request_id=0
    last_stats_time=$SECONDS
    last_health_check=$SECONDS

    log "SUCCESS" "Load test starting. Press Ctrl+C to stop."

    while true; do
        current_time=$SECONDS
        
        # Periodic health check
        if ((current_time - last_health_check >= 30)); then
            if ! check_alb_health; then
                log "WARNING" "ALB health check failed, waiting for recovery..."
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

trap cleanup SIGINT SIGTERM

# Run main function
main
