#!/usr/bin/env bash
#
# Kueue GPU-quota rebalancing demo — the Kueue replacement for the llm-d replica rebalancer.
#
# Builds a kind cluster with 8 fake GPUs, installs Kueue + KEDA, deploys two "model"
# Deployments that share the GPUs through one Kueue cohort, then drives load and shows
# borrowing, gating and reclaim/preemption happening live.
#
#   ./run-demo.sh              full guided demo (pauses between steps)
#   AUTO=1 ./run-demo.sh       same, no pauses
#   ./run-demo.sh setup        cluster + Kueue + KEDA + workloads, then stop
#   ./run-demo.sh status       print current quota / pod / HPA state
#   ./run-demo.sh demand a 6   set model-a's desired replicas to 6 (alias: load)
#   ./run-demo.sh why          explain why the currently-pending pods are pending
#   ./run-demo.sh clean        delete the kind cluster
#
set -euo pipefail

CLUSTER="${CLUSTER:-kueue-demo}"
CTX="kind-${CLUSTER}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.32.0}"
GPUS="${GPUS:-8}"
NS="${NS:-llm-d-demo}"
KUEUE_VERSION="${KUEUE_VERSION:-0.19.1}"
KEDA_VERSION="${KEDA_VERSION:-2.20.2}"
KIND_VERSION="${KIND_VERSION:-v0.32.0}"   # kind < 0.24 cannot run a v1.32 node image
AUTO="${AUTO:-0}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND="kind"

B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[31m'; N=$'\033[0m'

k() { kubectl --context "$CTX" "$@"; }

head1() { printf '\n%s\n%s%s%s\n%s\n' "${C}────────────────────────────────────────────────────────────${N}" "$B" "$*" "$N" "${C}────────────────────────────────────────────────────────────${N}"; }
note() { printf '%s%s%s\n' "$DIM" "$*" "$N"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

pause() {
  [[ "$AUTO" == "1" ]] && { sleep 2; return; }
  printf '\n%s[enter] %s%s' "$Y" "${1:-continue}" "$N"
  read -r _ || true
  printf '\n'
}

# wait_until <timeout-seconds> <description> <shell-condition>
wait_until() {
  local timeout=$1 desc=$2 cond=$3 i=0
  [[ -t 1 ]] && printf '%s… %s%s' "$DIM" "$desc" "$N"
  while (( i < timeout )); do
    if eval "$cond" >/dev/null 2>&1; then printf '\r%s✓%s %s%*s\n' "$G" "$N" "$desc" 12 ' '; return 0; fi
    sleep 1; i=$((i + 1))   # not ((i++)): that returns status 1 when i was 0, and set -e would abort
    [[ -t 1 ]] && printf '\r%s… %s (%ss)%s' "$DIM" "$desc" "$i" "$N"
  done
  printf '\r%s!%s %s — timed out after %ss, showing state anyway\n' "$Y" "$N" "$desc" "$timeout"
  return 0
}

# ---------------------------------------------------------------- preflight

preflight() {
  for bin in docker kubectl helm jq curl; do
    command -v "$bin" >/dev/null || die "$bin is required but not on PATH"
  done
  docker info >/dev/null 2>&1 || die "docker daemon is not running"
  ensure_inotify_limits
  ensure_kind
}

# kind nodes die with "inotify_init: too many open files" when the Docker VM's inotify limits
# are exhausted (common once another kind cluster is already running). Raising them is the
# documented kind workaround; it only lifts a limit, and resets when Docker restarts.
ensure_inotify_limits() {
  local cur
  cur=$(docker run --rm --privileged alpine sh -c 'sysctl -n fs.inotify.max_user_instances' 2>/dev/null || echo 0)
  if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= 4096 )); then
    ok "inotify limits already sufficient (max_user_instances=$cur)"; return
  fi
  docker run --rm --privileged alpine sh -c \
    'sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192' >/dev/null 2>&1 \
    || warn "could not raise inotify limits; kubelet may fail with 'too many open files'"
  ok "raised inotify limits in the Docker VM (was $cur)"
}

# The node image this demo pins needs kind >= 0.24. If the system kind is older (or absent),
# fetch a pinned binary into demo/.bin instead of touching the system install.
ensure_kind() {
  local v minor os arch
  if command -v kind >/dev/null 2>&1; then
    v=$(kind version 2>/dev/null | awk '{print $2}')
    minor=$(sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/' <<<"${v:-}")
    if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 24 )); then
      KIND=$(command -v kind); ok "using system kind $v"; return
    fi
    warn "system kind ${v:-unknown} is too old for $NODE_IMAGE — fetching $KIND_VERSION locally"
  fi
  if [[ -x "$DIR/.bin/kind" ]]; then KIND="$DIR/.bin/kind"; ok "using $($KIND version | awk '{print $2}') from demo/.bin"; return; fi
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m); [[ "$arch" == "x86_64" ]] && arch=amd64; [[ "$arch" == "aarch64" ]] && arch=arm64
  mkdir -p "$DIR/.bin"
  if curl -fsSL -o "$DIR/.bin/kind" \
       "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${os}-${arch}"; then
    chmod +x "$DIR/.bin/kind"
    ok "downloaded kind $KIND_VERSION to demo/.bin/kind (system kind untouched)"
  elif command -v go >/dev/null 2>&1; then
    # some networks block GitHub release assets; building from the module proxy also works
    warn "release download failed — building kind $KIND_VERSION with go instead"
    GOBIN="$DIR/.bin" go install "sigs.k8s.io/kind@${KIND_VERSION}" \
      || die "could not build kind ${KIND_VERSION}"
    ok "built kind $KIND_VERSION into demo/.bin/kind (system kind untouched)"
  else
    die "could not obtain kind ${KIND_VERSION}: download blocked and no go toolchain available.
    Install kind >= 0.24 yourself (brew install kind), or set NODE_IMAGE to an image your kind supports."
  fi
  KIND="$DIR/.bin/kind"
}

