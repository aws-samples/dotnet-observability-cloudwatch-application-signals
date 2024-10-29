#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { DemoAppStack } from "../lib/demo-app-stack";
import { EksBlueprintStack } from "../lib/eks-blueprint-stack";
import { DemoCanaryStack } from "../lib/demo-canary";

const app = new cdk.App();
const appStack = new DemoAppStack(app, "demo-app-stack", {});

new EksBlueprintStack(app, "eks-blueprint-demo");
new DemoCanaryStack(app, "demo-canary-stack", {
  CanaryName: process.env.CART_WORKLOAD_NAME || "cart-web-app",
});
