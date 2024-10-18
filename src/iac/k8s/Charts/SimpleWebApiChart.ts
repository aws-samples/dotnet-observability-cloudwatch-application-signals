import { Construct } from "constructs";
import * as kplus from "cdk8s-plus-30";
import { Chart, ChartProps, Size } from "cdk8s";

export interface SimpleWebApiChartProps extends ChartProps {
  image: string;
  args?: string[];
  portNumber: number;
  healthcheckPath?: string;
  envVariables?: {
    [name: string]: kplus.EnvValue;
  };
  ingress?: kplus.Ingress;
  serviceAccountName?: string;
}
export default class SimpleWebApiChart extends Chart {
  appServices: kplus.Service;

  constructor(
    scope: Construct,
    id: string,
    props: SimpleWebApiChartProps = {
      image: "public.ecr.aws/ecs-sample-image/amazon-ecs-sample:latest",
      portNumber: 80,
    }
  ) {
    super(scope, id, props);

    const appServiceAccount = props.serviceAccountName
      ? kplus.ServiceAccount.fromServiceAccountName(
          this,
          "service-account",
          props.serviceAccountName
        )
      : undefined;

    const appDeployment = new kplus.Deployment(this, "web-app", {
      serviceAccount: appServiceAccount,
      podMetadata: {
        annotations: {
          "instrumentation.opentelemetry.io/inject-dotnet": "true",
          "instrumentation.opentelemetry.io/otel-dotnet-auto-runtime":
            "linux-musl-x64",
        },
      },
      containers: [
        {
          image: props.image,
          args: props.args ?? [],
          portNumber: props.portNumber,
          envVariables: props.envVariables ?? undefined,
          resources: {
            cpu: {
              request: kplus.Cpu.millis(100),
              limit: kplus.Cpu.millis(500),
            },
            memory: {
              request: Size.mebibytes(512),
              limit: Size.mebibytes(1024),
            },
          },
          securityContext: {
            ensureNonRoot: false,
          },
        },
      ],
    });

    this.appServices = appDeployment.exposeViaService({
      name: `${id}-svc`,
      ports: [
        {
          name: `http-${props.portNumber}`,
          port: props.portNumber,
          targetPort: props.portNumber,
        },
      ],
      serviceType: kplus.ServiceType.CLUSTER_IP,
    });

    if (props.ingress) {
      props.ingress.addRule(
        `/apps/${id}`,
        kplus.IngressBackend.fromService(this.appServices)
      );

      props.ingress.metadata.addAnnotation(
        "alb.ingress.kubernetes.io/scheme",
        "internet-facing"
      );

      props.ingress.metadata.addAnnotation(
        "alb.ingress.kubernetes.io/listen-ports",
        '[{"HTTP": 80}]'
      );

      props.ingress.metadata.addAnnotation(
        "alb.ingress.kubernetes.io/healthcheck-path",
        props.healthcheckPath ?? "/"
      );

      props.ingress.metadata.addAnnotation(
        "alb.ingress.kubernetes.io/target-type",
        "ip"
      );
    }
  }
}