# ---------------------------------------------------------------- setup

create_cluster() {
  head1 "1/5  kind cluster with ${GPUS} fake GPUs"
  if "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    ok "cluster '$CLUSTER' already exists — reusing"
  else
    note "kind create cluster --name $CLUSTER --image $NODE_IMAGE"
    "$KIND" create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --wait 120s
    ok "cluster created"
  fi
  k wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

  # Advertise a fake extended resource. This is the documented way to add an extended
  # resource to a node (no device plugin needed) — kubelet leaves resources it does not
  # manage alone, and copies the capacity into allocatable.
  local node
  node=$(k get nodes -o jsonpath='{.items[0].metadata.name}')
  k patch node "$node" --subresource=status --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"${GPUS}\"}]" >/dev/null
  local adv
  adv=$(k get node "$node" -o json | jq -r '.status.allocatable["nvidia.com/gpu"] // "none"')
  [[ "$adv" == "$GPUS" ]] || die "failed to advertise fake GPUs on $node (allocatable='${adv:-none}')"
  ok "node $node advertises nvidia.com/gpu: $adv"
}

install_kueue() {
  head1 "2/5  Kueue ${KUEUE_VERSION}"
  if k get deploy -n kueue-system kueue-controller-manager >/dev/null 2>&1; then
    ok "Kueue already installed"
  else
    helm install kueue "oci://registry.k8s.io/kueue/charts/kueue" \
      --version "$KUEUE_VERSION" --kube-context "$CTX" \
      -n kueue-system --create-namespace --wait --timeout 5m >/dev/null
    ok "Kueue installed"
  fi
  k wait --for=condition=Available -n kueue-system deploy/kueue-controller-manager --timeout=180s >/dev/null
  for crd in clusterqueues localqueues workloads resourceflavors; do
    k wait --for=condition=established "crd/${crd}.kueue.x-k8s.io" --timeout=60s >/dev/null
  done
  note "integrations enabled by default (no config edit needed):"
  k get cm -n kueue-system kueue-manager-config -o jsonpath='{.data.controller_manager_config\.yaml}' \
    | awk '/^ *integrations:/{f=1} f && /^ *- "?(pod|deployment)"?$/{print "    " $0}' || true
  ok "the 'deployment' integration turns every replica Pod into a Kueue Workload"
}

