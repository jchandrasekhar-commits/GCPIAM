# Interview Preparation — GKE DevOps Assignment (GCPIAM)

Model questions, detailed answers, and topic deep-dives for defending this project.
Grounded in the actual repo (`terraform/`, `k8s/`, `grafana/`, `docs/`).

---

## Question 1 — "Walk me through the end-to-end architecture."

**Model answer**

It's a GCP project running two web applications on GKE with full observability, all
defined as Terraform IaC.

- **Network layer:** a custom VPC (`gke-vpc`) with dedicated subnets per cluster
  (`10.10.0.0/20` primary, `10.20.0.0/20` secondary). Egress goes through **Cloud NAT**
  so nodes need no public IPs; **firewall rules** allow east-west traffic and Google's
  health-check probe ranges.
- **Clusters:** a regional primary GKE cluster (`gke-primary`, us-central1) plus an
  optional symmetric secondary (`gke-secondary`, us-east1) toggled by `enable_secondary`
  for multi-region HA. Both are VPC-native, Workload Identity enabled, private nodes with
  master authorized networks.
- **Workloads:** two stateless apps — `webapp-a` (4 replicas) and `webapp-b` (3) — each
  with resource requests/limits, readiness/liveness probes, HPAs, and PodDisruptionBudgets.
  Config comes from a ConfigMap and a Kubernetes Secret, plus a managed Secret Manager
  secret accessed via Workload Identity. Traffic arrives via LoadBalancer Services or a
  single GKE Ingress that path-routes `/a` and `/b`.
- **Observability:** container + LB logs flow to Cloud Logging, a sink exports them to
  BigQuery (`logs_dataset_us`), and Grafana runs SQL for four panels: error rate, pod
  restarts, latency p50/p95/p99, and a utilization trend.

Everything is reproducible with `terraform apply`, documented with an architecture diagram
and a real troubleshooting incident.

**Why it works:** follows the request path (network -> cluster -> workloads -> observability),
names concrete resources, signals depth (HA toggle, Workload Identity, IaC).

**Likely follow-ups:** Why two clusters? Why BigQuery over Cloud Logging? What happens
between the LB and the pod?

---

## Question 2 — "Walk me through your observability stack. Why BigQuery instead of just Cloud Logging?"

**Model answer**

Three pillars — logs, metrics, traces; my design focuses on logs feeding analytics plus
metrics dashboards.

- **Data path:** container stdout/stderr -> GKE logging agent -> Cloud Logging ->
  log sink `export-to-bq` -> BigQuery `logs_dataset_us` -> Grafana SQL. I widened the sink
  filter to include `http_load_balancer` logs for request latency.
- **Why BigQuery, not just Cloud Logging:** Cloud Logging is great for real-time tailing
  and short-term search but has limited retention and isn't built for analytical SQL over
  large ranges. BigQuery adds long-term retention, cheap columnar storage, and full SQL —
  enabling error *rates*, latency *percentiles*, and *trends*, plus joins across log types.
- **Four dashboard panels (each a BigQuery query):**
  1. Application error rate by namespace (from `stderr_*`)
  2. Pod restart / instability events (from `events_*`)
  3. Request latency p50/p95/p99 via `APPROX_QUANTILES` on `httpRequest.latency`
  4. Resource / activity trend (throughput proxy)
- Added a **Cloud Monitoring** dashboard as a second format for native CPU/memory metrics.
- **Cost detail:** logs land in date-sharded tables (`stderr_YYYYMMDD`); every query filters
  on `_TABLE_SUFFIX` so BigQuery only scans needed days (partition pruning).

**Three pillars:** logs = discrete events; metrics = numeric time series; traces = per-request
path across services (Cloud Trace, documented as next step).

**Likely follow-ups:**
- p95/p99 vs averages -> averages hide tail latency that breaks SLOs.
- CPU/mem panel is a proxy -> true CPU/mem are metrics (Cloud Monitoring / Managed
  Prometheus), not logs; called out honestly in query comments.
- BigQuery cost control -> `_TABLE_SUFFIX` pruning, no `SELECT *`, short windows.
- Alerting -> log-based metrics + Cloud Monitoring alert policies, or Grafana alerts.

---

## Topic deep-dive A — Network layer: egress and Cloud NAT

- **VPC** (`gke-vpc`): your own isolated virtual network in GCP.
- **Subnets** (`/20` = ~4,096 IPs each): per-region IP slices; primary `10.10.0.0/20`,
  secondary `10.20.0.0/20`, deliberately non-overlapping.
- **Ingress vs egress:** ingress = traffic coming *in* (a customer); egress = traffic
  going *out* (a pod calling an external API, pulling an image).
