#!/usr/bin/env bash
# End-to-end test on an OpenShift 4.22 cluster.
#
#   KUBECONFIG=<file> hack/e2e/ocp.sh <command>
#
# Commands:
#   prereq     check cert-manager and Envoy Gateway (with the Agent Router extension settings)
#   install    install the operator through OLM (OwnNamespace) and wait until it is ready
#   cr         create the AgentRouter resource and wait until the release is deployed
#   verify     check the release, the webhook certificate, the pods, the OpenShift Gateway API
#              and the revision stability
#   test       send a chat completion through a Gateway, with the examples in samples/ocp/test
#   uninstall  delete the examples and the AgentRouter resource, then uninstall the operator
#   all        prereq, install, cr, verify and test
#
# Variables:
#   CATALOG_IMAGE  a test catalog (hack/e2e/build-on-cluster.sh). Without it, the
#                  operator comes from CATALOG_NAME (default community-operators)
#                  in CATALOG_NAMESPACE (default openshift-marketplace).
#   CR_FILE        the AgentRouter resource (default: the sample of config/samples)
#   EG_NAMESPACE   the namespace of Envoy Gateway (default envoy-gateway-system)
#   STABILITY_SECONDS  how long verify watches the release revision (default 200)
#
# Install Envoy Gateway first, for example with the Envoy Gateway operator and
# its samples/ocp/envoygateway-with-agent-router.yaml. The script never logs
# in. Log in first, with a kubeconfig file that is not in this repository.

# shellcheck source=hack/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ

EG_NAMESPACE=${EG_NAMESPACE:-envoy-gateway-system}
SNAPSHOT_FILE=${SNAPSHOT_FILE:-$ROOT_DIR/build/gateway-api-snapshot.tsv}

# --- Prerequisites ----------------------------------------------------------------
cert_manager_api() { k get crd certificates.cert-manager.io issuers.cert-manager.io; }
cert_manager_ready() { [[ $(k get deployment -n cert-manager -o jsonpath='{.items[*].status.availableReplicas}' | wc -w) -ge 3 ]]; }
eg_points_here() {
  k get configmap envoy-gateway-config -n "$EG_NAMESPACE" -o jsonpath='{.data.envoy-gateway\.yaml}' \
    | "$YQ" -e ".extensionManager.service.fqdn.hostname == \"ai-gateway-controller.$NS.svc.cluster.local\""
}
cmd_prereq() {
  expect "the cluster serves the cert-manager API" cert_manager_api
  expect "cert-manager runs (controller, webhook, cainjector)" cert_manager_ready
  expect "Envoy Gateway runs in $EG_NAMESPACE" deployment_available envoy-gateway "$EG_NAMESPACE"
  expect "the Envoy Gateway extension manager points to the Agent Router in $NS" eg_points_here
}

cmd_install() {
  mkdir -p "$(dirname "$SNAPSHOT_FILE")"
  if [[ ! -s $SNAPSHOT_FILE ]]; then
    gateway_api_snapshot >"$SNAPSHOT_FILE"
    log "saved a snapshot of the Gateway API CRDs in ${SNAPSHOT_FILE#"$ROOT_DIR"/}"
  fi
  install_operator
}

cmd_cr() { create_cr; }

