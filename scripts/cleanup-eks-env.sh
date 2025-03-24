#!/bin/bash
set -eo pipefail

# Colors and logging
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
trap 'log ERROR "Error occurred on line $LINENO"' ERR

# Check prerequisites
check_prerequisites() {
    log INFO "Checking prerequisites..."
    local required_tools="aws kubectl eksctl jq helm"
    local missing_tools=()

    for tool in $required_tools; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log ERROR "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
}

# Load configuration
read_cluster_config() {
    log INFO "Loading cluster configuration..."
    local config_file=".cluster-config/cluster-resources.json"
    
    if [[ ! -f $config_file ]]; then
        log ERROR "Configuration file not found. Nothing to clean up."
        exit 1
    fi

    RESOURCE_ID=$(jq -r '.id // empty' "$config_file")
    CLUSTER_NAME=$(jq -r '.cluster.name // empty' "$config_file")
    AWS_REGION=$(jq -r '.cluster.region // empty' "$config_file")
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id // empty' "$config_file")
    DYNAMODB_TABLE_NAME=$(jq -r '.resources.dynamodb_table // empty' "$config_file")
    CART_SERVICE_ACCOUNT=$(jq -r '.resources.cart_service_account // empty' "$config_file")
    DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.delivery_service_account // empty' "$config_file")

    if [[ -z $CLUSTER_NAME || -z $AWS_REGION || -z $AWS_ACCOUNT_ID ]]; then
        log ERROR "Missing required configuration values"
        exit 1
    fi

    log INFO "Configuration loaded for cluster: $CLUSTER_NAME"
}

# Delete AWS Load Balancer Controller
delete_alb_controller() {
    log INFO "Removing AWS Load Balancer Controller..."
    
    # Uninstall ALB Controller
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
    
    # Delete ALB Controller Policy
    local ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
    aws iam delete-policy \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ALB_POLICY_NAME}" 2>/dev/null || true
    
    log SUCCESS "AWS Load Balancer Controller removed"
}

# Delete cert-manager
delete_cert_manager() {
    log INFO "Removing cert-manager..."
    kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml 2>/dev/null || true
    log SUCCESS "cert-manager removed"
}

# Delete CloudWatch resources
delete_cloudwatch_resources() {
    log INFO "Removing CloudWatch resources..."
    
    # Delete CloudWatch addon
    aws eks delete-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name amazon-cloudwatch-observability \
        --region "${AWS_REGION}" 2>/dev/null || true
    
    # Delete CloudWatch namespace
    kubectl delete namespace amazon-cloudwatch --ignore-not-found || true
    
    # Delete service-linked role
    aws iam delete-service-linked-role \
        --role-name AWSServiceRoleForApplicationSignals 2>/dev/null || true
    
    log SUCCESS "CloudWatch resources removed"
}

# Delete CloudWatch log groups
delete_cloudwatch_logs() {
    log "INFO" "Removing CloudWatch log groups..."
    
    local log_groups=(
        "/aws/containerinsights/${CLUSTER_NAME}/application"
        "/aws/containerinsights/${CLUSTER_NAME}/dataplane"
        "/aws/containerinsights/${CLUSTER_NAME}/performance"
    )
    
    for log_group in "${log_groups[@]}"; do
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$AWS_REGION" --query 'logGroups[].logGroupName' --output text &>/dev/null; then
            log "INFO" "Deleting log group: $log_group"
            aws logs delete-log-group \
                --log-group-name "$log_group" \
                --region "$AWS_REGION" || true
        else
            log "INFO" "Log group not found: $log_group"
        fi
    done
    
    log "SUCCESS" "CloudWatch log groups cleanup completed"
}

