import { Construct } from "constructs";
import * as cdk from "aws-cdk-lib";
import * as synthetics from "aws-cdk-lib/aws-synthetics";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
import { Duration } from "aws-cdk-lib";
import path = require("path");

export interface DemoCanaryStackProps extends cdk.StackProps {
  readonly CanaryName: string;
}

export class DemoCanaryStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: DemoCanaryStackProps) {
    super(scope, id, props);

    const canary = new synthetics.Canary(this, "cw-canary", {
      canaryName: props?.CanaryName ?? undefined,
      schedule: synthetics.Schedule.rate(Duration.minutes(2)),
      test: synthetics.Test.custom({
        code: synthetics.Code.fromAsset(path.join(__dirname, "../canary")),
        handler: "index.handler",
      }),
      runtime: new synthetics.Runtime(
        "syn-nodejs-puppeteer-9.1",
        synthetics.RuntimeFamily.NODEJS
      ),
      environmentVariables: {
        EKS_URL_BASE: process.env.EKS_URL_BASE ?? "",
      },
    });

    const alarm = new cw.Alarm(this, "cw-alarm", {
      metric: canary.metricSuccessPercent(),
      evaluationPeriods: 1,
      comparisonOperator: cw.ComparisonOperator.LESS_THAN_OR_EQUAL_TO_THRESHOLD,
      threshold: 90,
      treatMissingData: cw.TreatMissingData.NOT_BREACHING,
    });
  }
}
