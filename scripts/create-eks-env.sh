#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Print with color
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Error handling
handle_error() {
    print_message $RED "Error occurred on line $1"
    print_message $RED "Command: $2"
    exit 1
}

trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

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

    print_message $RED "Failed to generate valid unique ID"
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
        print_message $RED "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        print_message $RED "AWS CLI is not configured"
        exit 1
    fi
}

# Get AWS account details
get_aws_details() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION=${AWS_REGION:-$(aws configure get region)}
    
    if [ -z "$AWS_REGION" ]; then
        print_message $RED "AWS region is not configured"
        exit 1
    fi
}

# Setup resource names
setup_resource_names() {
    ID=$(generate_unique_id)
    print_message $YELLOW "Generated ID: $ID"
    
    DYNAMODB_TABLE_NAME="simple-cart-catalog"
    CW_AGENT_ROLE_NAME="${ID}-cw"
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
        print_message $RED "Invalid cluster name format"
        exit 1
    fi
}

# Create EKS cluster
create_eks_cluster() {
    if aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null; then
        print_message $YELLOW "Cluster ${CLUSTER_NAME} already exists"
        return 0
    fi
    
    print_message $YELLOW "Creating EKS cluster ${CLUSTER_NAME}..."
    
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
  serviceAccounts:
    - metadata:
        name: cloudwatch-agent
        namespace: amazon-cloudwatch
      roleName: ${CW_AGENT_ROLE_NAME}
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
      tags: *tags

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
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: amazon-cloudwatch-observability
    version: latest
EOF

    eksctl create cluster -f cluster.yaml
    aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
}

# Create DynamoDB table
create_dynamodb_table() {
    if aws dynamodb describe-table --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION} &>/dev/null; then
        print_message $YELLOW "DynamoDB table ${DYNAMODB_TABLE_NAME} already exists"
        return 0
    fi

    print_message $YELLOW "Creating DynamoDB table ${DYNAMODB_TABLE_NAME}..."
    local common_tags=$(get_common_tags)

    aws dynamodb create-table \
        --table-name ${DYNAMODB_TABLE_NAME} \
        --attribute-definitions AttributeName=Id,AttributeType=S \
        --key-schema AttributeName=Id,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
        --tags $common_tags \
        --region ${AWS_REGION} \
        

    #aws dynamodb wait table-exists --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION}
}

# Create IAM policies and service accounts
# Create IAM policies and service accounts
create_iam_resources() {
    print_message $YELLOW "Creating IAM resources..."
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
        print_message $YELLOW "Updating existing policy ${CART_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CART_API_POLICY_NAME}" \
            --policy-document file://cart-api-dynamodb-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        CART_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CART_API_POLICY_NAME}"
    else
        print_message $YELLOW "Creating new policy ${CART_API_POLICY_NAME}"
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
        print_message $YELLOW "Updating existing policy ${DELIVERY_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}" \
            --policy-document file://delivery-api-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        DELIVERY_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}"
    else
        print_message $YELLOW "Creating new policy ${DELIVERY_API_POLICY_NAME}"
        DELIVERY_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${DELIVERY_API_POLICY_NAME}" \
            --policy-document file://delivery-api-policy.json \
            --tags $common_tags \
            --query 'Policy.Arn' \
            --output text)
    fi

    print_message $GREEN "Cart API Policy ARN: $CART_POLICY_ARN"
    print_message $GREEN "Delivery API Policy ARN: $DELIVERY_POLICY_ARN"

    # Create service accounts
    print_message $YELLOW "Creating service accounts..."
    
    # Cart API service account
    print_message $YELLOW "Creating service account ${CART_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${CART_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${CART_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${CART_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION} \

    # Verify Cart API service account
    if ! kubectl get serviceaccount ${CART_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        print_message $RED "Cart API service account creation failed"
        exit 1
    fi
    
    # Delivery API service account
    print_message $YELLOW "Creating service account ${DELIVERY_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${DELIVERY_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${DELIVERY_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION} 

    rm -f cart-api-dynamodb-policy.json delivery-api-policy.json
}
setup_eks_addons() {
    print_message "$YELLOW" "Setting up EKS add-ons..."

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
        print_message "$YELLOW" "ALB Controller policy already exists, using existing policy"
        ALB_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ALB_POLICY_NAME}"
    else
        print_message "$YELLOW" "Creating ALB Controller policy..."
        curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

        ALB_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${ALB_POLICY_NAME}" \
            --policy-document file://iam_policy.json \
            --query 'Policy.Arn' \
            --output text \
            --region ${AWS_REGION})

        rm -f iam_policy.json
    fi

    # Create service account for ALB Controller
    print_message "$YELLOW" "Creating service account for ALB Controller..."
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --attach-policy-arn="${ALB_POLICY_ARN}" \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Check if ALB Controller is already installed
    if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
        print_message "$YELLOW" "AWS Load Balancer Controller already installed, upgrading..."
        helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName=${CLUSTER_NAME} \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller
    else
        print_message "$YELLOW" "Installing AWS Load Balancer Controller..."
        helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName=${CLUSTER_NAME} \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller
    fi

    print_message "$GREEN" "EKS add-ons setup completed"
}



