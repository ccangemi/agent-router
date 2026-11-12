# OpenShift design notes

This page explains how the operator installs The Agent Router on OpenShift,
and why it differs from a plain `helm install` of the upstream chart.

## A Helm operator around the upstream chart

The operator is the upstream `helm-operator` of Operator SDK, with two inputs:

* [watches.yaml](../watches.yaml): the custom resource to watch
  (`AgentRouter`) and the chart to install for each resource;
* [helm-charts/agent-router](../helm-charts/agent-router): the operator chart.

The operator chart is small. Its only dependency is the upstream chart in
`charts/ai-gateway-helm`, which stays exactly as `helm pull` writes it
(`make chart-check` proves it). The operator chart adds:

* `values.yaml`: the values that OpenShift needs, under `ai-gateway-helm`;
* `templates/validate.yaml`: a clear error when cert-manager is on but the
  cluster does not serve the cert-manager API.

Each `AgentRouter` resource is one Helm release, with the same name and
namespace. The spec of the resource is merged on top of `values.yaml`. The
operator compares the release with the spec at every change and once a
minute, and upgrades the release when they differ.

### Why not overrideValues

`watches.yaml` can force values with `overrideValues`, but `helm-operator`
parses them as strings: `"true"` is not a boolean, and `"null"` does not remove
a default. The values of the operator chart have real types, so the operator
uses no `overrideValues`.

### Dry run in server mode

To detect changes, `helm-operator` renders the chart in a dry run. The upstream
chart reuses objects that exist, with Helm `lookup`:

* the secret with the MCP session encryption seed (a new seed would end every
  MCP session);
* without cert-manager, the secret with the webhook certificate.

In the default (client) mode, `lookup` finds nothing during a dry run, so the
chart would generate a new seed and a new certificate each time, and the
operator would upgrade the release every minute. `watches.yaml` therefore sets
`dryRunOption: server`. The end-to-end test checks that the revision of the
release and the seed stay the same, with and without cert-manager.

### Empty values

When the values are empty, `helm upgrade` keeps the values of the previous
release instead of the chart defaults. The CRD therefore declares
`spec.ai-gateway-helm` with the default `{}`, so that the values are never
empty, and `spec: {}` means "the defaults".

## Values that the operator chart sets

| Value under `ai-gateway-helm` | Operator chart | Why |
|---|---|---|
| `controller.mutatingWebhook.certManager.enable` | `true` (you can turn it off) | Without cert-manager the chart generates a certificate that expires after 365 days, and nobody renews it. When it expires, the API server refuses every new Envoy proxy pod. |
| `controller.podSecurityContext`, `controller.securityContext` | `runAsUser` and `runAsGroup` removed | The `restricted-v2` SCC does not allow the fixed ID 65532. Without them, OpenShift assigns IDs from the namespace range. |
| `controller.image`, `extProc.image` | tag `<version>@<digest>` | Pinned by digest. The bundle lists the same images in `relatedImages`, for disconnected clusters. |

The controller therefore runs with `restricted-v2`. The bundle contains no SCC
and no SCC grant.

## The webhook

The Agent Router controller adds the external processor to the Envoy proxy
pods with a mutating webhook. The upstream chart creates the webhook
configuration with the fixed name
`envoy-ai-gateway-gateway-pod-mutator.<namespace>`, which the controller needs.
It has `failurePolicy: Fail` and selects only the pods with the label
`app.kubernetes.io/managed-by: envoy-gateway`. The gate checks that the chart
renders this webhook and no other.

With cert-manager, the chart creates a self-signed `Issuer` and a
`Certificate` (90 days, renewed by cert-manager). The cert-manager CA injector
writes the CA into the webhook configuration, so a renewal needs no restart.

## The Gateway API belongs to OpenShift

The operator never installs or changes CRDs of the group
`gateway.networking.k8s.io`: the bundle contains only the CRDs of
`agentrouter.ccangemi.github.io` and `aigateway.envoyproxy.io`, and the
operator cannot change CRDs. The ClusterServiceVersion declares the Gateway
API kinds in `nativeAPIs`.

The Agent Router v1.2 is tested upstream with Gateway API v1.6. OpenShift 4.22
has v1.4.1; the HTTP and AI features work (the end-to-end test sends a chat
completion through a Gateway).

## CRDs

The Agent Router CRDs come from the upstream `ai-gateway-crds-helm` chart
(`make update-upstream`). They are part of the bundle, so OLM installs them
before the operator and upgrades them with each operator version.

The operator does not install the Gateway API Inference Extension CRDs
(`InferencePool`). On clusters with OpenShift AI, KServe owns them. The
controller works without them.

## Permissions of the operator

`hack/generate-rbac.sh` builds the ClusterRole of the operator from the chart:
full control of every kind of object that the chart renders, and every
permission that the roles of the chart grant. Kubernetes does not let a user
create a role with permissions that the user does not have.

The upstream ClusterRole of the controller is wide: all verbs on
`aigateway.envoyproxy.io`, `gateway.envoyproxy.io`, the Gateway API resources,
the InferencePool resources, deployments, pods, services and secrets, and read
access to CRDs. The operator therefore has the same permissions. It cannot
change CRDs and has no permission on SCCs; the gate checks both.

## One namespace, one resource

The operator watches only its own namespace (`WATCH_NAMESPACE` comes from the
OperatorGroup). The CRD accepts only the name `agent-router`: the controller
names are fixed, so a second release would conflict.

## Images

| Name in `relatedImages` | Image |
|---|---|
| `operator` | `quay.io/gateway-operators/agent-router-operator` |
| `ai-gateway-controller` | `docker.io/envoyproxy/ai-gateway-controller` |
| `ai-gateway-extproc` | `docker.io/envoyproxy/ai-gateway-extproc` (the sidecar of the Envoy proxies) |

All operand images are pinned by digest. The released bundle pins the operator
image by digest too.
