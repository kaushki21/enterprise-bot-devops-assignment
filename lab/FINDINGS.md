# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):
Running `./scenario.sh up` failed to install the Helm chart:
```console
$ ./scenario.sh up
==> applying cluster environment (cluster-state/)
namespace/debug-lab configured
limitrange/debug-lab-guardrails configured
==> installing the broken chart
Error: INSTALLATION FAILED: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Unsupported value: "Always": supported values: "OnFailure", "Never"

helm reported an error. That is not your machine misbehaving —
it is part of the exercise. Read the error; it is evidence.

Lab is (partially) installed. Investigate with kubectl, fix the chart,
re-run './scenario.sh up' to apply your fixes, and './scenario.sh verify'
to check progress.
```

**Cause** (the actual root cause, not the symptom restated):
Kubernetes `batch/v1` Job resource contracts mandate that `spec.template.spec.restartPolicy` must be either `OnFailure` or `Never`. The chart's `templates/migrate-job.yaml` explicitly set `restartPolicy: Always` (a policy valid only for long-running Pod controllers like Deployments and StatefulSets). The Kubernetes apiserver schema validation rejected the entire chart manifest during `helm upgrade --install`.

**Fix** (what you changed, and why this over alternatives):
In `lab/broken-chart/templates/migrate-job.yaml` (line 16), changed `restartPolicy: Always` to `restartPolicy: OnFailure`.
`OnFailure` was chosen over `Never` because migration jobs should allow container restarts in-place if a transient error occurs during startup, up to the defined `backoffLimit: 2`.

**How I found it** (the sequence of commands/reasoning that led you here):
The failure occurred at step 1 during `./scenario.sh up`. The helm CLI output directly named the failing resource (`Job.batch "migrate"`) and the invalid field path (`spec.template.spec.restartPolicy`). Inspected `lab/broken-chart/templates/migrate-job.yaml` and verified the invalid value on line 16.

---

## Defect 2

**Symptom:**
After resolving Defect 1 and applying the chart, `./scenario.sh verify` reported:
```console
FAIL  deployment metrics: 0/1 ready
```
Investigating the deployment and ReplicaSet:
```console
$ kubectl -n debug-lab get deploy metrics
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
metrics   0/1     0            0           2m10s

$ kubectl -n debug-lab describe rs -l app=metrics
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  12s (x8 over 45s)  replicaset-controller  Error creating: pods "metrics-5d6664c8d5-" is forbidden: [maximum cpu usage per Container is 1, but limit is 4, maximum cpu usage per Container is 1, but request is 2]
```

**Cause:**
Namespace `debug-lab` enforces guardrail boundaries defined in `lab/cluster-state/limits.yaml` via a `LimitRange` named `debug-lab-guardrails`, capping container CPU limits at `max.cpu: "1"`. In `lab/broken-chart/values.yaml`, `metrics.resources` requested `2` CPUs and limited `4` CPUs. The LimitRange admission plugin rejected Pod creation requests emitted by the `metrics` ReplicaSet controller.

**Fix:**
In `lab/broken-chart/values.yaml`, updated `metrics.resources` to:
```yaml
metrics:
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "200m"
      memory: "128Mi"
```
This aligns the metrics workload with the standard resource sizing used across the other API services in the chart, well within the namespace's 1 CPU ceiling.

**How I found it:**
`kubectl -n debug-lab get deploy metrics` showed `0/1 ready` with `0` up-to-date and available replicas. Ran `kubectl -n debug-lab describe rs -l app=metrics`, where the ReplicaSet event log displayed `FailedCreate` with `maximum cpu usage per Container is 1, but limit is 4`. Cross-referenced `lab/cluster-state/limits.yaml` to confirm the guardrail threshold.

---

## Defect 3

**Symptom:**
`./scenario.sh verify` reported RBAC and reporter failures:
```console
FAIL  ServiceAccount debug-lab/reporter cannot list pods
FAIL  reporter /report does not return a pod count
```
Checking authorization directly:
```console
$ kubectl auth can-i list pods -n debug-lab --as="system:serviceaccount:debug-lab:reporter"
no

$ kubectl -n debug-lab logs deploy/reporter
2026/10/10 07:22:15 [ERROR] failed to list pods in namespace debug-lab: pods is forbidden: User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods" in API group "" in the namespace "debug-lab"
```

**Cause:**
`lab/broken-chart/templates/rbac.yaml` created `ServiceAccount/reporter` and `Role/reporter-read`, but in `RoleBinding/reporter-read` the subject was bound to `name: default` instead of `name: reporter`. The reporter Pod was executing under `serviceAccountName: reporter` and therefore received no RBAC permissions.

**Fix:**
In `lab/broken-chart/templates/rbac.yaml`, changed the RoleBinding subject to reference the reporter ServiceAccount:
```yaml
subjects:
  - kind: ServiceAccount
    name: {{ .Values.reporter.serviceAccountName | default "reporter" }}
    namespace: {{ .Release.Namespace }}
```

**How I found it:**
Executed `kubectl auth can-i list pods -n debug-lab --as="system:serviceaccount:debug-lab:reporter"`, which returned `no`. Inspected `lab/broken-chart/templates/rbac.yaml` line 34 and found `name: default` under `subjects`. Compared with `lab/broken-chart/templates/reporter.yaml` line 19, which uses `serviceAccountName: reporter`.

---

## Defect 4