# Setup CloudWatch observability
setup_cloudwatch() {
    print_message $YELLOW "Setting up CloudWatch observability..."

    eksctl utils associate-iam-oidc-provider \
        --cluster ${CLUSTER_NAME} \
        --approve \
        --region ${AWS_REGION} || true

    kubectl create namespace amazon-cloudwatch --dry-run=client -o yaml | kubectl apply -f -

    if ! aws eks describe-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name amazon-cloudwatch-observability \
        --region ${AWS_REGION} &>/dev/null; then
        
        aws eks create-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name amazon-cloudwatch-observability \
            --region ${AWS_REGION}

        # Wait for addon to be active
        aws eks wait addon-active \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name amazon-cloudwatch-observability \
            --region ${AWS_REGION}
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
        "cloudwatch_role": "${CW_AGENT_ROLE_NAME}",
        "iam_policy": {
            "name": "${CART_API_POLICY_NAME}",
            "arn": "${POLICY_ARN}"
        },
        "alb_controller": {
            "policy_name": "AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}",
            "policy_arn": "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}",
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
        "cert_manager": "installed",
        "cloudwatch_observability": "installed"
    }
}
EOF

    if ! jq '.' .cluster-config/cluster-resources.json >/dev/null 2>&1; then
        print_message $RED "Invalid JSON configuration"
        exit 1
    fi

    print_message $GREEN "Configuration saved to .cluster-config/cluster-resources.json"
}


# Verify setup
verify_setup() {
    print_message $YELLOW "Verifying setup..."
    
    # Check nodes
    if ! kubectl get nodes &>/dev/null; then
        print_message $RED "Failed to get cluster nodes"
        exit 1
    fi

    # Check service accounts
    if ! kubectl get serviceaccount ${CART_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        print_message $RED "Cart service account verification failed"
        exit 1
    fi

    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        print_message $RED "Delivery service account verification failed"
        exit 1
    fi  # Remove the extra }

    # Check DynamoDB
    if ! aws dynamodb describe-table \
        --table-name ${DYNAMODB_TABLE_NAME} \
        --region ${AWS_REGION} \
        --query 'Table.TableStatus' \
        --output text &>/dev/null; then
        print_message $RED "DynamoDB table verification failed"
        exit 1
    fi
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --region)
                if [ -z "$2" ]; then
                    print_message $RED "Region value is required"
                    exit 1
                fi
                AWS_REGION="$2"
                shift
                shift
                ;;
            --help)
                print_message $GREEN "Usage: $0 --region <aws-region>"
                print_message $GREEN "Example: $0 --region us-east-1"
                exit 0
                ;;
            *)
                print_message $RED "Unknown option: $1"
                print_message $YELLOW "Usage: $0 --region <aws-region>"
                exit 1
                ;;
        esac
    done

    if [ -z "$AWS_REGION" ]; then
        print_message $RED "Region parameter is required"
        print_message $YELLOW "Usage: $0 --region <aws-region>"
        exit 1
    fi
}

# Print summary 
print_summary() {
    print_message $GREEN "\n========================================="
    print_message $GREEN "Environment setup completed successfully!"
    print_message $GREEN "========================================="
    
    print_message $GREEN "\nCluster Details:"
    print_message $GREEN "  Name: ${CLUSTER_NAME}"
    print_message $GREEN "  Region: ${AWS_REGION}"
    print_message $GREEN "  Resource ID: ${ID}"
    
    print_message $GREEN "\nResources Created:"
    print_message $GREEN "  - EKS Cluster"
    print_message $GREEN "  - DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
    print_message $GREEN "  - IAM Policy: ${CART_API_POLICY_NAME}"
    print_message $GREEN "  - Cart Service Account: ${CART_SERVICE_ACCOUNT_NAME}"
    print_message $GREEN "  - Delivery Service Account: ${DELIVERY_SERVICE_ACCOUNT_NAME}"
    print_message $GREEN "  - CloudWatch Agent Role: ${CW_AGENT_ROLE_NAME}"
    print_message $GREEN "  - ALB Controller Policy: AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
    print_message $GREEN "  - ALB Controller Service Account: aws-load-balancer-controller"
    
    print_message $GREEN "\nAdd-ons Installed:"
    print_message $GREEN "  - AWS Load Balancer Controller"
    print_message $GREEN "  - Cert Manager"
    print_message $GREEN "  - CloudWatch Observability"
    
    print_message $GREEN "\nConfiguration saved to:"
    print_message $GREEN "  .cluster-config/cluster-resources.json"
    
    print_message $YELLOW "\nNext Steps:"
    print_message $YELLOW "Run the deployment script:"
    print_message $YELLOW "   ./scripts/build-deploy.sh --region ${AWS_REGION}"
}


# Main execution
main() {
    print_message $YELLOW "Starting environment setup..."
    
    parse_arguments "$@"
    check_prerequisites
    get_aws_details
    setup_resource_names
    get_cluster_name
    
    print_message $YELLOW "\nCreating resources..."
    create_eks_cluster
    setup_eks_addons
    create_dynamodb_table
    create_iam_resources
    setup_cloudwatch
    
    print_message $YELLOW "\nFinalizing setup..."
    verify_setup
    save_config
    print_summary
}

# Execute main function with arguments
main "$@"
