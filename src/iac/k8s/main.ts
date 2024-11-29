import { App } from "cdk8s";
import * as kplus from "cdk8s-plus-30";
import SimpleWebApiChart from "./Charts/SimpleWebApiChart";
import MainChart from "./Charts/MainChart";

const app = new App();

const DELIVERY_IMAGE = process.env.DELIVERY_IMAGE ?? "";
const CART_IMAGE = process.env.CART_IMAGE ?? "";

const mainChart = new MainChart(app, "main");

const deliveryApp = new SimpleWebApiChart(app, "delivery", {
  image: DELIVERY_IMAGE,
  portNumber: 8080,
  healthcheckPath: "/healthz",
  envVariables: {
    ASPNETCORE_ENVIRONMENT: kplus.EnvValue.fromValue("Development"),
    ASPNETCORE_URLS: kplus.EnvValue.fromValue("http://+:8080"),
  },
  ingress: mainChart.ingress,
});

new SimpleWebApiChart(app, "cart", {
  image: CART_IMAGE,
  portNumber: 8080,
  healthcheckPath: "/healthz",
  envVariables: {
    ASPNETCORE_ENVIRONMENT: kplus.EnvValue.fromValue("Development"),
    ASPNETCORE_URLS: kplus.EnvValue.fromValue("http://+:8080"),
    BACKEND_URL: kplus.EnvValue.fromValue(
      `http://${deliveryApp.appServices.name}:${deliveryApp.appServices.port}`
    ),
  },
  ingress: mainChart.ingress,
  serviceAccountName: "cart-app-service-account",
});

app.synth();
