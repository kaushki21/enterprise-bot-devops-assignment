# Enterprise Bot — DevOps / Platform Engineer Take-Home Submission

This repository contains the end-to-end implementation for the Enterprise Bot GmbH DevOps / Platform Engineer assignment.

> [!NOTE]
> **AI Usage Disclosure (per Enterprise Bot AI Policy):**
> AI assistance (Google Antigravity agentic assistant) was used to accelerate boilerplate scaffolding, OCI layer inspection, and hypothesis validation. See the full disclosure in the [How I Used AI](#how-i-used-ai) section below detailing tools used, workflows, and candidate corrections. All work is fully defended live.

---

## Table of Contents
- [Repository Structure](#repository-structure)
- [How I Used AI (Mandatory Disclosure)](#how-i-used-ai)
- [How to Run and Verify Your Work](#how-to-run-and-verify-your-work)
  - [Part 3: One-Command Setup (`setup.sh`)](#part-3-one-command-setup)
  - [Part 4: Debug the Lab (`lab/`)](#part-4-debug-the-lab)
- [Resource Requests and Limits — Rationale](#resource-requests-and-limits--rationale)
- [What Was Deliberately Skipped & Associated Risks](#what-was-deliberately-skipped--associated-risks)
- [What Would Make This Production-Ready](#what-would-make-this-production-ready)

## Repository Structure

As required by the automated grading harness:

```text
.
├── setup.sh                 # Part 3: Idempotent end-to-end setup script
├── README.md                # Part 6: Documentation and reasoning
├── ANSWERS.md               # Part 5: Written answer on Gateway API migration
├── service/                 # Part 1: Containerized Node.js service
│   ├── server.js            #   Application source with dynamic config resolution
│   ├── package.json         #   Node.js manifest
│   ├── Dockerfile           #   Multi-stage build, non-root user (UID 10001)
│   └── .dockerignore        #   Build ignore list
├── chart/                   # Part 2: Helm chart for demo-service
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap.yaml   #   ConfigMap driving appName & version
│       ├── deployment.yaml  #   2 replicas, probes, resources, config volume
│       ├── service.yaml     #   ClusterIP service
│       └── ingress.yaml     #   Ingress for demo.local
├── lab/                     # Part 4: Handout lab and fixes
│   ├── scenario.sh          #   Test harness driver (unmodified)
│   ├── cluster-state/       #   Cluster guardrails and namespace (unmodified)
│   ├── broken-chart/        #   Fixed Helm chart for debug-lab
│   ├── FINDINGS.md          #   Complete breakdown of all 6 defects
│   └── part4-session.log    #   Recorded terminal debugging transcript
└── .github/workflows/       # Bonus: CI workflow
    └── ci.yml               #   Helm linting, buildx, and Trivy scan
```

---

## How to Run and Verify Your Work

### Prerequisites
- Docker Engine / Docker Desktop
- `kind` (v0.20+)
- `kubectl` (v1.28+)
- `helm` (v3.12+)

---

### Part 3: One-Command Setup

Run the idempotent setup script from the repository root:

```bash
chmod +x setup.sh
./setup.sh
```

The script will:
1. Create a `kind` cluster named `demo` configured with host port mappings (`80`, `443`) and `ingress-ready=true` labels (or reuse it if it exists).
2. Install the `ingress-nginx` controller and await controller readiness.
3. Build `demo-service:1.0.0` from `service/` and load the image into the kind cluster.
4. Deploy the Helm chart to namespace `demo` under release `demo`.

To verify idempotency, execute `./setup.sh` a second time; it exits 0 without recreation conflicts.

#### Verification Commands:

```bash
# 1. Verify pods are running and ready (2 replicas)
kubectl get pods -n demo

# 2. Test root endpoint through ingress (resolving demo.local to localhost)
curl -s -H "Host: demo.local" http://localhost/
# Expected JSON output:
# {"app":"demo-service","version":"1.0.0","pod":"demo-56fb747864-8qm29"}

# 3. Test health check endpoint
curl -s -H "Host: demo.local" http://localhost/healthz
# Expected JSON output:
# {"status":"ok"}

# 4. Verify live ConfigMap dynamic update
kubectl -n demo patch configmap demo-config --type merge -p '{"data":{"APP_NAME":"updated-app"}}'
sleep 2
curl -s -H "Host: demo.local" http://localhost/
# Expected output shows updated app name without pod restart:
# {"app":"updated-app","version":"1.0.0","pod":"..."}
```

---

### Part 4: Debug the Lab

To run and verify the fixed debug lab:

```bash
cd lab

# Install the fixed lab chart and pristine cluster environment
./scenario.sh up

# Run the automated verification harness
./scenario.sh verify
```

Expected result:
```text
==> verifying goal state in namespace debug-lab
  PASS  migrate Job completed
  PASS  deployment backend: 1/1 ready
  PASS  deployment gateway: 1/1 ready
  PASS  deployment worker: 1/1 ready
  PASS  deployment reporter: 1/1 ready
  PASS  deployment metrics: 1/1 ready
  PASS  no pods in CrashLoopBackOff
  PASS  ServiceAccount debug-lab/reporter can list pods
  PASS  backend answers on http://backend:8080/healthz
  PASS  gateway /status reports backend=ok
  PASS  reporter /report sees pods in the namespace

ALL GREEN — 11/11 checks passed. This part is done.
```

See [lab/FINDINGS.md](lab/FINDINGS.md) for full incident details and [lab/part4-session.log](lab/part4-session.log) for the complete terminal investigation session.

---

## Resource Requests and Limits — Rationale

In `chart/values.yaml`, resources are set to:
```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

### Why these numbers?
1. **Node.js Baseline Footprint:**
   A minimal Node.js HTTP runtime utilizing native standard libraries (`http`, `fs`, `os`) has an idle memory footprint of ~25–35 MiB RSS. Setting `requests.memory: 64Mi` provides enough headroom for V8 garbage collection and runtime buffers without triggering early OOM.
2. **CPU Sizing & Throttling Mitigation:**
   `requests.cpu: 50m` (0.05 core) guarantees that Kubernetes scheduling can place replicas densely across local kind or development cluster nodes. `limits.cpu: 200m` accommodates short JSON serialization bursts without triggering aggressive CFS quota throttling.
3. **Cluster Guardrail Compatibility:**
   In shared Kubernetes environments (such as the `LimitRange` guardrails seen in Part 4), setting excessive resource requests blocks pod scheduling. These numbers fit within restrictive container ceilings while ensuring guaranteed Quality of Service (QoS: *Burstable*).

---

## What Was Deliberately Skipped & Associated Risks

| Component Skipped | Rationale for Skipping | Operational / Production Risk |
|---|---|---|
| **HorizontalPodAutoscaler (HPA)** | Kept deployment minimal for local kind cluster grading; focus on basic replica control. | Pods cannot autoscale under sustained HTTP traffic surges, leading to degraded latency or dropped connections. |
| **PodDisruptionBudget (PDB)** | Lab and grading run in single-node kind cluster where node drains do not occur. | In a multi-node cluster, rolling upgrades or node drains could evict all replicas simultaneously, causing service downtime. |
| **NetworkPolicies (CNI firewall)** | Default kind bridge does not enforce Calico/Cilium egress/ingress isolation out of the box. | Any pod in the cluster can communicate directly with the demo pods; unrestricted lateral movement in case of pod compromise. |
| **TLS / HTTPS Termination** | Kept Ingress simple for local curl verification on port 80. | In production, traffic is transmitted in cleartext; vulnerable to eavesdropping and MITM attacks without cert-manager TLS. |
| **External Secret Manager** | Values passed via plain ConfigMaps. | Configuration values are unencrypted at rest; risk of leaking sensitive configuration if secrets are introduced. |

---

## What Would Make This Production-Ready

1. **High Availability & Scheduling Topology:**
   - Add `topologySpreadConstraints` and `podAntiAffinity` across availability zones (`topology.kubernetes.io/zone`) to prevent single-rack or single-zone outages from taking down both replicas.
   - Configure a `PodDisruptionBudget` (`minAvailable: 1`).
2. **Security Hardening:**
   - Migrate container image to a `distroless` or scratch runtime to eliminate package managers and shells entirely.
   - Enforce Kubernetes `securityContext`: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `drop: ["ALL"]`.
   - Implement restrictive `NetworkPolicy` rules allowing only ingress controller traffic into the service namespace.
3. **Observability & Reliability:**
   - Integrate Prometheus metrics export (e.g. `prom-client`) and deploy a `ServiceMonitor` for automated scraping.
   - Implement OpenTelemetry tracing and structured JSON logging with correlation IDs.
   - Add HTTP readiness probe startup grace period (`startupProbe`) for predictable cold-start handling.
4. **GitOps & Delivery:**
   - Deploy via ArgoCD or Flux with automated semantic versioning and image tag pinning.
   - Use automated vulnerability gates (Trivy / Snyk) in CI to block deployments containing CVEs (implemented in `.github/workflows/ci.yml`).

---

## How I Used AI

In compliance with Enterprise Bot's disclosure policy:

1. **Tools Used:**
   - AI assistant (Claude / Antigravity agent) was used across the assignment.
2. **Where AI was used:**
   - **Binary Inspection & Reverse-Engineering:** Used AI to script OCI layer extraction and string analysis against `ebinterview/eb-debug-app:1.0.1` directly from Docker Hub registry blobs, discovering the undocumented default port `8081` and the hardcoded `/var/cache/app` path.
   - **Boilerplate Scaffolding:** Accelerated authoring of the Helm templates (`chart/`), Docker multi-stage configuration, and GitHub Actions CI workflow.
   - **Hypothesis Testing:** Cross-checked Kubernetes LimitRange admission controller error codes and batch Job schema validation rules against the lab chart defects.
3. **What I Corrected:**
   - The initial AI draft suggested passing only `PORT: 8080` in the environment to fix the port defect. However, checking `scenario.sh` verified that Services hardcode port `8080` while routing to `targetPort: {{ .Values.common.port }}`. Updating `common.port: 8081` in `values.yaml` alongside passing `PORT` was the mathematically sound fix that keeps the chart fully compliant with both the prebuilt image and the test harness.
   - Fixed ConfigMap live update behavior: added dual resolution (checking live mounted `/etc/config` files dynamically on every request before falling back to `process.env`) so that live `kubectl patch configmap` calls reflect immediately on `GET /` without requiring a pod restart.
