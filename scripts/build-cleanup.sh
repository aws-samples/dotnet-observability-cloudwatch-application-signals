#!/bin/bash
set -eo pipefail

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
DEBUG_COLOR='\033[0;37m'
NO_COLOR='\033[0m'

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
    local required_tools="aws kubectl docker jq"
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

# Load configuration
load_configuration() {
    local config_file=".cluster-config/cluster-resources.json"
    
    if [ ! -f "$config_file" ]; then
        handle_error "Cluster configuration not found. Please run create-eks-env.sh first."
    fi

    log "INFO" "Loading configuration..."
    
    CLUSTER_NAME=$(jq -r '.cluster.name // empty' "$config_file")
    AWS_REGION=$(jq -r '.cluster.region // empty' "$config_file")
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id // empty' "$config_file")

    if [[ -z $CLUSTER_NAME || -z $AWS_REGION || -z $AWS_ACCOUNT_ID ]]; then
        handle_error "Invalid configuration in $config_file"
    fi

    log "SUCCESS" "Configuration loaded successfully"
    log "INFO" "Cluster: $CLUSTER_NAME"
    log "INFO" "Region: $AWS_REGION"
}

# Remove Kubernetes resources
remove_k8s_resources() {
    log "INFO" "Starting Kubernetes resource cleanup..."

    # Delete deployments and services
    log "INFO" "Removing deployments and services..."
    kubectl delete deployment dotnet-cart-api dotnet-delivery-api traffic-generator --ignore-not-found=true
    kubectl delete service cart-api-service delivery-api-service --ignore-not-found=true
    log "SUCCESS" "Deployments and services removed"

    # Get ingress details before deletion
    local alb_hostname=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # Delete ingress with timeout
    if [ -n "$alb_hostname" ]; then
        log "INFO" "Deleting ALB ingress (this might take a few minutes)..."
        kubectl delete ingress apps-ingress --ignore-not-found=true
        log "INFO" "ALB ($alb_hostname) deletion initiated"
    else
        log "INFO" "No ALB ingress found"
    fi

    log "SUCCESS" "Kubernetes resources removal completed"
}

# Remove ECR repositories
remove_ecr_repos() {
    log "INFO" "Removing ECR repositories..."
    
    for repo in "simple-cart-api" "simple-delivery-api" "traffic-generator"; do
        log "INFO" "Removing repository: $repo"
        aws ecr delete-repository \
            --repository-name "$repo" \
            --force \
            --region "$AWS_REGION" \
            --no-cli-pager 2>/dev/null || true
    done
    
    log "SUCCESS" "ECR repositories removed"
}

# Remove local Docker images
remove_docker_images() {
    log "INFO" "Removing local Docker images..."
    
    # Remove specific images
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    docker image rm -f \
        "$ecr_url/simple-cart-api:latest" \
        "$ecr_url/trafic-generator:latest"
        "$ecr_url/simple-delivery-api:latest" 2>/dev/null || true
    
    # Clean up build cache
    log "INFO" "Cleaning Docker build cache..."
    docker builder prune -f >/dev/null 2>&1 || true
    
    log "SUCCESS" "Local Docker images cleaned up"
}

# Remove local files
remove_local_files() {
    log "INFO" "Removing local files..."
    rm -rf kubernetes *.tmp
    log "SUCCESS" "Local files removed"
}

# Confirm cleanup
confirm_cleanup() {
    log "WARNING" "This will remove all application resources and local files."
    log "WARNING" "This action cannot be undone!"
    log "WARNING" "Are you sure you want to continue? (y/N)"
    
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "INFO" "Cleanup cancelled"
        exit 0
    fi
}

# Print cleanup summary
print_summary() {
    log "SUCCESS" "\n====================================="
    log "SUCCESS" "Cleanup Summary"
    log "SUCCESS" "====================================="
    log "INFO" "The following items were cleaned up:"
    log "INFO" "✓ Kubernetes deployments and services"
    log "INFO" "✓ ALB ingress"
    log "INFO" "✓ ECR repositories"
    log "INFO" "✓ Local Docker images"
    log "INFO" "✓ Local files"
    log "WARNING" "\nNote: ALB deletion may take a few minutes to complete in AWS."
    log "WARNING" "You can check the status in AWS Console → EC2 → Load Balancers."
}

# Main execution
log "INFO" "Starting application cleanup process..."

check_prerequisites
load_configuration
confirm_cleanup

remove_k8s_resources
remove_ecr_repos
remove_docker_images
remove_local_files

print_summary
log "SUCCESS" "Cleanup completed successfully"
