#!/bin/bash

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Global variables
declare AWS_ACCOUNT_ID
declare AWS_REGION
declare SKIP_BUILD

# Print colorized message
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Handle errors
handle_error() {
    print_message "$RED" "$1"
    exit 1
}

# Load configuration
load_configuration() {
    if [ ! -f .cluster-config/cluster-resources.json ]; then
        handle_error "Cluster configuration not found. Please run create-eks-env.sh first."
    fi

    print_message "$YELLOW" "Loading configuration..."
    
    # Extract configuration values using the correct JSON paths
    CLUSTER_NAME=$(jq -r '.cluster.name' .cluster-config/cluster-resources.json)
    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' .cluster-config/cluster-resources.json)
    DYNAMODB_TABLE_NAME=$(jq -r '.resources.dynamodb_table' .cluster-config/cluster-resources.json)
    CART_SERVICE_ACCOUNT=$(jq -r '.resources.cart_service_account' .cluster-config/cluster-resources.json)
    DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.delivery_service_account' .cluster-config/cluster-resources.json)

    # Validate configuration
    if [ -z "$CLUSTER_NAME" ] || [ "$CLUSTER_NAME" = "null" ] || \
       [ -z "$AWS_REGION" ] || [ "$AWS_REGION" = "null" ] || \
       [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" = "null" ] || \
       [ -z "$DYNAMODB_TABLE_NAME" ] || [ "$DYNAMODB_TABLE_NAME" = "null" ]; then
        handle_error "Invalid configuration. Please run create-eks-env.sh to recreate the environment."
    fi

    print_message "$GREEN" "Configuration loaded successfully"
    print_message "$GREEN" "Cluster Name: $CLUSTER_NAME"
    print_message "$GREEN" "AWS Region: $AWS_REGION"
    print_message "$GREEN" "DynamoDB Table: $DYNAMODB_TABLE_NAME"
}

# Create ECR repositories
create_ecr_repos() {
    print_message "$YELLOW" "Creating ECR repositories..."
    
    for repo in "simple-cart-api" "simple-delivery-api"; do
        if ! aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" --no-cli-pager 2>/dev/null; then
            aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" --no-cli-pager
        fi
    done
}

# Log in to ECR
ecr_login() {
    print_message "$YELLOW" "Logging in to ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
}

# Build and push Docker images
build_and_push_images() {
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    # Clean Docker system
    print_message "$YELLOW" "Cleaning Docker system..."
    docker system prune -f

    # Build and push Cart API
    print_message "$YELLOW" "Building and pushing Cart API..."
    cd src/apps/Simple.CartApi
    if ! docker build --no-cache --platform linux/amd64 -t simple-cart-api:latest .; then
        cd ../../..
        handle_error "Failed to build Cart API"
    fi
    docker tag simple-cart-api:latest $ecr_url/simple-cart-api:latest
    docker push $ecr_url/simple-cart-api:latest
    cd ../../..

    # Build and push Delivery API
    print_message "$YELLOW" "Building and pushing Delivery API..."
    cd src/apps/Simple.DeliveryApi
    if ! docker build --no-cache --platform linux/amd64 -t simple-delivery-api:latest .; then
        cd ../../..
        handle_error "Failed to build Delivery API"
    fi
    docker tag simple-delivery-api:latest $ecr_url/simple-delivery-api:latest
    docker push $ecr_url/simple-delivery-api:latest
    cd ../../..
}

# Verify service account exists
verify_service_accounts() {
    print_message "$YELLOW" "Verifying service accounts..."
    
    if ! kubectl get serviceaccount ${CART_SERVICE_ACCOUNT} &>/dev/null; then
        handle_error "Cart API service account not found. Please run create-eks-env.sh first."
    fi
    
    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT} &>/dev/null; then
        handle_error "Delivery API service account not found. Please run create-eks-env.sh first."
    fi
    
    print_message "$GREEN" "Service accounts verified successfully"
}
# Create Kubernetes deployment files
create_k8s_files() {
    print_message "$YELLOW" "Creating Kubernetes deployment files..."
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
      annotations:
        instrumentation.opentelemetry.io/inject-dotnet: "true"
        instrumentation.opentelemetry.io/otel-dotnet-auto-runtime: "linux-musl-x64"
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
      annotations:
        instrumentation.opentelemetry.io/inject-dotnet: "true"
        instrumentation.opentelemetry.io/otel-dotnet-auto-runtime: "linux-musl-x64"
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
          value: "http://delivery-api-service:8080"
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
  name: cart-api-service
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
  name: delivery-api-service
spec:
  selector:
    app: dotnet-delivery-api
  ports:
    - name: http-8080
      protocol: TCP
      port: 8080
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
            name: cart-api-service
            port:
              number: 8080
      - path: /apps/delivery
        pathType: Prefix
        backend:
          service:
            name: delivery-api-service
            port:
              number: 8080
EOF
}

