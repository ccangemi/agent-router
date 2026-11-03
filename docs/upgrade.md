# Upgrades and certificates

## Operator upgrades

Each operator version installs one Agent Router version. OLM upgrades the
operator through the channel `alpha`, following the `replaces` field of each
ClusterServiceVersion.

During an upgrade:

1. OLM upgrades the Agent Router CRDs of the bundle. OLM first checks that the
   existing resources are valid with the new CRDs.
2. OLM replaces the operator deployment.
3. The new operator compares the release with the new chart and upgrades it.
   The MCP session seed stays the same.

Before you approve an upgrade, read the upstream release notes, in particular
the Envoy Gateway version that the new Agent Router needs. Upgrade Envoy
Gateway first when the notes ask for it.

## Changes to the AgentRouter resource

A change to the spec gives one Helm upgrade. The status shows the result:

```console
$ oc get agentrouter agent-router -n envoy-ai-gateway-system -o jsonpath='{.status.conditions}'
```

Setting `spec: {}` goes back to the chart defaults, cert-manager included. The
CRD makes sure that the values are never empty, because with empty values
Helm would keep the values of the previous release.

## The webhook certificate

### With cert-manager (the default)

cert-manager renews the certificate about 30 days before it expires (after 90
days), and the CA injector updates the webhook configuration. Nothing to do.
Check it with:

```console
$ oc get certificate self-signed-cert-for-mutating-webhook -n envoy-ai-gateway-system
```

### Without cert-manager

The certificate is valid for 365 days (its CA for 10 years) and nothing renews
it. To renew it, delete its secret when no Envoy proxy is in a rollout:

```console
$ oc -n envoy-ai-gateway-system delete secret self-signed-cert-for-mutating-webhook
```

The operator sees the missing secret and upgrades the release within a minute:
the chart generates a new certificate and CA, and writes the new CA bundle into
the webhook configuration. Until then, new Envoy proxy pods can be refused.
Check that a new proxy pod starts after that.

To watch the expiry date:

```console
$ oc -n envoy-ai-gateway-system get secret self-signed-cert-for-mutating-webhook \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
```

### Turn cert-manager on

Set `ai-gateway-helm.controller.mutatingWebhook.certManager.enable: true`, or
remove the value. The Helm upgrade deletes the generated secret and creates the
`Issuer` and the `Certificate`; cert-manager writes a new secret and the CA
injector updates the webhook configuration. For about a minute new Envoy proxy
pods can be refused, so do it when no proxy is in a rollout.

### Turn cert-manager off

Helm cannot take over the secret that cert-manager created. Follow these steps
in this order, when no Envoy proxy is in a rollout:

```console
$ NS=envoy-ai-gateway-system
$ oc -n $NS patch agentrouter agent-router --type merge \
    -p '{"spec":{"ai-gateway-helm":{"controller":{"mutatingWebhook":{"certManager":{"enable":false}}}}}}'
$ oc -n $NS delete certificate self-signed-cert-for-mutating-webhook
$ oc -n $NS delete secret self-signed-cert-for-mutating-webhook
```

1. The change of the value comes first. The upgrade stops with
   `invalid ownership metadata` for the secret, and the operator reports the
   condition `Irreconcilable`. It does not touch the release, so it does not
   create the `Certificate` again.
2. Delete the `Certificate` before its secret: while the `Certificate`
   exists, cert-manager writes the secret again at once.
3. When the secret is gone, the operator completes the upgrade with a
   generated certificate, within a minute.

If you delete the `Certificate` before you change the value, the operator
creates it again from the release, and cert-manager writes the secret again.
Between step 1 and step 3, new Envoy proxy pods can be refused.
