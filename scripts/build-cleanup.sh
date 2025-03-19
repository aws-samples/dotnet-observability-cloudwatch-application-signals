#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Print colorized message
print_message() {
    echo -e "${1}${2}${NC}"
}

# Load configuration
load_configuration() {
    if [ ! -f .cluster-config/cluster-resources.json ]; then
        print_message "$RED" "Cluster configuration not found. Please run create-env.sh first."
        exit 1
    fi

    CLUSTER_NAME=$(jq -r '.cluster.name' .cluster-config/cluster-resources.json)
    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' .cluster-config/cluster-resources.json)

    print_message "$GREEN" "Configuration loaded: Cluster=${CLUSTER_NAME}, Region=${AWS_REGION}"
}

# Remove Kubernetes resources
remove_k8s_resources() {
    print_message "$YELLOW" "Starting Kubernetes resource cleanup..."

    # First, delete deployments and services
    print_message "$YELLOW" "Removing deployments and services..."
    kubectl delete deployment dotnet-cart-api dotnet-delivery-api --ignore-not-found=true
    kubectl delete service cart-api-service delivery-api-service --ignore-not-found=true

    # Get ingress details before deletion
    local alb_hostname=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # Delete ingress with timeout
    if [ -n "$alb_hostname" ]; then
        print_message "$YELLOW" "Deleting ALB ingress (this might take a few minutes)..."
        kubectl delete ingress apps-ingress --ignore-not-found=true
        print_message "$YELLOW" "ALB ($alb_hostname) deletion initiated"
    fi

    print_message "$GREEN" "Kubernetes resources removal initiated"
    print_message "$YELLOW" "Note: ALB deletion will continue in the background"
}

# Remove ECR repositories
remove_ecr_repos() {
    print_message "$YELLOW" "Removing ECR repositories..."
    
    for repo in "simple-cart-api" "simple-delivery-api"; do
        aws ecr delete-repository \
            --repository-name "$repo" \
            --force \
            --region "$AWS_REGION" \
            --no-cli-pager 2>/dev/null || true
    done
    
    print_message "$GREEN" "ECR repositories removed"
}

# Remove local Docker images
remove_docker_images() {
    print_message "$YELLOW" "Removing local Docker images..."
    
    # Remove specific images
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    docker image rm -f \
        "$ecr_url/simple-cart-api:latest" \
        "$ecr_url/simple-delivery-api:latest" 2>/dev/null || true
    
    # Clean up build cache
    docker builder prune -f >/dev/null 2>&1 || true
    
    print_message "$GREEN" "Local Docker images cleaned up"
}

# Remove local files
remove_local_files() {
    print_message "$YELLOW" "Removing local files..."
    rm -rf kubernetes *.tmp
    print_message "$GREEN" "Local files removed"
}

# Print cleanup summary
print_summary() {
    print_message "$GREEN" "\n=== Cleanup Summary ==="
    print_message "$GREEN" "✓ Kubernetes deployments and services removed"
    print_message "$GREEN" "✓ ALB ingress deletion initiated"
    print_message "$GREEN" "✓ ECR repositories removed"
    print_message "$GREEN" "✓ Local Docker images cleaned"
    print_message "$GREEN" "✓ Local files removed"
    print_message "$YELLOW" "\nNote: The ALB deletion may take a few minutes to complete in AWS."
    print_message "$YELLOW" "You can check the status in AWS Console → EC2 → Load Balancers."
}

# Main cleanup function
main() {
    print_message "$YELLOW" "Starting cleanup process..."
    
    load_configuration
    remove_k8s_resources
    remove_ecr_repos
    remove_docker_images
    remove_local_files
    print_summary
    
    print_message "$GREEN" "Cleanup completed successfully"
}

# Run main function
main
