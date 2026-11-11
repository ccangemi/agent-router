# agent-router-operator

A community operator for [Operator Lifecycle Manager (OLM)](https://olm.operatorframework.io/)
that installs [The Agent Router](https://github.com/theagentrouter/agent-router)
(formerly Envoy AI Gateway) on OpenShift.

The Agent Router adds AI traffic features to Envoy Gateway: routing to LLM
providers, token based rate limits, provider fallback and MCP routing.

It is a Helm operator, built with [Operator SDK](https://sdk.operatorframework.io/).
It installs the upstream `ai-gateway-helm` chart, unchanged, with the values
that OpenShift needs. cert-manager issues and renews the certificate of the
Agent Router webhook.

> This is a community project. It is not affiliated with, or endorsed by, the
> Envoy project.

## Versions

| Component | Version |
|---|---|
| Operator | 0.1.0 (channel `alpha`) |
| The Agent Router | v1.2.0 |
| Envoy Gateway (installed separately) | v1.9, with the extension settings for the Agent Router |
| OpenShift | 4.22 or later (Gateway API v1.4.1) |
| helm-operator (Operator SDK) | v1.42.3 |

The file [versions.env](versions.env) defines these versions.

## How it works

* You install, in this order: the cert-manager Operator for Red Hat
  OpenShift, Envoy Gateway (for example with the Envoy Gateway operator), and
  this operator in the namespace `envoy-ai-gateway-system`.
* You create one `AgentRouter` resource, named `agent-router`, in that
  namespace. Its spec holds the chart values: the values of the upstream chart
  go under the key `ai-gateway-helm`.
* The operator installs the chart as a Helm release in the same namespace: the
  Agent Router controller, and a mutating webhook that adds the external
  processor to the Envoy proxy pods.
* OLM installs and upgrades the Agent Router CRDs (`aigateway.envoyproxy.io`).

```yaml
apiVersion: agentrouter.ccangemi.github.io/v1alpha1
kind: AgentRouter
metadata:
  name: agent-router
  namespace: envoy-ai-gateway-system
spec: {}
```

## Quick start

1. Install the cert-manager Operator for Red Hat OpenShift.
2. Install Envoy Gateway with the extension settings for the Agent Router.
   With the Envoy Gateway operator, use its example
   `samples/ocp/envoygateway-with-agent-router.yaml`.
3. Install this operator and create the `AgentRouter` resource. See
   [docs/install.md](docs/install.md).
4. Create a GatewayClass, a Gateway and an `AIGatewayRoute`. The directory
   [samples/ocp/test](samples/ocp/test) has a complete example with a test
   backend.

## Documentation

* [Installation](docs/install.md)
* [OpenShift design notes](docs/openshift.md)
* [Install with Red Hat Advanced Cluster Management](docs/acm-policy.md)
* [Upgrades and certificates](docs/upgrade.md)
* [Troubleshooting](docs/troubleshooting.md)
* [Development, tests and releases](docs/development.md)

## Repository layout

| Path | Content |
|---|---|
| `versions.env` | The versions of the operator and of the upstream chart |
| `watches.yaml` | The custom resource that the operator watches, and its chart |
| `helm-charts/agent-router/` | The operator chart: OpenShift values and checks |
| `helm-charts/agent-router/charts/ai-gateway-helm/` | The upstream chart, unchanged |
| `config/` | Kustomize inputs of the bundle: CRDs, RBAC, manager, CSV base |
| `hack/` | Scripts: tools, upstream update, generators, safety gate, tests |
| `bundle/` | The generated OLM bundle (committed, do not edit by hand) |
| `samples/ocp/test/` | A complete example for OpenShift |
| `community/` | Files for the community catalog pull request |
| `docs/` | Documentation |

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
