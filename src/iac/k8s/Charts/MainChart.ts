import { Chart } from "cdk8s";
import * as kplus from "cdk8s-plus-30";
import { Construct } from "constructs";

export default class MainChart extends Chart {
  public ingress: kplus.Ingress;

  constructor(scope: Construct, id: string) {
    super(scope, id);

    this.ingress = new kplus.Ingress(this, "ingress", {
      className: "alb",
    });
  }
}