# Restart deployments
restart_deployments() {
    print_message "$YELLOW" "Restarting deployments..."
    
    kubectl rollout restart deployment dotnet-cart-api
    kubectl rollout restart deployment dotnet-delivery-api
    
    kubectl rollout status deployment dotnet-cart-api
    kubectl rollout status deployment dotnet-delivery-api
}

# Deploy to Kubernetes
deploy_to_k8s() {
    print_message "$YELLOW" "Deploying to Kubernetes..."
    
    kubectl apply -f kubernetes/cart-deployment.yaml
    kubectl apply -f kubernetes/delivery-deployment.yaml
    kubectl apply -f kubernetes/cart-service.yaml
    kubectl apply -f kubernetes/delivery-service.yaml
    kubectl apply -f kubernetes/ingress.yaml
    
    restart_deployments
}

# Verify deployment
verify_deployment() {
    print_message "$YELLOW" "Verifying deployment..."
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
                print_message "$YELLOW" "Waiting for $deployment to be ready ($ready_replicas/$total_replicas)..."
                break
            fi
        done
        
        if $all_ready; then
            print_message "$GREEN" "All deployments are ready!"
            break
        fi
        
        if [ $i -eq $max_attempts ]; then
            handle_error "Deployment verification timed out"
        fi
        
        sleep $wait_seconds
    done

    print_message "$GREEN" "Deployment verification completed successfully"
}

# Print deployment summary
print_deployment_summary() {
    print_message "$YELLOW" "Getting deployment summary..."
    
    # Get ALB endpoint
    ALB_ENDPOINT=$(kubectl get ingress apps-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    # Print summary
    echo -e "\n${GREEN}Deployment Summary:${NC}"
    echo -e "${GREEN}Application URL: ${NC}http://${ALB_ENDPOINT}"
    echo -e "${GREEN}Cart API Path: ${NC}/apps/cart"
    echo -e "${GREEN}Delivery API Path: ${NC}/apps/delivery"
    echo -e "\n${YELLOW}Note: It may take a few minutes for the ALB to become available${NC}"
}

# Validate AWS region
validate_aws_region() {
    if ! aws ec2 describe-regions --region "$AWS_REGION" &>/dev/null; then
        handle_error "Invalid AWS region: $AWS_REGION"
    fi
}

# Check prerequisites
check_prerequisites() {
    print_message "$YELLOW" "Checking prerequisites..."
    
    # Check required commands
    local required_commands=("aws" "kubectl" "docker" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            handle_error "$cmd is required but not installed"
        fi
    done
    
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
                echo "Usage: $0 [--region AWS_REGION] [--skip-build]"
                echo "  --region     : AWS region (default: from cluster config)"
                echo "  --skip-build : Skip building and pushing Docker images"
                echo "  --help       : Show this help message"
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
        print_message "$YELLOW" "Using provided AWS region: $AWS_REGION"
    fi
    
    verify_service_accounts
    
    if [ "$SKIP_BUILD" != "true" ]; then
        create_ecr_repos
        ecr_login
        build_and_push_images
    else
        print_message "$YELLOW" "Skipping build and push of Docker images"
    fi
    
    create_k8s_files
    deploy_to_k8s
    verify_deployment
    print_deployment_summary
}

# Cleanup handler
cleanup() {
    if [ $? -ne 0 ]; then
        print_message "$RED" "Deployment failed!"
        if [ ! -z "${AWS_REGION}" ]; then
            print_message "$YELLOW" "You may want to run cleanup-eks-env.sh to clean up resources"
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