- **The problem:** private nodes have **no public IP** (for security), so they can't
  initiate outbound internet connections on their own.
- **Cloud NAT (Network Address Translation):** a Google-managed service giving private
  nodes **outbound-only** internet access. It rewrites the node's private source IP to a
  shared public NAT IP, remembers the mapping, and routes the reply back. The internet can
  never *initiate* a connection inbound — only reply to outbound ones. Security win.
  - In Terraform: `google_compute_router` + `google_compute_router_nat`
    (`AUTO_ONLY`, `ALL_SUBNETWORKS_ALL_IP_RANGES`), per region.
- **Firewall rules:**
  - `gke-allow-internal` — east-west (service-to-service) traffic within the VPC.
  - `gke-allow-health-checks` — Google's probe ranges `130.211.0.0/22`, `35.191.0.0/16`;
    without these the LB marks every backend unhealthy and drops all traffic.
- **Analogy:** Cloud NAT is a company mailroom — employees (private nodes) have no public
  address; outgoing mail gets the company's return address; replies route back internally;
  outsiders can't mail an employee directly.

**One-liner:** "Nodes are private for security, so Cloud NAT gives them outbound-only egress
by translating their private IPs to a shared public one; firewall rules permit internal
service traffic and Google's health-check probes."

---

## Topic deep-dive B — HPA and HA

### HPA (Horizontal Pod Autoscaler)
- Scales the **number of pod replicas** based on live load (horizontal = more copies;
  vertical = bigger pod).
- Config: webapp-a min 2 / max 10 / 50% CPU; webapp-b min 2 / max 8 / 60% CPU.
- **Algorithm:** every ~15s, `desired = ceil(current * currentUtil / targetUtil)`,
  measured against the pod's CPU **request**.
- **Example (webapp-a):** request 100m, target 50% -> target 50m/pod. 4 pods at 90m
  -> ceil(4 * 90/50) = 8 pods. Load drops to 20m -> ceil(8 * 20/50) = 4 pods. Bounded
  by min 2 / max 10.
- **Why the numbers:** min 2 = always redundant; max = cost/blast-radius ceiling;
  50-60% target = headroom to absorb bursts while new pods start.
- **Needs:** resource requests set, metrics server running, stateless pods.
- **Limit:** HPA scales *pods*; if nodes are full, the **Cluster Autoscaler** adds *nodes*.
  They work together.

### HA (High Availability) — four layers
1. **Pod:** 4/3 replicas; Service load-balances across healthy pods; failed pods restart.
2. **Node/zone:** regional cluster, nodes across `us-central1-a`/`-b`; survives a zone loss
   (control plane too).
3. **Region:** optional `gke-secondary` (us-east1) for cross-region DR (active/active or
   active/passive).
4. **Safe operations:** readiness probes (no traffic to not-ready pods -> zero-downtime
   deploys), liveness probes (restart hung pods), PodDisruptionBudget `minAvailable: 1`
   (safe node drains), preStop + `terminationGracePeriodSeconds: 30` (graceful draining).

### How they reinforce each other
- HPA's `minReplicas: 2` is itself an HA control (redundancy even at zero load).
- Multiple replicas let the Service keep serving during scaling or restarts.
- PDB ensures the Cluster Autoscaler respects the availability floor when draining nodes.

**One-liners:**
- HPA: "Scales replicas on CPU-vs-request; webapp-a targets 50% between 2 and 10 pods."
- HA: "Layered — replicas survive pod failures, a regional cluster survives zone failures,
  a secondary cluster survives region failures, and probes + PDBs keep it up during deploys."
- Together: "HPA handles *load*; HA handles *failure*. `minReplicas: 2` is where they meet."

---

## Topic deep-dive C — Why p95/p99 (not averages) and how they're calculated

### Why percentiles beat averages
An average hides the distribution — a few extreme values distort it. What matters for
latency is how bad the slow requests are, because those are the unhappy users.

**Example — same average, different reality.** 10 requests (ms):
`20, 22, 25, 21, 23, 20, 24, 22, 21, 900`
- Average = 109.8 ms — but no request was actually near 110 ms (fiction).
- p50 (median) ≈ 22 ms — the typical user is fast.
- p95 — captures the 900 ms outlier — 1 in 20 users waited that long.

The average both overstates the typical experience and understates the pain. Percentiles
expose both.

**What each means:**
- p50 (median): half of requests are faster. "Typical user."
- p95: 95% faster; worst 5%. "Almost everyone."
- p99: 99% faster; worst 1%. "Tail latency" — GC pauses, cold starts, lock contention.

