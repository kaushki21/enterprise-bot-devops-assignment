# Written Question — Part 5

### Q1. Migrating ~40 Ingress Objects from `ingress-nginx` to Kubernetes Gateway API with Zero Downtime

> [!NOTE]
> **AI Usage Disclosure:** Architectural reasoning and risk sequencing were developed by the candidate and refined with AI assistance (Google Antigravity), in full alignment with the assignment's AI policy.

#### Approach & Sequencing

1. **Deploy Gateway API Infrastructure in Parallel:**
   - Install standard Gateway API CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`).
   - Deploy the new Gateway controller (e.g., Envoy Gateway or Cilium) alongside existing `ingress-nginx` with its own dedicated LoadBalancer / external IP.

2. **Audit & Translate Ingress Resources:**
   - Catalog all 40 `Ingress` objects, noting TLS secrets, hostnames, path rules, and custom annotations.
   - Author corresponding `HTTPRoute` resources targeting existing backend Services.
   - Establish a shared `Gateway` listener with multi-domain TLS referencing existing `cert-manager` secrets.

3. **Dual Routing & Traffic Shadowing:**
   - At the upstream DNS / CDN layer (e.g., Cloudflare, Route53), configure weighted DNS routing or route staging/non-critical domains first to validate latency, headers, and routing fidelity.

4. **Incremental Cutover (Canary per Service):**
   - Migrate low-risk services first, followed by stateful/critical APIs.
   - Shift DNS traffic in increments (10% → 50% → 100%) while monitoring 4xx/5xx error rates, latency spikes, and ingress logs.

5. **Decommissioning:**
   - Keep `ingress-nginx` idle for a soak period (24–48 hours) for instant DNS rollback capability before removing controller workloads and `Ingress` manifests.

---

#### What I Expect to Break Along the Way

- **Custom Nginx Annotations:** Ingress-nginx features like `configuration-snippet`, `proxy-body-size`, regex path rewrites (`rewrite-target`), and CORS do not translate 1:1 to core Gateway API specs and require vendor-specific filters (e.g., `ExtensionRef` or Envoy filters).
- **External Authentication & OAuth:** Workloads relying on `nginx.ingress.kubernetes.io/auth-url` for external authentication require migration to Gateway API external authorization (`EnvoyExtensionPolicy` or similar).
- **cert-manager Integration:** The legacy `kubernetes.io/tls-acme: "true"` annotation does not apply to `HTTPRoute`. Certificate management must transition to Gateway-level TLS listeners.
- **Path Matching Differences:** Nginx regex path priority behaves differently than Gateway API `PathPrefix` / `Exact` precedence rules, which can misroute overlapping API subpaths.
- **Client IP Preservation:** Proxy protocol and `X-Forwarded-For` handling differences between Nginx and Envoy can break upstream IP whitelisting or geolocation logic.