# Delete service accounts
delete_service_accounts() {
    log INFO "Removing service accounts..."
    
    local service_accounts=(
        "default/${CART_SERVICE_ACCOUNT}"
        "default/${DELIVERY_SERVICE_ACCOUNT}"
        "kube-system/aws-load-balancer-controller"
        "amazon-cloudwatch/cloudwatch-agent"
    )

    for sa in "${service_accounts[@]}"; do
        IFS='/' read -r namespace account <<< "$sa"
        eksctl delete iamserviceaccount \
            --cluster="${CLUSTER_NAME}" \
            --namespace="$namespace" \
            --name="$account" \
            --region "${AWS_REGION}" 2>/dev/null || true
    done
    
    log SUCCESS "Service accounts removed"
}

# Delete IAM policies
delete_iam_policies() {
    log INFO "Removing IAM policies..."
    
    local policies=(
        "${RESOURCE_ID}-cart-policy"
        "${RESOURCE_ID}-delivery-policy"
    )

    for policy in "${policies[@]}"; do
        aws iam delete-policy \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy}" 2>/dev/null || true
    done
    
    log SUCCESS "IAM policies removed"
}

# Delete DynamoDB table
delete_dynamodb_table() {
    log INFO "Removing DynamoDB table..."
    aws dynamodb delete-table \
        --table-name "${DYNAMODB_TABLE_NAME}" \
        --region "${AWS_REGION}" 2>/dev/null || true
    
    log SUCCESS "DynamoDB table removed"
}

# Delete EKS cluster
delete_eks_cluster() {
    log INFO "Deleting EKS cluster..."
    eksctl delete cluster \
        --name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --wait
    
    log SUCCESS "EKS cluster deleted"
}
# Remove local Docker images
remove_docker_images() {
    log "INFO" "Removing local Docker images..."
    
    # Remove specific images
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    docker image rm -f \
        "$ecr_url/simple-cart-api:latest" \
        "$ecr_url/simple-delivery-api:latest" 2>/dev/null || true
    
    # Clean up build cache
    log "INFO" "Cleaning Docker build cache..."
    docker builder prune -f >/dev/null 2>&1 || true
    
    log "SUCCESS" "Local Docker images cleaned up"
}
# Remove ECR repositories
remove_ecr_repos() {
    log "INFO" "Removing ECR repositories..."
    
    for repo in "simple-cart-api" "simple-delivery-api"; do
        log "INFO" "Removing repository: $repo"
        aws ecr delete-repository \
            --repository-name "$repo" \
            --force \
            --region "$AWS_REGION" \
            --no-cli-pager 2>/dev/null || true
    done
    
    log "SUCCESS" "ECR repositories removed"
}

# Clean up local files
cleanup_local_files() {
    log INFO "Cleaning up local files..."
    rm -rf .cluster-config kubernetes cluster.yaml *.json *tmp
    log SUCCESS "Local files cleaned up"
}

# Confirm cleanup
confirm_cleanup() {
    log WARNING "WARNING: This will delete all resources created by create-eks-env.sh"
    log WARNING "This action cannot be undone!"
    log WARNING "Are you sure you want to continue? (y/N)"
    
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log INFO "Cleanup cancelled"
        exit 0
    fi
}

# Print summary
print_summary() {
    log SUCCESS "\n====================================="
    log SUCCESS "Cleanup completed successfully!"
    log SUCCESS "====================================="
    log INFO "\nThe following resources were removed:"
    log INFO "  - EKS Cluster: ${CLUSTER_NAME}"
    log INFO "  - DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
    log INFO "  - IAM Policies and Service Accounts"
    log INFO "  - AWS Load Balancer Controller"
    log INFO "  - cert-manager"
    log INFO "  - CloudWatch Observability resources"
    log INFO "  - Local configuration files"
}

# Main execution
main() {
    log INFO "Starting cleanup process..."
    
    check_prerequisites
    read_cluster_config
    confirm_cleanup
    
    # Delete resources in reverse order of creation
    delete_alb_controller
    delete_cert_manager
    delete_cloudwatch_resources
    delete_cloudwatch_logs
    delete_service_accounts
    delete_iam_policies
    delete_dynamodb_table
    remove_docker_images
    remove_ecr_repos
    delete_eks_cluster
    cleanup_local_files
    
    print_summary
}

# Execute main function
main