# --- Checks on the release --------------------------------------------------------
ingress_healthy() {
  [[ $(k get clusteroperator ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Degraded")].status}') == TrueFalse ]]
}
certificate_ready() {
  [[ $(k get certificate "$WEBHOOK_SECRET" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]
}
# The CA bundle of the webhook configuration must be the CA of the serving
# certificate, or the API server refuses every Envoy proxy pod.
webhook_ca_matches() {
  local bundle ca
  bundle=$(k get mutatingwebhookconfiguration "$WEBHOOK_NAME" -o jsonpath='{.webhooks[0].clientConfig.caBundle}')
  ca=$(k get secret "$WEBHOOK_SECRET" -n "$NS" -o jsonpath='{.data.ca\.crt}')
  [[ -n $bundle && $bundle == "$ca" ]]
}
mcp_seed() { k get secret ai-gateway-controller-mcp-session-encryption -n "$NS" -o jsonpath='{.data.seed}'; }

cmd_verify() {
  log "checking the release"
  expect "$CR_KIND $CR_NAME is Deployed" cr_deployed
  expect "deployment ai-gateway-controller is available" deployment_available ai-gateway-controller
  expect "the controller pods run with the restricted-v2 SCC" pods_use_restricted_scc
  if [[ $(k get "$CR_KIND.$CR_GROUP" "$CR_NAME" -n "$NS" -o jsonpath='{.spec.ai-gateway-helm.controller.mutatingWebhook.certManager.enable}') != false ]]; then
    expect "cert-manager issued the webhook certificate" certificate_ready
  fi
  expect "the webhook CA bundle is the CA of the serving certificate" webhook_ca_matches
  echo "Pods in $NS:"
  k get pods -n "$NS" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc' || true

  log "checking the OpenShift Gateway API"
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change (name, uid, generation, bundle version)" \
      diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  else
    fail_check "no snapshot of the Gateway API CRDs; run the install command first"
  fi
  expect "the Ingress Operator admission policy still exists" \
    k get validatingadmissionpolicy openshift-ingress-operator-gatewayapi-crd-admission
  expect "ClusterOperator ingress is available and not degraded" ingress_healthy
  expect "no CRD was created by a Helm release" test -z "$(helm_created_crds)"

  local seed
  seed=$(mcp_seed)
  expect "the release keeps its revision when nothing changes" revision_stable
  expect "the MCP session seed did not change" test "$(mcp_seed)" = "$seed"
}

# --- Functional test --------------------------------------------------------------
gateway_programmed() {
  [[ $(k get gateway "$GATEWAY_NAME" -n "$TEST_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}') == True ]]
}
route_accepted() {
  k get aigatewayroute "$GATEWAY_NAME" -n "$TEST_NS" -o jsonpath='{.status.conditions[*].type}' | grep -q Accepted
}
proxy_pod_has_extproc() {
  k get pods -n "$TEST_NS" -l "gateway.envoyproxy.io/owning-gateway-name=$GATEWAY_NAME" \
    -o jsonpath='{.items[*].spec.initContainers[*].name}{" "}{.items[*].spec.containers[*].name}' | grep -q extproc
}

# chat_request runs curl in a short-lived pod and prints the HTTP status and
# the body. The body asks for "test-model", which the AIGatewayRoute sends to
# the test backend.
chat_request() {
  local pod=curl-$RANDOM image=${CURL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}
  k run "$pod" -n "$TEST_NS" --restart=Never --quiet --image="$image" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"'"$image"'","command":["curl","-sS","-m","20","-w","\\nHTTP %{http_code}\\n","-H","Content-Type: application/json","-d","{\"model\":\"test-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}","http://'"$GATEWAY_NAME"'.'"$TEST_NS"'.svc.cluster.local/v1/chat/completions"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    >/dev/null
  local start
  start=$(date +%s)
  until [[ $(k get pod "$pod" -n "$TEST_NS" -o jsonpath='{.status.phase}') =~ ^(Succeeded|Failed)$ ]]; do
    (($(date +%s) - start > 120)) && break
    sleep 2
  done
  k logs "$pod" -n "$TEST_NS" 2>&1 || true
  k delete pod "$pod" -n "$TEST_NS" --wait=false >/dev/null 2>&1 || true
}
chat_ok() {
  local out
  out=$(chat_request)
  echo "$out" >"${CHAT_OUTPUT:-/dev/null}"
  grep -q '^HTTP 200' <<<"$out" && grep -q '"choices"' <<<"$out"
}

cmd_test() {
  log "running the functional test in namespace $TEST_NS"
  local f
  for f in "$ROOT_DIR"/samples/ocp/test/*.yaml; do
    k apply -f "$f" >/dev/null
  done
  wait_for "deployment testupstream is available" deployment_available testupstream "$TEST_NS" || true
  wait_for "Gateway $GATEWAY_NAME is programmed" gateway_programmed || true
  wait_for "AIGatewayRoute $GATEWAY_NAME is accepted" route_accepted || true
  wait_for "proxy deployment $GATEWAY_NAME is available" deployment_available "$GATEWAY_NAME" "$TEST_NS" || true
  expect "the proxy pod has the Agent Router external processor" proxy_pod_has_extproc
  CHAT_OUTPUT=$(mktemp)
  export CHAT_OUTPUT
  if wait_for "a chat completion through the Gateway returns HTTP 200" chat_ok; then
    sed 's/^/    /' "$CHAT_OUTPUT" | head -5
  else
    echo "Last response:"
    sed 's/^/    /' "$CHAT_OUTPUT"
  fi
  rm -f "$CHAT_OUTPUT"
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change after the test" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  fi
}

cmd_uninstall() {
  log "deleting the examples"
  local f
  for f in $(find "$ROOT_DIR/samples/ocp/test" -name '*.yaml' | sort -r); do
    k delete -f "$f" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  done
  log "deleting $CR_KIND $CR_NAME: the operator uninstalls the release"
  k delete "$CR_KIND.$CR_GROUP" "$CR_NAME" -n "$NS" --ignore-not-found --timeout=300s >/dev/null
  release_gone() { [[ -z $(release_revision) ]]; }
  wait_for "the Helm release is uninstalled" release_gone || true
  webhook_gone() { ! k get mutatingwebhookconfiguration "$WEBHOOK_NAME"; }
  expect "the webhook configuration is deleted with the release" webhook_gone
  log "uninstalling the operator"
  k delete subscription "$PACKAGE_NAME" -n "$NS" --ignore-not-found >/dev/null
  k delete csv "$CSV_NAME" -n "$NS" --ignore-not-found >/dev/null
  k delete catalogsource "$PACKAGE_NAME-test" -n "$NS" --ignore-not-found >/dev/null
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change after uninstall" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  fi
  log "left on the cluster on purpose: the CRDs (OLM never deletes CRDs) and the namespace $NS"
}

case ${1:-} in
  prereq) cmd_prereq ;;
  install) cmd_install ;;
  cr) cmd_cr ;;
  verify) cmd_verify ;;
  test) cmd_test ;;
  uninstall) cmd_uninstall ;;
  all) cmd_prereq && [[ $e2e_errors -eq 0 ]] && cmd_install && cmd_cr && cmd_verify && cmd_test ;;
  *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
finish
