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
    local level=$1
    local message="$2"
    local color
    
    # Convert level to uppercase using tr instead of ${1^^}
    level=$(echo "$level" | tr '[:lower:]' '[:upper:]')
    
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
    log "ERROR" "Error occurred on line $1"
    log "ERROR" "Command: $2"
    exit 1
}

trap 'handle_error ${LINENO} "${BASH_COMMAND}"' ERR

# Generate common tags
get_common_tags() {
    local common_tags="Key=Environment,Value=Development \
        Key=Project,Value=DotNetAppSignals \
        Key=ClusterName,Value=${CLUSTER_NAME}"
    echo "$common_tags"
}

# Generate unique ID with max attempts
generate_unique_id() {
    local id=""
    local max_attempts=10
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        id=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
        if [[ $id =~ ^[a-z0-9]{6}$ ]]; then
            echo $id
            return 0
        fi
        attempt=$((attempt + 1))
    done

    log "ERROR" "Failed to generate valid unique ID"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    local required_tools="aws kubectl eksctl jq helm"
    local missing_tools=()

    for tool in $required_tools; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        log "ERROR" "AWS CLI is not configured"
        exit 1
    fi
}

# Get AWS account details
get_aws_details() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION=${AWS_REGION:-$(aws configure get region)}
    
    if [ -z "$AWS_REGION" ]; then
        log "ERROR" "AWS region is not configured"
        exit 1
    fi
}

# Setup resource names
setup_resource_names() {
    ID=$(generate_unique_id)
    log "INFO" "Generated ID: $ID"
    
    DYNAMODB_TABLE_NAME="simple-cart-catalog"
    ORDER_API_POLICY_NAME="${ID}-policy"
    CART_API_POLICY_NAME="${ID}-cart-policy"
    CART_SERVICE_ACCOUNT_NAME="${ID}-cart-sa"
    DELIVERY_SERVICE_ACCOUNT_NAME="${ID}-delivery-sa"
    SERVICE_ACCOUNT_NAME="${ID}-sa"
}

# Get cluster name from user
get_cluster_name() {
    local DEFAULT_CLUSTER_NAME="eks-${ID}"
    
    read -p "Enter cluster name [$DEFAULT_CLUSTER_NAME]: " CLUSTER_NAME
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    
    if ! [[ $CLUSTER_NAME =~ ^[a-zA-Z][a-zA-Z0-9-]*[a-zA-Z0-9]$ && ${#CLUSTER_NAME} -le 100 ]]; then
        log "ERROR" "Invalid cluster name format"
        exit 1
    fi
}

# Create EKS cluster
create_eks_cluster() {
    if aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "Cluster ${CLUSTER_NAME} already exists"
        return 0
    fi
    
    log "INFO" "Creating EKS cluster ${CLUSTER_NAME}..."
    
    cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.31"
  tags: &tags
    Environment: Development
    Project: DotNetAppSignals
    ClusterName: ${CLUSTER_NAME}

iam:
  withOIDC: true

managedNodeGroups:
  - name: ng-1
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    tags: *tags
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
EOF

    eksctl create cluster -f cluster.yaml
    aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
}

# Create DynamoDB table
create_dynamodb_table() {
    if aws dynamodb describe-table --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "DynamoDB table ${DYNAMODB_TABLE_NAME} already exists"
        return 0
    fi

    log "INFO" "Creating DynamoDB table ${DYNAMODB_TABLE_NAME}..."
    local common_tags=$(get_common_tags)

    aws dynamodb create-table \
        --table-name ${DYNAMODB_TABLE_NAME} \
        --attribute-definitions AttributeName=Id,AttributeType=S \
        --key-schema AttributeName=Id,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
        --tags $common_tags \
        --region ${AWS_REGION}

    aws dynamodb wait table-exists --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION}
}

# Create IAM policies and service accounts
create_iam_resources() {
    log "INFO" "Creating IAM resources..."
    local common_tags=$(get_common_tags)

    # Create Cart API DynamoDB policy
    cat <<EOF > cart-api-dynamodb-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:UpdateItem",
                "dynamodb:DeleteItem",
                "dynamodb:Scan",
                "dynamodb:Query",
                "dynamodb:DescribeTable"
            ],
            "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${DYNAMODB_TABLE_NAME}"
        }
    ]
}
EOF

    # Create Delivery API policy
    cat <<EOF > delivery-api-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sqs:SendMessage",
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes"
            ],
            "Resource": "*"
        }
    ]
}
EOF

    # Create or update Cart API policy
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CART_API_POLICY_NAME}" 2>/dev/null; then
        log "INFO" "Updating existing policy ${CART_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CART_API_POLICY_NAME}" \
            --policy-document file://cart-api-dynamodb-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        CART_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CART_API_POLICY_NAME}"
    else
        log "INFO" "Creating new policy ${CART_API_POLICY_NAME}"
        CART_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${CART_API_POLICY_NAME}" \
            --policy-document file://cart-api-dynamodb-policy.json \
            --tags $common_tags \
            --query 'Policy.Arn' \
            --output text)
    fi

    # Create or update Delivery API policy
    DELIVERY_API_POLICY_NAME="${ID}-delivery-policy"
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}" 2>/dev/null; then
        log "INFO" "Updating existing policy ${DELIVERY_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}" \
            --policy-document file://delivery-api-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        DELIVERY_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}"
    else
        log "INFO" "Creating new policy ${DELIVERY_API_POLICY_NAME}"
        DELIVERY_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${DELIVERY_API_POLICY_NAME}" \
            --policy-document file://delivery-api-policy.json \
            --tags $common_tags \
            --query 'Policy.Arn' \
            --output text)
    fi

    # Create service accounts
    log "INFO" "Creating service accounts..."
    
    # Cart API service account
    log "INFO" "Creating service account ${CART_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${CART_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${CART_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${CART_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Verify Cart API service account
    if ! kubectl get serviceaccount ${CART_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Cart API service account creation failed"
        exit 1
    fi
    
    # Delivery API service account
    log "INFO" "Creating service account ${DELIVERY_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${DELIVERY_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${DELIVERY_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Verify Delivery API service account
    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Delivery API service account creation failed"
        exit 1
    fi

    rm -f cart-api-dynamodb-policy.json delivery-api-policy.json
}

