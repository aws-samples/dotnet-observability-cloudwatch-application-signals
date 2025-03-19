#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Load configuration if exists
if [ -f .cluster-config/cluster-resources.json ]; then
    RESOURCE_ID=$(jq -r '.id' .cluster-config/cluster-resources.json)
    CLUSTER_NAME=$(jq -r '.cluster.name' .cluster-config/cluster-resources.json)
    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' .cluster-config/cluster-resources.json)
    DYNAMODB_TABLE_NAME=$(jq -r '.resources.dynamodb_table' .cluster-config/cluster-resources.json)
    CART_SERVICE_ACCOUNT=$(jq -r '.resources.cart_service_account' .cluster-config/cluster-resources.json)
    DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.delivery_service_account' .cluster-config/cluster-resources.json)
else
    print_message "$RED" "Configuration file not found"
    exit 1
fi

print_message "$YELLOW" "Starting cleanup for cluster: $CLUSTER_NAME"

# Delete AWS Load Balancer Controller
print_message "$YELLOW" "Removing AWS Load Balancer Controller..."
helm uninstall aws-load-balancer-controller -n kube-system || true

# Delete ALB Controller Policy
ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
aws iam delete-policy \
    --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ALB_POLICY_NAME}" || true

# Delete cert-manager
print_message "$YELLOW" "Removing cert-manager..."
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml || true

# Delete EKS addons
print_message "$YELLOW" "Removing EKS addons..."
aws eks delete-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name amazon-cloudwatch-observability \
    --region "${AWS_REGION}" || true

# Delete service accounts and associated IAM roles
print_message "$YELLOW" "Removing service accounts..."
eksctl delete iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --namespace=default \
    --name="${CART_SERVICE_ACCOUNT}" \
    --region "${AWS_REGION}" || true

eksctl delete iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --namespace=default \
    --name="${DELIVERY_SERVICE_ACCOUNT}" \
    --region "${AWS_REGION}" || true

eksctl delete iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --namespace=kube-system \
    --name="aws-load-balancer-controller" \
    --region "${AWS_REGION}" || true

# Delete IAM policies
print_message "$YELLOW" "Removing IAM policies..."
CART_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${RESOURCE_ID}-cart-policy"
DELIVERY_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${RESOURCE_ID}-delivery-policy"

aws iam delete-policy --policy-arn "${CART_POLICY_ARN}" || true
aws iam delete-policy --policy-arn "${DELIVERY_POLICY_ARN}" || true

# Delete ECR repositories
#print_message "$YELLOW" "Removing ECR repositories..."
#for repo in "simple-cart-api" "simple-delivery-api"; do
#    aws ecr delete-repository \
#        --repository-name "$repo" \
#        --force \
#        --region "${AWS_REGION}" || true
#done

# Delete DynamoDB table
print_message "$YELLOW" "Removing DynamoDB table..."
aws dynamodb delete-table \
    --table-name "${DYNAMODB_TABLE_NAME}" \
    --region "${AWS_REGION}" || true

# Delete EKS cluster
print_message "$YELLOW" "Deleting EKS cluster..."
eksctl delete cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --wait

# Clean up local files
print_message "$YELLOW" "Cleaning up local files..."
rm -rf .cluster-config kubernetes cluster.yaml *.json

print_message "$GREEN" "Cleanup completed successfully"
print_message "$GREEN" "The following resources have been removed:"
echo -e "${GREEN}- EKS Cluster: ${CLUSTER_NAME}"
echo -e "- DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
#echo -e "- ECR Repositories: simple-cart-api, simple-delivery-api"
echo -e "- IAM Policies and Service Accounts"
echo -e "- AWS Load Balancer Controller"
echo -e "- cert-manager"
echo -e "- CloudWatch Observability addon${NC}"