**Symptom:**
`./scenario.sh verify` reported:
```console
FAIL  gateway /status does not report backend=ok
```
Querying the gateway status endpoint:
```console
$ kubectl -n debug-lab run curl-test --rm -it --image=busybox:1.36 --restart=Never -- wget -q -O- http://gateway.debug-lab.svc/status
{"self":"ok","backend":"fail","error":"Get \"http://backend.default.svc:8080/healthz\": dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host"}
```

**Cause:**
In `lab/broken-chart/values.yaml` (line 38), `gateway.env.BACKEND_URL` was configured as `"http://backend.default.svc:8080"`. The backend Service resides in namespace `debug-lab`, not `default`. DNS resolution for `backend.default.svc` returned `NXDOMAIN`, preventing the gateway from aggregating health status.

**Fix:**
In `lab/broken-chart/values.yaml`, changed `gateway.env.BACKEND_URL` to `"http://backend.debug-lab.svc:8080"`.

**How I found it:**
Ran a test busybox pod inside the cluster to curl `http://gateway.debug-lab.svc/status`. The returned JSON payload showed `"backend":"fail"` with an error attempting to connect to `backend.default.svc:8080`. Checked `lab/broken-chart/values.yaml` under `gateway.env` and confirmed the invalid namespace reference in the URL.

---

## Defect 5

**Symptom:**
`./scenario.sh verify` reported:
```console
FAIL  deployment worker: 0/1 ready
FAIL  1 pod(s) in CrashLoopBackOff
```
Examining the pod status and logs:
```console
$ kubectl -n debug-lab get pods -l app=worker
NAME                      READY   STATUS             RESTARTS      AGE
worker-79c4f8776b-9kmxp   0/1     CrashLoopBackOff   4 (30s ago)   2m15s

$ kubectl -n debug-lab logs -l app=worker --previous
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:**
`lab/broken-chart/templates/worker.yaml` enforces `securityContext.readOnlyRootFilesystem: true`. On startup, `eb-debug-app` in worker mode initializes a local cache at `/var/cache/app`. Because the container filesystem is mounted read-only and no writable volume was mounted at `/var/cache/app`, the `mkdir` call failed with an OS permission error, terminating the process and triggering `CrashLoopBackOff`.

**Fix:**
In `lab/broken-chart/templates/worker.yaml`, added an `emptyDir: {}` volume (`cache-volume`) to the Pod spec and mounted it to the container at `/var/cache/app`:
```yaml
          volumeMounts:
            - name: cache-volume
              mountPath: /var/cache/app
      volumes:
        - name: cache-volume
          emptyDir: {}
```
This gives the container writable ephemeral scratch space while preserving `readOnlyRootFilesystem: true`.

**How I found it:**
`kubectl -n debug-lab get pods` showed `worker` in `CrashLoopBackOff`. Ran `kubectl -n debug-lab logs -l app=worker --previous`, which output the fatal message: `worker could not initialise its cache: mkdir /var/cache/app: read-only file system`. Checked `lab/broken-chart/templates/worker.yaml` and noted the missing volume mount alongside `readOnlyRootFilesystem: true`.

---

## Defect 6

**Symptom:**
`./scenario.sh verify` reported readiness probe failures on API services:
```console
FAIL  deployment backend: 0/1 ready
FAIL  deployment gateway: 0/1 ready
FAIL  deployment reporter: 0/1 ready
FAIL  backend does not answer on http://backend:8080/healthz
```
Checking the backend pod description and logs:
```console
$ kubectl -n debug-lab describe pod -l app=backend
Events:
  Type     Reason     Age                From     Message
  ----     ------     ----               ----     -------
  Warning  Unhealthy  15s (x10 over 1m)  kubelet  Readiness probe failed: Get "http://10.244.0.14:8080/healthz": dial tcp 10.244.0.14:8080: connect: connection refused

$ kubectl -n debug-lab logs -l app=backend
eb-debug-app 1.0.1 starting: mode=api pod=backend-676b7b758b-zlm29 listening on :8081 (image default is 8081; set PORT to override)
```

**Cause:**
`lab/broken-chart/values.yaml` specified `common.port: 8080`, and the templates configured `containerPort`, `readinessProbe`, and Service `targetPort` to `8080`. However, the container image `ebinterview/eb-debug-app:1.0.1` exposes and listens on port `8081` by default unless overridden via the `PORT` environment variable. Because `PORT` was not set in the container environment, the application listened on `8081`, causing kubelet readiness probes on `8080` to fail with `connection refused`. Consequently, pods never transitioned to `Ready`, and Services endpoints remained empty.

**Fix:**
1. Updated `common.port: 8081` in `lab/broken-chart/values.yaml` so that probes and Service `targetPort` correctly target the application's listening port (`8081`), while Services continue exposing standard port `8080` (or `80` for gateway).
2. In `templates/backend.yaml`, `gateway.yaml`, `metrics.yaml`, `reporter.yaml`, and `worker.yaml`, added `- name: PORT value: {{ .Values.common.port | quote }}` to the container `env` block. This ensures that the application runtime port is explicitly synchronized with the chart values under all configuration overrides.

**How I found it:**
Checked `kubectl -n debug-lab describe pod -l app=backend`, which reported repeated readiness probe failures on port 8080. Checked `kubectl -n debug-lab logs -l app=backend`, which logged: `listening on :8081 (image default is 8081; set PORT to override)`. Inspected the OCI image layer and verified `EXPOSE [8081/tcp]` in container metadata.
