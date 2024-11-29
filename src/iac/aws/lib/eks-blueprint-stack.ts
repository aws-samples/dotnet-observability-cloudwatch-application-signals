#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import * as blueprints from "@aws-quickstart/eks-blueprints";
import { KubernetesVersion } from "aws-cdk-lib/aws-eks";
import { Construct } from "constructs";
import * as iam from "aws-cdk-lib/aws-iam";

export class EksBlueprintStack {
  constructor(scope: Construct, id: string) {
    //EKS BluePrint
    blueprints.HelmAddOn.validateHelmVersions = true; // optional if you would like to check for newer versions

    const addOns: Array<blueprints.ClusterAddOn> = [
      new blueprints.addons.AwsLoadBalancerControllerAddOn(),
      new blueprints.addons.CertManagerAddOn(),
      new blueprints.addons.AdotCollectorAddOn(),
      new blueprints.addons.CloudWatchAdotAddOn(),
      new blueprints.addons.CloudWatchInsights(),
      new blueprints.addons.ClusterAutoScalerAddOn(),
      new blueprints.addons.CoreDnsAddOn(),
      new blueprints.addons.KubeProxyAddOn(),
    ];

    const stack = blueprints.EksBlueprint.builder()
      .version(KubernetesVersion.V1_30)
      .addOns(...addOns)
      .useDefaultSecretEncryption(false) // set to false to turn secret encryption off (non-production/demo cases)
      .build(scope, id);

    //Create Service Account to allow APP to access DynamoDB
    blueprints.utils.createServiceAccountWithPolicy(
      stack.getClusterInfo().cluster,
      "cart-app-service-account",
      "default",
      iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonDynamoDBFullAccess") //This is for demo, you should limit access in production environment..
    );
  }
}
