# Installation

## Before you start

* OpenShift 4.22, the only supported version. OLM refuses to install the
  operator when the cluster does not serve the Gateway API v1 kinds, including
  `BackendTLSPolicy`.
* Cluster administrator rights: the operator installs CRDs, cluster roles and
  a mutating webhook.
* **cert-manager.** Install the cert-manager Operator for Red Hat OpenShift
  (catalog `redhat-operators`, package `openshift-cert-manager-operator`)
  before you create the `AgentRouter` resource. cert-manager issues and renews
  the certificate of the Agent Router webhook. To work without cert-manager,
  see [Without cert-manager](#without-cert-manager).
* **Envoy Gateway**, with the extension settings for the Agent Router:
  `extensionApis.enableBackend`, `extensionApis.enableEnvoyPatchPolicy`, the
  `extensionManager` hooks, and the extension manager service
  `ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local:1063`.
  With the Envoy Gateway operator, its example
  `samples/ocp/envoygateway-with-agent-router.yaml` has all of them.

The operator does not declare these prerequisites as OLM dependencies: OLM
would install a dependency in the same namespace as this operator, and both
cert-manager and Envoy Gateway have their own namespaces.

## 1. Install the operator

The operator supports only the OwnNamespace install mode: it reconciles the
`AgentRouter` resource of its own namespace. The suggested namespace is
`envoy-ai-gateway-system`, which the extension settings of Envoy Gateway use.

From the web console: **Operators → OperatorHub**, search for "The Agent
Router (Community)", and choose **A specific namespace on the cluster** with
the namespace `envoy-ai-gateway-system`.

From the command line:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: envoy-ai-gateway-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: agent-router-operator
  namespace: envoy-ai-gateway-system
spec:
  targetNamespaces:
    - envoy-ai-gateway-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: agent-router-operator
  namespace: envoy-ai-gateway-system
spec:
  name: agent-router-operator
  channel: alpha
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
```

To install with a policy, see [acm-policy.md](acm-policy.md).

## 2. Create the AgentRouter resource

Create one `AgentRouter`, named `agent-router`, in the namespace of the
operator. The CRD refuses any other name. The spec holds the values of the
operator chart; the values of the upstream chart go under `ai-gateway-helm`.

```yaml
apiVersion: agentrouter.ccangemi.github.io/v1alpha1
kind: AgentRouter
metadata:
  name: agent-router
  namespace: envoy-ai-gateway-system
spec: {}
```

Wait until the release is deployed and the certificate is ready:

```console
$ oc get agentrouter -n envoy-ai-gateway-system
NAME           DEPLOYED   REASON              AGE
agent-router   True       InstallSuccessful   1m
$ oc get certificate -n envoy-ai-gateway-system
NAME                                    READY   SECRET                                  AGE
self-signed-cert-for-mutating-webhook   True    self-signed-cert-for-mutating-webhook   1m
```

The operator installs:

* the Agent Router controller (`ai-gateway-controller`);
* a cert-manager `Issuer` and `Certificate` for the webhook; the cert-manager
  CA injector writes the CA into the webhook configuration;
* the mutating webhook `envoy-ai-gateway-gateway-pod-mutator.envoy-ai-gateway-system`;
* a secret with the MCP session encryption seed. The chart keeps the seed at
  every upgrade.

### Where Envoy Gateway runs

By default the controller expects Envoy Gateway in `envoy-gateway-system`. If
Envoy Gateway runs in another namespace, set both values:

```yaml
spec:
  ai-gateway-helm:
    envoyGateway:
      namespace: my-envoy-gateway
    controller:
      quotaRateLimitServiceAddr: envoy-ai-gateway-ratelimit.my-envoy-gateway
```

### Scope of the webhook

The webhook has `failurePolicy: Fail` and selects the pods with the label
`app.kubernetes.io/managed-by: envoy-gateway`, in all namespaces: the Envoy
proxies. To limit it to the namespaces of your Gateways, add a namespace
selector:

```yaml
spec:
  ai-gateway-helm:
    controller:
      mutatingWebhook:
        namespaceSelector:
          matchExpressions:
            - key: kubernetes.io/metadata.name
              operator: In
              values: ["my-gateways"]
```

### Without cert-manager

Set `ai-gateway-helm.controller.mutatingWebhook.certManager.enable: false`.
The chart then generates a self-signed certificate that is valid for 365 days,
and nothing renews it. When it expires, the API server refuses every new Envoy
proxy pod. See [upgrade.md](upgrade.md#the-webhook-certificate) for the
renewal and for a change between the two modes.

## 3. Create a Gateway

Create a GatewayClass for Envoy Gateway, a Gateway, an `AIServiceBackend` and
an `AIGatewayRoute`. The Envoy proxy of the Gateway needs the `nonroot-v2` SCC
(see the documentation of the Envoy Gateway operator). Where the proxy runs,
and the name of its service account, depend on the deployment mode of Envoy
Gateway:

* Gateway Namespace Mode: in the namespace of the Gateway, with a service
  account named like the Gateway. Bind that service account.
* ControllerNamespace mode (the upstream default): in the Envoy Gateway
  namespace, with generated names. Bind the group
  `system:serviceaccounts:envoy-gateway-system` there.
 The directory
[samples/ocp/test](../samples/ocp/test) has a complete example, with a test
backend that answers chat completions.

## 4. Network policies

When the namespaces have a default-deny policy, allow these flows:

| From | To | Port |
|---|---|---|
| The kube-apiserver (host network) | The Agent Router controller | 9443 (webhook) |
| Envoy Gateway (`envoy-gateway-system`) | The Agent Router controller | 1063 (extension server) |
| The Envoy proxies | Envoy Gateway | 18000 (xDS) |

## Uninstall

1. Delete the `AIGatewayRoute` resources and the Gateways that use them.
2. Remove the extension settings from Envoy Gateway, or Envoy Gateway cannot
   program any Gateway without the Agent Router controller.
3. Delete the `AgentRouter` resource. The operator uninstalls the Helm
   release, the webhook configuration included.
4. Uninstall the operator (delete the Subscription and the
   ClusterServiceVersion).

The CRDs stay: OLM never deletes CRDs. See
[troubleshooting.md](troubleshooting.md#leftovers-after-uninstall).