# Setup EKS addons
setup_eks_addons() {
    log "INFO" "Setting up EKS add-ons..."

    # Create OIDC provider
    eksctl utils associate-iam-oidc-provider \
        --cluster ${CLUSTER_NAME} \
        --approve \
        --region ${AWS_REGION}

    # Install cert-manager
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

    # Install AWS Load Balancer Controller
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update

    # Create or get existing ALB Controller Policy
    ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
    ALB_POLICY_ARN=""

    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ALB_POLICY_NAME}" &>/dev/null; then
        log "INFO" "ALB Controller policy already exists"
        ALB_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ALB_POLICY_NAME}"
    else
        log "INFO" "Creating ALB Controller policy..."
        curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

        ALB_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${ALB_POLICY_NAME}" \
            --policy-document file://iam_policy.json \
            --query 'Policy.Arn' \
            --output text)

        rm -f iam_policy.json
    fi

    # Create service account for ALB Controller
    log "INFO" "Creating service account for ALB Controller..."
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --attach-policy-arn="${ALB_POLICY_ARN}" \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Install/upgrade AWS Load Balancer Controller
    if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
        log "INFO" "Upgrading AWS Load Balancer Controller..."
        helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName=${CLUSTER_NAME} \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller
    else
        log "INFO" "Installing AWS Load Balancer Controller..."
        helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName=${CLUSTER_NAME} \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller
    fi
}

