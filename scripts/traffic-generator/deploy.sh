#!/bin/bash
set -eo pipefail

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"  

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

# Load configuration
load_configuration() {
    local config_file="${PROJECT_ROOT}/.cluster-config/cluster-resources.json"
    
    if [[ ! -f $config_file ]]; then
        handle_error "Cluster configuration not found at: $config_file. Run create-eks-env.sh first."
    fi

    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' "$config_file")
    AWS_REGION=$(jq -r '.cluster.region' "$config_file")
    CLUSTER_NAME=$(jq -r '.cluster.name' "$config_file")

    if [[ -z $AWS_ACCOUNT_ID || -z $AWS_REGION || -z $CLUSTER_NAME ]]; then
        handle_error "Failed to load configuration"
    fi

    log "INFO" "Configuration loaded:"
    log "INFO" "Cluster: $CLUSTER_NAME"
    log "INFO" "Region: $AWS_REGION"
    log "INFO" "Account: $AWS_ACCOUNT_ID"
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    local required_tools="docker kubectl aws jq"
    local missing_tools=()

    for tool in $required_tools; do
        if ! command -v $tool &>/dev/null; then
            missing_tools+=($tool)
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        handle_error "Missing required tools: ${missing_tools[*]}"
    fi

    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        handle_error "AWS CLI is not configured properly"
    fi

    log "SUCCESS" "Prerequisites check passed"
}

# Build and push Docker image
build_and_push() {
    log "INFO" "Building traffic generator image..."

    # Change to the traffic-generator directory
    cd "${SCRIPT_DIR}"

    # Create ECR repository if it doesn't exist
    if ! aws ecr describe-repositories --repository-names "traffic-generator" --region "$AWS_REGION" &>/dev/null; then
        log "INFO" "Creating ECR repository..."
        aws ecr create-repository --repository-name "traffic-generator" --region "$AWS_REGION"
    fi

    # Login to ECR
    log "INFO" "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    # Build image with platform specification
    log "INFO" "Building Docker image..."
    docker build -t traffic-generator:latest \
        --platform linux/amd64 \
        --no-cache \
        .

    # Tag and push
    log "INFO" "Pushing image to ECR..."
    docker tag traffic-generator:latest "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/traffic-generator:latest"
    docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/traffic-generator:latest"

    log "SUCCESS" "Image built and pushed successfully"
}


# Create ConfigMap with ALB URL
create_alb_config() {
    log "INFO" "Creating ALB ConfigMap..."
    
    local max_attempts=30
    local attempt=1
    local alb_url=""
    
    while [ $attempt -le $max_attempts ]; do
        alb_url=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "$alb_url" ]; then
            break
        fi
        log "INFO" "Waiting for ALB URL... (Attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    done
    
    if [ -z "$alb_url" ]; then
        handle_error "Failed to get ALB URL"
    fi
    
    kubectl create configmap alb-config \
        --from-literal=url="$alb_url" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log "SUCCESS" "ALB ConfigMap created with URL: $alb_url"
}

# Deploy traffic generator
deploy() {
    log "INFO" "Deploying traffic generator..."
    
    local deployment_file="${SCRIPT_DIR}/deployment.yaml"
    
    if [[ ! -f $deployment_file ]]; then
        handle_error "Deployment file not found at: $deployment_file"
    fi
    
    # Create temp file with substituted values
    local temp_file=$(mktemp)
    sed "s/ACCOUNT_ID_PLACEHOLDER/${AWS_ACCOUNT_ID}/g; s/REGION_PLACEHOLDER/${AWS_REGION}/g" \
        "$deployment_file" > "$temp_file"
    
    # Apply the deployment
    kubectl apply -f "$temp_file"
    
    # Clean up temp file
    rm -f "$temp_file"
    
    # Wait for deployment
    log "INFO" "Waiting for deployment..."
    kubectl rollout status deployment/traffic-generator
    
    log "SUCCESS" "Traffic generator deployed successfully"
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --help)
                log "INFO" "Usage: $0 [--skip-build]"
                log "INFO" "  --skip-build : Skip building and pushing Docker image"
                log "INFO" "  --help      : Show this help message"
                exit 0
                ;;
            *)
                handle_error "Unknown argument: $1"
                ;;
        esac
    done
}

# Main execution
main() {
    log "INFO" "Starting traffic generator deployment..."
    
    check_prerequisites
    load_configuration
    
    if [[ "$SKIP_BUILD" != "true" ]]; then
        build_and_push
    else
        log "INFO" "Skipping build phase"
    fi
    
    create_alb_config
    deploy
    
    log "SUCCESS" "Traffic generator setup completed"
    log "INFO" "To view logs: kubectl logs -f deployment/traffic-generator"
}

# Parse arguments and run main
parse_args "$@"
main
