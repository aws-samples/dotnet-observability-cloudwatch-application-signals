#!/bin/bash
set -eo pipefail

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
DEBUG_COLOR='\033[0;37m'
NO_COLOR='\033[0m'

# Global variables
declare AWS_ACCOUNT_ID
declare AWS_REGION
declare SKIP_BUILD

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

# Load configuration
load_configuration() {
    if [ ! -f .cluster-config/cluster-resources.json ]; then
        handle_error "Cluster configuration not found. Please run create-eks-env.sh first."
    fi

    log "INFO" "Loading configuration..."
    
    # Extract configuration values using the correct JSON paths
    CLUSTER_NAME=$(jq -r '.cluster.name // empty' .cluster-config/cluster-resources.json)
    AWS_REGION=$(jq -r '.cluster.region // empty' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id // empty' .cluster-config/cluster-resources.json)
    DYNAMODB_TABLE_NAME=$(jq -r '.resources.dynamodb_table // empty' .cluster-config/cluster-resources.json)
    CART_SERVICE_ACCOUNT=$(jq -r '.resources.cart_service_account // empty' .cluster-config/cluster-resources.json)
    DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.delivery_service_account // empty' .cluster-config/cluster-resources.json)

    # Validate configuration
    if [ -z "$CLUSTER_NAME" ] || [ "$CLUSTER_NAME" = "null" ] || \
       [ -z "$AWS_REGION" ] || [ "$AWS_REGION" = "null" ] || \
       [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" = "null" ] || \
       [ -z "$DYNAMODB_TABLE_NAME" ] || [ "$DYNAMODB_TABLE_NAME" = "null" ]; then
        handle_error "Invalid configuration. Please run create-eks-env.sh to recreate the environment."
    fi

    log "SUCCESS" "Configuration loaded successfully"
    log "INFO" "Cluster Name: $CLUSTER_NAME"
    log "INFO" "AWS Region: $AWS_REGION"
    log "INFO" "DynamoDB Table: $DYNAMODB_TABLE_NAME"
}

# Create ECR repositories
create_ecr_repos() {
    log "INFO" "Creating ECR repositories..."
    
    for repo in "simple-cart-api" "simple-delivery-api"; do
        if ! aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" --no-cli-pager 2>/dev/null; then
            aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" --no-cli-pager
            log "SUCCESS" "Created ECR repository: $repo"
        else
            log "INFO" "ECR repository already exists: $repo"
        fi
    done
}

# Log in to ECR
ecr_login() {
    log "INFO" "Logging in to ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    log "SUCCESS" "Successfully logged in to ECR"
}

# Build and push Docker images
build_and_push_images() {
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    # Clean Docker system
    log "INFO" "Cleaning Docker system..."
    docker system prune -f

    # Build and push Cart API
    log "INFO" "Building and pushing Cart API..."
    cd src/apps/Simple.CartApi
    if ! docker build --no-cache --platform linux/amd64 -t simple-cart-api:latest .; then
        cd ../../..
        handle_error "Failed to build Cart API"
    fi
    docker tag simple-cart-api:latest $ecr_url/simple-cart-api:latest
    docker push $ecr_url/simple-cart-api:latest
    cd ../../..
    log "SUCCESS" "Cart API image pushed successfully"

    # Build and push Delivery API
    log "INFO" "Building and pushing Delivery API..."
    cd src/apps/Simple.DeliveryApi
    if ! docker build --no-cache --platform linux/amd64 -t simple-delivery-api:latest .; then
        cd ../../..
        handle_error "Failed to build Delivery API"
    fi
    docker tag simple-delivery-api:latest $ecr_url/simple-delivery-api:latest
    docker push $ecr_url/simple-delivery-api:latest
    cd ../../..
    log "SUCCESS" "Delivery API image pushed successfully"
}

# Verify service account exists
verify_service_accounts() {
    log "INFO" "Verifying service accounts..."
    
    if ! kubectl get serviceaccount ${CART_SERVICE_ACCOUNT} &>/dev/null; then
        handle_error "Cart API service account not found. Please run create-eks-env.sh first."
    fi
    
    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT} &>/dev/null; then
        handle_error "Delivery API service account not found. Please run create-eks-env.sh first."
    fi
    
    log "SUCCESS" "Service accounts verified successfully"
}

# Create Kubernetes deployment files
create_k8s_files() {
    log "INFO" "Creating Kubernetes deployment files..."
    mkdir -p kubernetes

    # Create Delivery API deployment
    cat <<EOF > kubernetes/delivery-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dotnet-delivery-api
  labels:
    app: dotnet-delivery-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dotnet-delivery-api
  template:
    metadata:
      labels:
        app: dotnet-delivery-api
    spec:
      serviceAccountName: ${DELIVERY_SERVICE_ACCOUNT}
      containers:
      - name: dotnet-delivery-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/simple-delivery-api:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1024Mi
        env:
        - name: ASPNETCORE_ENVIRONMENT
          value: "Development"
        - name: ASPNETCORE_URLS
          value: "http://+:8080"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
EOF

    # Create Cart API deployment
    cat <<EOF > kubernetes/cart-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dotnet-cart-api
  labels:
    app: dotnet-cart-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dotnet-cart-api
  template:
    metadata:
      labels:
        app: dotnet-cart-api
    spec:
      serviceAccountName: ${CART_SERVICE_ACCOUNT}
      containers:
      - name: dotnet-cart-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/simple-cart-api:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1024Mi
        env:
        - name: ASPNETCORE_ENVIRONMENT
          value: "Development"
        - name: ASPNETCORE_URLS
          value: "http://+:8080"
        - name: BACKEND_URL
          value: "http://dotnet-delivery-api"
        - name: AWS_REGION
          value: "${AWS_REGION}"
        - name: DYNAMODB_TABLE_NAME
          value: "${DYNAMODB_TABLE_NAME}"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
EOF

    # Create Cart API service
    cat <<EOF > kubernetes/cart-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: dotnet-cart-api
spec:
  selector:
    app: dotnet-cart-api
  ports:
    - name: http-8080
      protocol: TCP
      port: 8080
      targetPort: 8080
  type: ClusterIP
EOF

    # Create Delivery API service
    cat <<EOF > kubernetes/delivery-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: dotnet-delivery-api
spec:
  selector:
    app: dotnet-delivery-api
  ports:
    - name: http-8080
      protocol: TCP
      port: 80
      targetPort: 8080
  type: ClusterIP
EOF

# Create Ingress
cat <<EOF > kubernetes/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apps-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /apps/cart
        pathType: Prefix
        backend:
          service:
            name: dotnet-cart-api
            port:
              number: 8080
      - path: /apps/delivery
        pathType: Prefix
        backend:
          service:
            name: dotnet-delivery-api
            port:
              number: 80
EOF

    log "SUCCESS" "Kubernetes deployment files created"
}

# Restart deployments
restart_deployments() {
    log "INFO" "Restarting deployments..."
    
    kubectl rollout restart deployment dotnet-cart-api
    kubectl rollout restart deployment dotnet-delivery-api
    
    kubectl rollout status deployment dotnet-cart-api
    kubectl rollout status deployment dotnet-delivery-api
    
    log "SUCCESS" "Deployments restarted successfully"
}

# Deploy to Kubernetes
# Deploy to Kubernetes
deploy_to_k8s() {
    log "INFO" "Deploying to Kubernetes..."
    
    # Delete existing deployments and wait for complete removal
    log "INFO" "Removing existing deployments..."
    kubectl delete deployment dotnet-cart-api dotnet-delivery-api --ignore-not-found=true
    kubectl delete service dotnet-cart-api dotnet-delivery-api --ignore-not-found=true
    
    # Wait for resources to be fully deleted
    log "INFO" "Waiting for resources to be removed..."
    while true; do
        if ! kubectl get deployment dotnet-cart-api 2>/dev/null && \
           ! kubectl get deployment dotnet-delivery-api 2>/dev/null && \
           ! kubectl get service dotnet-cart-api 2>/dev/null && \
           ! kubectl get service dotnet-delivery-api 2>/dev/null; then
            break
        fi
        log "INFO" "Waiting for resources to be removed..."
        sleep 5
    done
    
    log "SUCCESS" "Existing resources removed"
    
    # Apply all configurations at once
    log "INFO" "Applying configurations..."
    kubectl apply -f kubernetes/
    
    # Wait for deployments to be ready
    log "INFO" "Waiting for deployments to be ready..."
    kubectl rollout status deployment/dotnet-cart-api
    kubectl rollout status deployment/dotnet-delivery-api
    
    log "SUCCESS" "Kubernetes deployments completed"
}


# Verify deployment
verify_deployment() {
    log "INFO" "Verifying deployment..."
    local max_attempts=30
    local wait_seconds=10
    local deployments=("dotnet-cart-api" "dotnet-delivery-api")
    local all_ready=false

    for ((i=1; i<=max_attempts; i++)); do
        all_ready=true
        
        for deployment in "${deployments[@]}"; do
            ready_replicas=$(kubectl get deployment $deployment -o jsonpath='{.status.readyReplicas}')
            total_replicas=$(kubectl get deployment $deployment -o jsonpath='{.status.replicas}')
            
            if [ "$ready_replicas" != "$total_replicas" ]; then
                all_ready=false
                log "INFO" "Waiting for $deployment to be ready ($ready_replicas/$total_replicas)..."
                break
            fi
        done
        
        if $all_ready; then
            log "SUCCESS" "All deployments are ready!"
            break
        fi
        
        if [ $i -eq $max_attempts ]; then
            handle_error "Deployment verification timed out"
        fi
        
        sleep $wait_seconds
    done

    log "SUCCESS" "Deployment verification completed"
}

# Print deployment summary
print_deployment_summary() {
    log "INFO" "Getting deployment summary..."
    
    # Get ALB endpoint
    ALB_ENDPOINT=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    # Print summary
    log "SUCCESS" "\n====================================="
    log "SUCCESS" "Deployment Summary"
    log "SUCCESS" "====================================="
    log "INFO" "Application URL: http://${ALB_ENDPOINT}"
    log "INFO" "Cart API Path: /apps/cart"
    log "INFO" "Delivery API Path: /apps/delivery"
    log "WARNING" "Note: It may take a few minutes for the ALB to become available"
}

# Validate AWS region
validate_aws_region() {
    if ! aws ec2 describe-regions --region "$AWS_REGION" &>/dev/null; then
        handle_error "Invalid AWS region: $AWS_REGION"
    fi
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    # Check required commands
    local required_commands=("aws" "kubectl" "docker" "jq")
    local missing_commands=()

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        handle_error "Required tools not installed: ${missing_commands[*]}"
    fi
    
    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        handle_error "AWS CLI is not configured properly"
    fi
    
    # Check Docker daemon
    if ! docker info &>/dev/null; then
        handle_error "Docker daemon is not running"
    fi
    
    # Check kubectl configuration
    if ! kubectl cluster-info &>/dev/null; then
        handle_error "kubectl is not configured properly"
    fi

    # Check AWS Load Balancer Controller
    if ! kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
        handle_error "AWS Load Balancer Controller is not installed. Please install it first."
    fi

    log "SUCCESS" "Prerequisites check passed"
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --help)
                log "INFO" "Usage: $0 [--region AWS_REGION] [--skip-build]"
                log "INFO" "  --region     : AWS region (default: from cluster config)"
                log "INFO" "  --skip-build : Skip building and pushing Docker images"
                log "INFO" "  --help       : Show this help message"
                exit 0
                ;;
            *)
                handle_error "Unknown parameter: $1"
                ;;
        esac
    done
}