install_keda() {
  head1 "3/5  KEDA ${KEDA_VERSION}"
  if k get deploy -n keda keda-operator >/dev/null 2>&1; then
    ok "KEDA already installed"
  else
    helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
    helm repo update kedacore >/dev/null 2>&1 || true
    helm install keda kedacore/keda --version "$KEDA_VERSION" --kube-context "$CTX" \
      -n keda --create-namespace --wait --timeout 5m >/dev/null
    ok "KEDA installed"
  fi
  k wait --for=condition=Available -n keda deploy/keda-operator --timeout=180s >/dev/null
  k wait --for=condition=Available -n keda deploy/keda-operator-metrics-apiserver --timeout=180s >/dev/null
  ok "KEDA will own one HPA per model — Kueue never touches it"
}

deploy_workloads() {
  head1 "4/5  quota objects, models, load generators, ScaledObjects"
  k apply -f "$DIR/manifests/00-kueue-quota.yaml" >/dev/null
  ok "ResourceFlavor + 2 ClusterQueues (floor 4 GPU each, cohort llm-d-gpu) + 2 LocalQueues"
  k apply -f "$DIR/manifests/10-models.yaml"   >/dev/null
  ok "model-a / model-b Deployments — 1 GPU per replica, labelled kueue.x-k8s.io/queue-name"
  k apply -f "$DIR/manifests/30-scaledobjects.yaml" >/dev/null
  ok "KEDA ScaledObjects, minReplicas=1 maxReplicas=8 (the physical GPU ceiling)"

  wait_until 120 "waiting for the baseline replica of each model to be admitted" \
    '[[ $(k get pods -n '"$NS"' -l llm-d.ai/model --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge 2 ]]'
  wait_until 90 "waiting for KEDA to create the HPAs" \
    '[[ $(k get hpa -n '"$NS"' --no-headers 2>/dev/null | wc -l) -ge 2 ]]'
}

# ---------------------------------------------------------------- state display