**Why SLOs use them:** SLOs read like "95% of requests < 200 ms" — a percentile promise
an average can't express. Averages can stay green while p99 is on fire.

### How they're calculated
1. Sort all values ascending.
2. rank = ceil((p/100) * N), where N = number of samples.
3. Read the value at that rank (interpolate if between two).

Example: 20 sorted values, p95 = value at position 0.95 * 20 = 19 (the 19th value).

### How BigQuery does it (your query)
Exact percentiles need a full sort — expensive on billions of rows. BigQuery uses
`APPROX_QUANTILES`, an approximate streaming estimator — near-exact without a global sort.

```sql
APPROX_QUANTILES(latency_ms, 100) AS p   -- 101 boundary values (0%..100%)
...
p[OFFSET(50)] AS p50   -- 0-indexed array: offset 50 = 50th percentile
p[OFFSET(95)] AS p95
p[OFFSET(99)] AS p99
```
- `100` = number of buckets → 1%-granularity percentiles (use 1000 for p99.9 at OFFSET(999)).
- Computed per minute (`TIMESTAMP_TRUNC(timestamp, MINUTE)`), then unioned into 3 series.

### Senior signals
- **You can't average percentiles** — p95 of two servers is not the mean of their p95s.
  Compute from raw values (as the query does), never by averaging pre-aggregated percentiles.
- At high traffic, watch p99.9 too — the "worst 1%" of 1M requests is still 10,000 users.

**One-liner:** "`APPROX_QUANTILES(latency_ms, 100)` returns 101 percentile cut-points; I index
`OFFSET(50/95/99)` per minute. Approximate so it scales without a full sort, and computed from
raw values because percentiles can't be averaged."

---

## Topic deep-dive D — Load Balancing, WAF, and Health Checks

### Container-Native Load Balancing (NEGs) vs kube-proxy
- **Old way (NodePort):** The LB sends traffic to *any* VM Node in the cluster. `kube-proxy` (iptables) on that node intercepts it, does a second round of load balancing, and forwards it to the Pod (which might be on a completely different node). **Downsides:** extra hop, uneven traffic, LB health checks the node (not the pod).
- **New way (NEGs):** Our setup uses **Container-Native Load Balancing**. The GKE Ingress controller programs a **Network Endpoint Group (NEG)**. The Global HTTPS Load Balancer routes traffic *directly* to the Pod IPs, bypassing `kube-proxy`. **Upsides:** lower latency, avoids an extra network hop, and the Google Load Balancer health checks the Pod directly.

### Security layer (Cloud Armor WAF)
- I placed a **Global External HTTPS Load Balancer** in front of the cluster.
- The Load Balancer terminates TLS using a Google-managed certificate and enforces HTTP->HTTPS redirection at the edge.
- Crucially, it's bound to a **Cloud Armor** security policy via a K8s `BackendConfig` custom resource.
- **The WAF Policy (`webapps-waf`):**
  1.  Blocks SQL injection (OWASP CRS ruleset).
  2.  Blocks Cross-Site Scripting (XSS).
  3.  Implements Rate Limiting (100 req/min per IP) to mitigate brute-force and volumetric DDoS.
  4.  Enables Adaptive L7 DDoS protection.

### Health Checking
We check health at two distinct layers:
1.  **Kubernetes layer:** The localized `kubelet` performs readiness probes (can it take traffic?) and liveness probes (is it dead/hung?) configured in the deployment manifests.
2.  **Load Balancer layer:** The global Google External Load Balancer probes the pods directly on `/` port 8080 (configured via `BackendConfig`). If a pod fails *this* check, it is pulled from the external routing pool globally.

**One-liner:** "We use Container-Native Load Balancing (NEGs) so the Global HTTPS Load Balancer routes directly to Pod IPs, bypassing `kube-proxy`. This is secured at the edge by a Cloud Armor WAF policy (SQLi, XSS, rate-limiting) attached via a `BackendConfig`."

## Remaining questions to prepare (queue)
- Q3: Troubleshooting scenario — the `table_invalid_schema` sink incident (required deliverable)
- Q4: Terraform / IaC — `iam_member` vs `iam_binding`, `lifecycle ignore_changes`, remote state
- Q5: Security — Workload Identity, Secret Manager, private clusters, least-privilege IAM
- Q6: Traffic flow — DNS -> Global LB -> NEG/Ingress -> Service -> Pod; LoadBalancer vs Ingress
- Q7: Cost & operations — what drives cost, BigQuery cost control, cleanup

(See also `docs/schwab-alignment.md` for enterprise-standard comparison questions.)
