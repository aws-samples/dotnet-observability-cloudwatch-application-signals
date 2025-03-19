## Deployment Steps

### 1. Create EKS Environment

This step creates the EKS cluster, DynamoDB table, and required IAM roles:

Make script executable and create environment


```bash
chmod +x scripts/create-eks-enn.sh

./scripts/create-eks-env.sh --region <your-aws-region>

```

### 2. Build and Deploy Application

Make script executable and build and deploy application

```bash
chmod +x scripts/build-deploy.sh
./scripts/build-deploy.sh --region <your-aws-region>
```

### 3. Test the application deployment

You can test and generate load on the application by running the below script. Keep the script running for ~2min.
```bash
chmod +x scripts/load-generator.sh
./scripts/load-generator.sh 
```

### 4. Monitor .NET applications using CloudWatch Application Signals

Check AWS Application Signals:

- Open [Amazon CloudWatch Console](https://console.aws.amazon.com/cloudwatch/)
- Navigate to CloudWatch Application Signals from the left hand side navigation pane


### 5. Cleanup
To remove all created resources run the below scripts

```bash    
chmod +x scripts/build-cleanup.sh
chmod +x scripts/cleanup-eks-env.sh
./scripts/build-cleanup.sh
./scripts/cleanup-eks-env.sh
```
  

## Troubleshooting

1. Check pod status:
```bash
kubectl get pods
kubectl describe pod <pod-name>
```

2. View logs:
```bash
kubectl logs -l app=dotnet-order-api
kubectl logs -l app=dotnet-delivery-api
```
