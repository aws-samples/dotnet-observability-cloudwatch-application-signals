# Code snippet

## EKS Cluster with Add-Ons

```ts
export class EksBlueprintStack {
  constructor(scope: Construct, id: string) {
    ...

    const addOns: Array<blueprints.ClusterAddOn> = [
      ...
      new blueprints.addons.AdotCollectorAddOn(),
      new blueprints.addons.CloudWatchAdotAddOn(),
      ...
    ];

    const stack = blueprints.EksBlueprint.builder()
      .version(KubernetesVersion.V1_30)
      .addOns(...addOns)
      .useDefaultSecretEncryption(false) 
      .build(scope, id);
    ....
  }
}
```

## Kubernetes Resources using CDK8s

```ts
const appDeployment = new kplus.Deployment(this, "web-app", {
  serviceAccount: appServiceAccount,
  podMetadata: {
    annotations: {
      "instrumentation.opentelemetry.io/inject-dotnet": "true",
      "instrumentation.opentelemetry.io/otel-dotnet-auto-runtime": "linux-musl-x64",
    },
  },
  containers: [
    {
      image: props.image,
      args: props.args ?? [],
      portNumber: props.portNumber,
      envVariables: props.envVariables ?? undefined,
      ...
    },
  ],
});
```

## Deploy Kubernetes Resources

```sh
# navigate to IaC folder
cd src/iac/k8s

#get container image URL
export CART_IMAGE=$(aws cloudformation describe-stacks  --stack-name demo-app-stack --output text --query 'Stacks[0].Outputs[?contains(OutputKey,`CartDockerImageUri`)].OutputValue  | [0]')
export DELIVERY_IMAGE=$(aws cloudformation describe-stacks  --stack-name demo-app-stack --output text --query 'Stacks[0].Outputs[?contains(OutputKey,`DeliveryDockerImageUri`)].OutputValue  | [0]')

#Synthesize cdk8s
npm ci
cdk8s synth

#deploy kubernetes resources
kubectl apply -f ./dist/
```

## Verify Deployment Results

```sh
kubectl get pods                            

# Output
# NAME                                                   READY   STATUS             RESTARTS           AGE
# cart-web-app-c8da5bb2-59b9558b87-4tlkv                 1/1     Running            0                  2min
# cart-web-app-c8da5bb2-59b9558b87-6gj29                 1/1     Running            0                  2min
# delivery-web-app-c887213d-b688b8955-sxnsq              1/1     Running            0                  2min
# delivery-web-app-c887213d-b688b8955-x72x8              1/1     Running            0                  2min
```

```sh
cd src/iac/aws
export EKS_URL_BASE=$(kubectl get ingress | awk 'NR==2 {print $4}')
export CART_WORKLOAD_NAME=$(kubectl get deployments | awk 'NR==2 {print $1}')

cdk deploy --require-approval never demo-canary-stack
```

## Clean up

```sh
cd src/iac/k8s
kubectl delete -f dist/
cd ../aws   
cdk destroy --require-approval never --all   
```

X-Ray Query to search for Traces that content DynamoDB

```sql
service(id(name: "DynamoDB" , type: "AWS::DynamoDB" ))
```
