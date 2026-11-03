# Troubleshooting

## The operator does not install

**OLM reports `RequirementsNotMet` for native APIs.** The cluster does not
serve the Gateway API v1 kinds. The operator needs OpenShift 4.22 or later.

**The OperatorGroup does not fit.** The operator supports only the
OwnNamespace install mode. The OperatorGroup must target its own namespace
(`spec.targetNamespaces: [envoy-ai-gateway-system]`).

## The AgentRouter resource does not become Deployed

Read the conditions of the resource and the operator log:

```console
$ oc get agentrouter agent-router -n envoy-ai-gateway-system -o yaml
$ oc logs -n envoy-ai-gateway-system deployment/agent-router-operator-controller-manager
```

**`the AgentRouter resource must be named agent-router`.** The CRD accepts
only this name.

**`the cluster does not serve cert-manager.io/v1/Certificate`.** cert-manager
is not installed. Install the cert-manager Operator for Red Hat OpenShift, or
turn cert-manager off (see [install.md](install.md#without-cert-manager)).

**`invalid ownership metadata` for the secret
`self-signed-cert-for-mutating-webhook`.** You turned cert-manager off, and Helm
cannot take over the secret that cert-manager created. See
[upgrade.md](upgrade.md#turn-cert-manager-off). The same error for other
objects means that an earlier manual installation of the Agent Router is still
there: remove it first.

## The controller does not start

**The pod stays in `ContainerCreating`.** The pod waits for the secret
`self-signed-cert-for-mutating-webhook`. With cert-manager, check the
`Certificate`:

```console
$ oc get certificate,certificaterequest -n envoy-ai-gateway-system
$ oc get deployment -n cert-manager
```

**`unable to validate against any security context constraint`.** A value of
the resource sets `runAsUser` or `runAsGroup` again. Remove it.

**The controller log says that it cannot find the webhook configuration.**
The controller needs the configuration
`envoy-ai-gateway-gateway-pod-mutator.<namespace>`, which the chart creates.
Check that the release is deployed.

## Envoy proxy pods

**Pod creation fails with `failed calling webhook`.** The API server cannot
call the Agent Router webhook:

* the controller is not ready;
* the CA bundle of the webhook configuration does not match the certificate.
  With cert-manager, check that the CA injector runs; without it, see
  [upgrade.md](upgrade.md#without-cert-manager);
* a network policy blocks the API server (port 9443).

**The proxy pod has no `ai-gateway-extproc` container.** The pod was created
before the webhook was ready, or outside its selector (namespace selector).
Delete the pod; the new pod gets the sidecar.

## Gateways and routes

**No Gateway is programmed.** Envoy Gateway calls the Agent Router controller
for every translation (port 1063). Check that the extension manager of Envoy
Gateway points to `ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local`,
and the network policies.

**The `AIGatewayRoute` is not accepted.** Check its status and the
controller log. Envoy Gateway must have `extensionApis.enableBackend` and
`extensionApis.enableEnvoyPatchPolicy` set to `true`.

## Leftovers after uninstall

When you delete the `AgentRouter` resource, the operator uninstalls the Helm
release, the webhook configuration included. These objects stay:

* the CRDs `*.aigateway.envoyproxy.io` and
  `agentrouters.agentrouter.ccangemi.github.io`: OLM never deletes CRDs;
* with cert-manager: the secret `self-signed-cert-for-mutating-webhook`
  (cert-manager does not delete it with the `Certificate`);
* in the Gateway namespaces: the filter configuration secrets of the Agent
  Router.

For a full cleanup, after you delete all Gateways and routes:

```console
$ oc delete namespace envoy-ai-gateway-system
$ oc get crd -o name | grep -E '\.aigateway\.envoyproxy\.io$' | xargs oc delete
$ oc delete crd agentrouters.agentrouter.ccangemi.github.io
```

Never delete the `*.gateway.networking.k8s.io` CRDs: they belong to OpenShift.