# Save configuration
save_config() {
    mkdir -p .cluster-config
    
    cat <<EOF > .cluster-config/cluster-resources.json
{
    "id": "${ID}",
    "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "cluster": {
        "name": "${CLUSTER_NAME}",
        "region": "${AWS_REGION}",
        "account_id": "${AWS_ACCOUNT_ID}"
    },
    "resources": {
        "dynamodb_table": "${DYNAMODB_TABLE_NAME}",
        "service_account": "${SERVICE_ACCOUNT_NAME}",
        "cart_service_account": "${CART_SERVICE_ACCOUNT_NAME}",
        "delivery_service_account": "${DELIVERY_SERVICE_ACCOUNT_NAME}",
        "iam_policy": {
            "cart_policy": {
                "name": "${CART_API_POLICY_NAME}",
                "arn": "${CART_POLICY_ARN}"
            },
            "delivery_policy": {
                "name": "${DELIVERY_API_POLICY_NAME}",
                "arn": "${DELIVERY_POLICY_ARN}"
            }
        },
        "alb_controller": {
            "policy_name": "${ALB_POLICY_NAME}",
            "policy_arn": "${ALB_POLICY_ARN}",
            "service_account": "aws-load-balancer-controller",
            "namespace": "kube-system"
        },
        "cert_manager": {
            "version": "v1.13.0",
            "namespace": "cert-manager"
        }
    },
    "tags": {
        "Environment": "Development",
        "Project": "DotNetAppSignals",
        "ClusterName": "${CLUSTER_NAME}"
    },
    "addons": {
        "aws_load_balancer_controller": "installed",
        "cert_manager": "installed"
    }
}
EOF

    if ! jq '.' .cluster-config/cluster-resources.json >/dev/null 2>&1; then
        log "ERROR" "Invalid JSON configuration"
        exit 1
    fi

    log "SUCCESS" "Configuration saved successfully"
}

# Verify setup
verify_setup() {
    log "INFO" "Verifying setup..."
    
    # Check nodes
    if ! kubectl get nodes &>/dev/null; then
        log "ERROR" "Failed to get cluster nodes"
        exit 1
    fi

    # Check service accounts
    if ! kubectl get serviceaccount ${CART_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Cart service account verification failed"
        exit 1
    fi

    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Delivery service account verification failed"
        exit 1
    fi

    # Check DynamoDB
    if ! aws dynamodb describe-table \
        --table-name ${DYNAMODB_TABLE_NAME} \
        --region ${AWS_REGION} \
        --query 'Table.TableStatus' \
        --output text &>/dev/null; then
        log "ERROR" "DynamoDB table verification failed"
        exit 1
    fi

    # Check ALB Controller
    if ! kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
        log "ERROR" "AWS Load Balancer Controller verification failed"
        exit 1
    fi

    log "SUCCESS" "All components verified successfully"
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --region)
                if [ -z "$2" ]; then
                    log "ERROR" "Region value is required"
                    exit 1
                fi
                AWS_REGION="$2"
                shift
                shift
                ;;
            --help)
                log "INFO" "Usage: $0 --region <aws-region>"
                log "INFO" "Example: $0 --region us-east-1"
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                log "INFO" "Usage: $0 --region <aws-region>"
                exit 1
                ;;
        esac
    done

    if [ -z "$AWS_REGION" ]; then
        log "ERROR" "Region parameter is required"
        log "INFO" "Usage: $0 --region <aws-region>"
        exit 1
    fi
}

# Print summary 
print_summary() {
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Environment setup completed successfully!"
    log "SUCCESS" "========================================="
    
    log "INFO" "\nCluster Details:"
    log "INFO" "  Name: ${CLUSTER_NAME}"
    log "INFO" "  Region: ${AWS_REGION}"
    log "INFO" "  Resource ID: ${ID}"
    
    log "INFO" "\nResources Created:"
    log "INFO" "  - EKS Cluster"
    log "INFO" "  - DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
    log "INFO" "  - Cart API Policy: ${CART_API_POLICY_NAME}"
    log "INFO" "  - Delivery API Policy: ${DELIVERY_API_POLICY_NAME}"
    log "INFO" "  - Cart Service Account: ${CART_SERVICE_ACCOUNT_NAME}"
    log "INFO" "  - Delivery Service Account: ${DELIVERY_SERVICE_ACCOUNT_NAME}"
    log "INFO" "  - ALB Controller Setup"
    log "INFO" "  - Cert Manager Installation"
    
    log "INFO" "\nConfiguration saved to:"
    log "INFO" "  .cluster-config/cluster-resources.json"
}

# Main execution
main() {
    log "INFO" "Starting environment setup..."
    
    parse_arguments "$@"
    check_prerequisites
    get_aws_details
    setup_resource_names
    get_cluster_name
    
    log "INFO" "\nCreating resources..."
    create_eks_cluster
    setup_eks_addons
    create_dynamodb_table
    create_iam_resources
    
    log "INFO" "\nFinalizing setup..."
    verify_setup
    save_config
    print_summary
}

# Execute main function with arguments
main "$@"
