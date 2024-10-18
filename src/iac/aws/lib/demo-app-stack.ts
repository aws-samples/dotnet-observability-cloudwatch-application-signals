import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as ecr_asset from "aws-cdk-lib/aws-ecr-assets";
import path = require("path");

export class DemoAppStack extends cdk.Stack {
  DynamoDbTable: cdk.aws_dynamodb.Table;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    this.DynamoDbTable = new dynamodb.Table(this, "simple-table", {
      tableName: "simple-cart-catalog",
      partitionKey: { name: "Id", type: dynamodb.AttributeType.STRING },
      removalPolicy: cdk.RemovalPolicy.DESTROY, //DO NOT USE THIS IN PRODUCTION
      pointInTimeRecovery: false, //DO NOT USE THIS IN PRODUCTION
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
    });

    //Build docker image
    const cartDockerImage = new ecr_asset.DockerImageAsset(
      this,
      "simple-cart-api",
      {
        directory: path.join(__dirname, "../../../apps/Simple.CartApi/"),
        platform: ecr_asset.Platform.LINUX_AMD64, //Set this to your target architecture
      }
    );

    const deliverDockerImage = new ecr_asset.DockerImageAsset(
      this,
      "simple-delivery-api",
      {
        directory: path.join(__dirname, "../../../apps/Simple.DeliveryApi/"),
        platform: ecr_asset.Platform.LINUX_AMD64, //Set this to your target architecture
      }
    );

    new cdk.CfnOutput(this, "DynamoDbTableName", {
      value: this.DynamoDbTable.tableName,
    });

    new cdk.CfnOutput(this, "CartDockerImageUri", {
      value: cartDockerImage.imageUri,
    });

    new cdk.CfnOutput(this, "DeliveryDockerImageUri", {
      value: deliverDockerImage.imageUri,
    });
  }
}
