# Install with Red Hat Advanced Cluster Management

With Red Hat Advanced Cluster Management (ACM), a governance policy can
install the operator and create the `AgentRouter` resource on the managed
clusters. The `OperatorPolicy` kind manages the OperatorGroup and the
Subscription.

The prerequisites need their own policies, which this one depends on:
cert-manager, and Envoy Gateway with the extension settings for the Agent
Router (for example the policy of the Envoy Gateway operator).

## Example

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-agent-router
  namespace: policies
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  disabled: false
  remediationAction: enforce
  # Wait for cert-manager and Envoy Gateway. Use the names of your policies.
  dependencies:
    - apiVersion: policy.open-cluster-management.io/v1
      kind: Policy
      name: policy-cert-manager
      namespace: policies
      compliance: Compliant
    - apiVersion: policy.open-cluster-management.io/v1
      kind: Policy
      name: policy-envoy-gateway
      namespace: policies
      compliance: Compliant
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: agent-router-namespace
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Namespace
                metadata:
                  name: envoy-ai-gateway-system
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1beta1
        kind: OperatorPolicy
        metadata:
          name: agent-router-operator
        spec:
          remediationAction: enforce
          severity: high
          complianceType: musthave
          operatorGroup:
            name: agent-router-operator
            namespace: envoy-ai-gateway-system
            # OwnNamespace install mode.
            targetNamespaces:
              - envoy-ai-gateway-system
          subscription:
            name: agent-router-operator
            namespace: envoy-ai-gateway-system
            channel: alpha
            source: community-operators
            sourceNamespace: openshift-marketplace
          # Approve only the versions that you have tested.
          upgradeApproval: Automatic
          versions:
            - agent-router-operator.v0.1.0
    - extraDependencies:
        - apiVersion: policy.open-cluster-management.io/v1beta1
          kind: OperatorPolicy
          name: agent-router-operator
          compliance: Compliant
      objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: agent-router-instance
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: agentrouter.ccangemi.github.io/v1alpha1
                kind: AgentRouter
                metadata:
                  name: agent-router
                  namespace: envoy-ai-gateway-system
                spec:
                  ai-gateway-helm:
                    controller:
                      mutatingWebhook:
                        # Only the namespaces of your Gateways.
                        namespaceSelector:
                          matchExpressions:
                            - key: kubernetes.io/metadata.name
                              operator: In
                              values: ["my-gateways"]
```

Bind the policy to your clusters with a `Placement` and a `PlacementBinding`,
as for any other policy.

## Notes

* `versions` limits the ClusterServiceVersions that the policy approves. Add a
  new version to the list after you test it.
* Put your own labels on the controller pods with
  `ai-gateway-helm.controller.podLabels`.
