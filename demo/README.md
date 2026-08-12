# Kueue GPU-quota rebalancing demo

A self-contained kind demo of the design of 
two model Deployments, each with its own KEDA-driven HPA, sharing one pool of 8 GPUs through
a Kueue cohort — no coordinator loop and no `maxReplicas` patching.

```bash
./run-demo.sh          # guided demo, pauses between steps
AUTO=1 ./run-demo.sh   # same, no pauses (~4 min)
```

Everything else is optional:

| command | what it does |
|---|---|
| `./run-demo.sh setup` | cluster + Kueue + KEDA + workloads, then stop |
| `./run-demo.sh status` | GPU pool, per-model running/gated pods, ClusterQueue state |
| `./run-demo.sh demand a 8` | set model-a's desired replicas to 8 (the demand dial) |
| `./run-demo.sh why` | print why the currently-gated pods are waiting |
| `./run-demo.sh clean` | delete the kind cluster |

Overridable: `CLUSTER`, `NS`, `GPUS`, `NODE_IMAGE`, `KUEUE_VERSION`, `KEDA_VERSION`, `AUTO`.

## What it builds

```
                    8 fake GPUs on one kind node
                                │
              cohort llm-d-gpu (shared pool)
              ┌─────────────────┴─────────────────┐
        model-a-cq  floor 4                 model-b-cq  floor 4
              │  LocalQueue model-a-lq            │  LocalQueue model-b-lq
        Deployment model-a                  Deployment model-b
              ▲  1 GPU / replica                  ▲
        keda-hpa-model-a  min 1 max 8       keda-hpa-model-b  min 1 max 8
              ▲                                   ▲
        ScaledObject model-a                ScaledObject model-b
          minReplicaCount = demand
```

**How demand is expressed.** `./run-demo.sh demand a 8` patches one field on the ScaledObject:

```bash
kubectl patch scaledobject model-a -n llm-d-demo --type=merge \
  -p '{"spec":{"minReplicaCount":8}}'
```

KEDA propagates it to the HPA's `minReplicas`, the HPA scales the Deployment, and 8 pods each
asking for a GPU arrive at Kueue. No load-generator pods and no metrics stack — "model-a now
needs 8 replicas" is stated directly.

Each ScaledObject also carries one inert `cron` trigger, because KEDA requires at least one and
because the trigger must keep serving a metric for the HPA to scale back *down*; its window is
five minutes a year. In llm-d you delete it and use the real signal — a `prometheus` trigger on
EPP queue depth, as in [../llm-d/guides/workload-autoscaling/README.hpa-epp.md](../llm-d/guides/workload-autoscaling/README.hpa-epp.md).
Kueue behaves identically either way: it only ever sees the pods the HPA creates.

## What the demo shows (measured, not predicted)

| Step | Result |
|---|---|
| baseline | `a=1 b=1`, 2/8 GPUs used, 6 lendable |
| `demand a 8` | model-a admits **7** (floor 4 + **3 borrowed**), 8th pod gated. Pool 8/8 |
| `demand b 6` | model-b reclaims by **preemption** → both land exactly on their floor, `a=4 b=4`, surplus demand queued |
| `demand a 1` | model-a → 1, model-b borrows **2** above its floor → `a=1 b=6` |

Reclaim completed in under 15s.

## Why they settle at 4+4

The rule Kueue enforces is: **you may preempt to get up to your own floor, never to get beyond
it.** Beyond your floor you can only take what is *idle*. Two separate settings produce that:

- `reclaimWithinCohort: Any` applies only when the incoming pod fits inside its own
  `nominalQuota` — that is what lets model-b evict model-a's pods.
- `borrowWithinCohort` governs preemption *by* a pod that itself needs to borrow. It defaults to
  `Never` and this demo leaves it alone, so a borrowing pod never evicts anyone; it waits for
  someone to go idle.

| | model-a | model-b | pool | why |
|---|---|---|---|---|
| baseline | 1 | 1 | 2/8 | 6 GPUs idle |
| a wants 8 | **7** (4 own + 3 borrowed) | 1 | 8/8 | b was using 1 of its 4, so 3 of b's were idle and lendable. a's 8th pod is gated — nothing left to borrow |
| b wants 6 | **4** | **4** | 8/8 | b's pods 2–4 fit inside b's own floor → allowed to preempt, and the only over-committed GPUs were a's 3 borrowed ones. b's pods 5–6 would need to borrow, and a is now exactly at its floor → nothing idle → gated |
| a goes idle | 1 | **6** (4 + 2 borrowed) | 7/8 | a released 3, b borrows back up to what it actually wants |

So neither model goes beyond quota in any lasting sense — each briefly holds GPUs the other
isn't using and hands them back the moment the owner asks. They sit at 4+4 under contention
because combined demand was 14 for 8 GPUs and the floors already sum to the whole pool, so
there is by definition nothing idle left to borrow; the surplus 6 pods stay gated. That is the
over-provisioning the replica rebalancer existed to prevent, except the surplus queues instead
of the cluster being oversubscribed.

Note the last row: the pool sits at 7/8 with one GPU idle. Nobody wanted it — the binding
constraint became demand, not quota.

The floors are the dial for a different equilibrium: asymmetric `nominalQuota` (6/2 splits
6+2 under contention), `lendingLimit: 0` to make a floor unborrowable so that model never waits
for a preemption round-trip, `WorkloadPriorityClass` to choose *which* replicas get evicted, or
weights instead of floors (Variant B in the plan). Floors should always sum to physical
capacity — over-subscribing them just moves the gating from Kueue to the scheduler.

You can watch the rule directly: `./run-demo.sh demand a 8` then `./run-demo.sh demand b 8` pins
both models at 4 with 4 gated each, however long you wait.

## Diagnostics

A gated pod explains itself:

```
QuotaReserved=False  reason=Pending
  couldn't assign flavors to pod set main: insufficient unused quota for
  nvidia.com/gpu in flavor gpu-default, 1 more needed

model-a-6cb659df7-d7gxg  gates: kueue.x-k8s.io/admission kueue.x-k8s.io/topology
```

and preemption is visible in events:

```
PreemptedWorkload: Preempted workload llm-d-demo/pod-model-a-… in ClusterQueue model-a-cq
```

## Files

| file | contents |
|---|---|
| `manifests/00-kueue-quota.yaml` | namespace, ResourceFlavor, 2 ClusterQueues (cohort + preemption), 2 LocalQueues |
| `manifests/10-models.yaml` | the two model Deployments — the only Kueue-specific line is the `kueue.x-k8s.io/queue-name` pod-template label |
| `manifests/30-scaledobjects.yaml` | KEDA ScaledObjects — `minReplicaCount` is the demand dial; no mention of quota anywhere |