# Deploy applications
deploy_applications() {
    check_prerequisites
    load_configuration
    
    # Override region if provided via command line
    if [ ! -z "$1" ] && [ "$AWS_REGION" != "$1" ]; then
        AWS_REGION="$1"
        validate_aws_region
        log "INFO" "Using provided AWS region: $AWS_REGION"
    fi
    
    verify_service_accounts
    
    if [ "$SKIP_BUILD" != "true" ]; then
        create_ecr_repos
        ecr_login
        build_and_push_images
    else
        log "INFO" "Skipping build and push of Docker images"
    fi
    
    create_k8s_files
    deploy_to_k8s
    verify_deployment
    print_deployment_summary



   # Add delay before deploying traffic generator
    log "INFO" "Waiting 10 seconds for ALB to be fully available..."
    sleep 10
    
    # Deploy traffic generator
    log "INFO" "Deploying traffic generator..."
    if ! (cd ./scripts/traffic-generator && ./deploy.sh); then
        log "WARNING" "Traffic generator deployment failed"
        return 1
    fi
    
    # Show traffic generator status
    log "INFO" "Traffic Generator Status:"
    kubectl get pods -l app=traffic-generator -o wide
    log "INFO" "To view traffic generator logs:"
    log "INFO" "kubectl logs -f deployment/traffic-generator" 
}

# Cleanup handler
cleanup() {
    if [ $? -ne 0 ]; then
        log "ERROR" "Deployment failed!"
        if [ ! -z "${AWS_REGION}" ]; then
            log "WARNING" "You may want to run cleanup-eks-env.sh to clean up resources"
        fi
    fi
}

# Main function
main() {
    trap cleanup EXIT
    parse_arguments "$@"
    deploy_applications "$AWS_REGION"
}

# Run main function
main "$@"