cq_field() {  # $1 = clusterqueue, $2 = total|borrowed
  k get clusterqueue "$1" -o json 2>/dev/null | jq -r --arg f "$2" '
    [.status.flavorsUsage[]?.resources[]? | select(.name=="nvidia.com/gpu") | .[$f] // "0"] | first // "0"
    | tostring' | sed 's/[^0-9].*//'
}
gpu_used()     { cq_field "$1" total; }
gpu_borrowed() { cq_field "$1" borrowed; }

pods_line() {  # $1 = model name, $2 = clusterqueue, $3 = GPUs in use (read once by the caller)
  local app=$1 cq=$2 used=$3 running pending gated desired nominal borrowed
  running=$(k get pods -n "$NS" -l "app=$app" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pending=$(k get pods -n "$NS" -l "app=$app" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  gated=$(k get pods -n "$NS" -l "app=$app" -o json 2>/dev/null \
    | jq '[.items[] | select((.spec.schedulingGates // []) | length > 0)] | length')
  desired=$(k get deploy -n "$NS" "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')
  nominal=$(k get clusterqueue "$cq" -o json 2>/dev/null \
    | jq -r '[.spec.resourceGroups[0].flavors[0].resources[] | select(.name=="nvidia.com/gpu") | .nominalQuota] | first | tostring')
  borrowed=$(gpu_borrowed "$cq")
  [[ "$used"     =~ ^[0-9]+$ ]] || used=0
  [[ "$nominal"  =~ ^[0-9]+$ ]] || nominal=0
  [[ "$borrowed" =~ ^[0-9]+$ ]] || borrowed=0
  local flag=""
  (( borrowed > 0 )) && flag="${Y}  ← borrowing ${borrowed} from the cohort${N}"
  printf '  %-9s HPA wants %-2s │ running %-2s  gated %-2s │ GPUs %s (floor %s)%s\n' \
    "$app" "$desired" "$running" "$gated" "$used" "$nominal" "$flag"
  [[ "$pending" != "$gated" ]] && printf '            %s(%s pending, %s of them gated by Kueue)%s\n' "$DIM" "$pending" "$gated" "$N"
  return 0
}

show_state() {
  # read each queue's usage once so the pool total and the per-model lines always agree
  local ua ub
  ua=$(gpu_used model-a-cq); ub=$(gpu_used model-b-cq)
  printf '\n%sGPU pool: %s/%s in use%s\n' "$B" "$(( ua + ub ))" "$GPUS" "$N"
  pods_line model-a model-a-cq "$ua"
  pods_line model-b model-b-cq "$ub"
  printf '\n%s' "$DIM"
  k get clusterqueues -o wide 2>/dev/null | sed 's/^/  /'
  printf '%s' "$N"
}

why_pending() {
  head1 "why are those pods pending?"
  local w
  w=$(k get workloads -n "$NS" -o json | jq -r '
    .items[] | select((.status.conditions // []) | any(.type=="QuotaReserved" and .status!="True"))
    | .metadata.name' | head -1)
  if [[ -z "$w" ]]; then ok "nothing is waiting for quota right now"; return; fi
  note "kubectl describe workload $w -n $NS"
  k get workload "$w" -n "$NS" -o json | jq -r '
    "  workload:  \(.metadata.name)",
    "  queue:     \(.spec.queueName)",
    (.status.conditions[]? | "  \(.type)=\(.status)  reason=\(.reason)\n    \(.message)")'
  local pod
  pod=$(k get pods -n "$NS" -o json | jq -r '
    [.items[] | select((.spec.schedulingGates // []) | length > 0)][0].metadata.name // empty')
  if [[ -n "$pod" ]]; then
    printf '\n'
    note "the pod itself is held by a scheduling gate, not by the scheduler:"
    k get pod "$pod" -n "$NS" -o jsonpath='{.metadata.name}{"  gates: "}{.spec.schedulingGates[*].name}{"\n"}' | sed 's/^/  /'
  fi
}

# The demand dial: patch the ScaledObject's minReplicaCount. KEDA pushes it to the HPA's
# minReplicas, and the HPA scales the Deployment — so "model-x now wants N replicas" is one
# field, with no load-generator pods needed to fake a metric.
set_load() {  # $1 = a|b, $2 = desired replicas
  local m=$1 n=$2
  [[ "$m" =~ ^[ab]$ ]] || die "model must be 'a' or 'b', got '$m'"
  [[ "$n" =~ ^[0-9]+$ ]] || die "replicas must be a number, got '$n'"
  k patch scaledobject "model-${m}" -n "$NS" --type=merge \
    -p "{\"spec\":{\"minReplicaCount\":${n}}}" >/dev/null
  note "model-${m} demand → ${n} replicas  (ScaledObject minReplicaCount, applied by KEDA to the HPA)"
}

# ---------------------------------------------------------------- the story

demo_baseline() {
  head1 "5/5  baseline — both models at minReplicas=1"
  show_state
  note "Each model holds 1 of its 4 guaranteed GPUs. 6 GPUs are idle and lendable."
  pause "raise model-a's demand"
}

demo_borrow() {
  head1 "BORROWING — model-a bursts past its floor into model-b's idle GPUs"
  set_load a 8
  wait_until 150 "model-a scaling up and borrowing from the cohort" \
    '[[ $(gpu_used model-a-cq) -ge 7 ]]'
  show_state
  cat <<EOF
${B}What happened${N}
  KEDA asked for 8 replicas of model-a. Its ClusterQueue floor is only 4, but model-b is
  idle at 1, so 7 GPUs were free in the cohort — Kueue admitted 7 and ${B}gated the 8th${N}.
  The old rebalancer would have patched maxReplicas down to 7 on a 15s loop; here the HPA
  is untouched and Kueue simply did not admit the pod that had no GPU.
EOF
  pause "see why the 8th pod is pending"
  why_pending
  pause "now wake up model-b and watch it reclaim its floor"
}

demo_reclaim() {
  head1 "RECLAIM — model-b takes its guaranteed GPUs back (preemption)"
  set_load b 6
  wait_until 180 "model-b preempting model-a's borrowed replicas" \
    '[[ $(gpu_used model-b-cq) -ge 4 ]]'
  show_state
  cat <<EOF
${B}What happened${N}
  model-b's new pods fit inside its own 4-GPU floor, and model-a was over its floor on
  borrowed quota, so ${B}reclaimWithinCohort: Any${N} let Kueue preempt model-a's borrowed
  replicas. Both models now sit exactly on their floor (4 + 4 = 8), and the demand neither
  can satisfy is queued rather than over-provisioning the cluster.
  This is the "No preemption" limitation of the experimental rebalancer, fixed.
EOF
  note "preemption events (Kueue evicting model-a's borrowed workloads):"
  k get events -n "$NS" -o json 2>/dev/null \
    | jq -r '[.items[] | select((.reason // "") | test("Preempt|Evicted";"i"))] | .[-4:][]? | "  \(.reason): \(.message)"' \
    || true
  pause "let model-a go idle and watch model-b borrow in the other direction"
}

demo_release() {
  head1 "RELEASE — idle model's GPUs flow to the busy one"
  set_load a 1   # not 0: minReplicaCount 0 would scale model-a away entirely
  wait_until 180 "model-a scaling down, model-b borrowing the freed GPUs" \
    '[[ $('"$(declare -f gpu_used)"'; gpu_used model-b-cq) -ge 6 ]] 2>/dev/null'
  show_state
  cat <<EOF
${B}What happened${N}
  model-a fell back to minReplicas=1 and released 3 GPUs. model-b, which still wants 6,
  borrowed above its own floor without anyone editing a quota or an HPA. Same effect as the
  rebalancer's "freed GPUs allow other HPAs a higher ceiling" — but event-driven.
EOF
}

demo_summary() {
  head1 "recap"
  cat <<EOF
  Total config to replace the replica rebalancer:

    1  ResourceFlavor
    2  ClusterQueues        floor 4 GPU each, same cohortName, reclaimWithinCohort: Any
    2  LocalQueues          one per model, in the workload namespace
    1  label per Deployment  kueue.x-k8s.io/queue-name  (on the pod template)

  No coordinator loop, no HPA patching, no annotation propagation, no KEDA conflict.

  ${B}Keep playing${N}
    $0 demand a 8    # burst model-a
    $0 demand b 5    # contend
    $0 status        # quota + pods + queues
    $0 why           # why a pod is gated
    watch -n2 'kubectl --context $CTX get clusterqueues -o wide; kubectl --context $CTX get pods -n $NS'
    $0 clean         # delete the cluster
EOF
}

# ---------------------------------------------------------------- entrypoints

case "${1:-demo}" in
  demo)
    preflight; create_cluster; install_kueue; install_keda; deploy_workloads
    demo_baseline; demo_borrow; demo_reclaim; demo_release; demo_summary ;;
  setup)
    preflight; create_cluster; install_kueue; install_keda; deploy_workloads; show_state ;;
  status) show_state ;;
  why)    why_pending ;;
  demand|load)
    [[ $# -eq 3 ]] || die "usage: $0 demand <a|b> <replicas>"
    set_load "$2" "$3"; sleep 20; show_state ;;   # the HPA syncs every 15s
  clean)
    ensure_kind; "$KIND" delete cluster --name "$CLUSTER"; ok "cluster '$CLUSTER' deleted" ;;
  *) die "usage: $0 [demo|setup|status|why|demand <a|b> <n>|clean]" ;;
esac
