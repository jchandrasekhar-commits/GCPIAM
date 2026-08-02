# Schwab Enterprise Alignment — GKE Assignment vs ArchLib Standards

This document relates the GCPIAM assignment (a GCP project with GKE, two web apps,
and full observability) to Charles Schwab's enterprise architecture standards as
published in the **Schwab Architecture Library (ArchLib)** Confluence space.

> Source references (Schwab internal Confluence, space `ARCHLIB`):
> - ArchLib Artifacts (index) — page `125076952`
> - Network Strategy — page `869040857`
> - Central Landing Zone SAD — page `3211794214`
> - Standard Network Fabric SAD — page `2627273250`

---

## 1. What ArchLib is

`ArchLib Artifacts` is the index of Schwab's Architecture Library — a governance
catalog of the artifact **types** used to document architecture across the firm.
Artifact categories include:

- Technology Strategy / Area Strategy
- Architecture Blueprint / Architecture Model / Architecture Overview
- Architecture Patterns / Architecture Principles
- Context Diagrams / Macro Architectures / Reference Architectures
- Handbooks / Solution Selectors

Each artifact carries metadata (author, version, publish date, **attestation date**)
so the enterprise can keep designs current and reviewed.

### How this repo maps to ArchLib artifact types

| This repo | ArchLib artifact type |
|---|---|
| `docs/architecture.md` Mermaid diagram | Context Diagram |
| End-to-end write-up + traffic flow | Architecture Overview / Blueprint |
| Terraform (`terraform/`) | Architecture Model (implemented, machine-readable) |
| Design decisions & free-tier rationale | Area Strategy / Technology Strategy |
| `docs/Steps.txt` runbook | Handbook |

---

## 2. How Schwab documents solutions: the SAD template

Cloud/GCP solutions at Schwab (e.g., the Central Landing Zone) are written using
the **Solution Architecture Document (SAD) v3.0** template. Its required sections
map almost one-to-one onto what this assignment already produced:

| SAD v3.0 section | This assignment's equivalent |
|---|---|
| Conceptual View | `docs/architecture.md` Mermaid diagram |
| Architecture Patterns | Two-cluster HA, multi-pod, log-export patterns |
| Logical View | VPC -> cluster -> services -> pods flow |
| Security & IAM View | `terraform/roles.tf`, Workload Identity, Secret Manager |
| Deployment View | Terraform IaC + `docs/Steps.txt` |
| Data View | BigQuery `logs_dataset_us` |
| Visibility & Monitoring View | Grafana + Cloud Monitoring dashboards |
| Cost Drivers / Analysis | Free-tier trade-off notes |

**Takeaway:** the repo already contains the substance of a Schwab SAD; productionizing
it would mean transcribing the content into the SAD template.

---

## 3. GCP is a first-class Schwab cloud

ArchLib contains multiple GCP-hosted solution documents, confirming Google Cloud is
a sanctioned platform:

- Central Landing Zone SAD (GCP-hosted data platform, uses Pub/Sub)
- Digital Forensics & Incident Response (DFIR) in Cloud — GCP SAD
- Salesforce Marketing Cloud (SFMC) <-> GCP connectivity SADs
- Cloud Go-Live Application SAD

The GCP/GKE skills demonstrated here map directly onto Schwab's real stack (the CLZ
even uses Pub/Sub, one of the "App B could use" services in the assignment brief).

---

## 4. Schwab Network Strategy — the standard

**Core principles:** Availability, Secure, Scalability.

**Guiding principles:**
- **Software Defined** — source-controlled, automated, SDLC; controller-based not CLI
- **Mass Standardization** — highly standardized, templated configs
- **Simplify** — as simple as possible for MVP; continuously reduce complexity
- **Supportability** — real-time monitoring; monitoring defined *before* deploy
- **Continuous Optimization** — lower cost per unit through automation

**Security / segmentation model:**
- **Macro-segmentation** — 6 firewalled zones (End-User/Corp, Non-Production,
  Production, Management, Shared CIS), physical isolation at the firewall layer
- **Micro-segmentation** — fine-grained, per-workload isolation. Strategy note:
  *"Within the cloud, micro-segmentation is already baked in — each node enforces
  its own policies and inherits from the zone/VPC it lives in."*
- **Zero Trust**, **DNSSEC**, **network security automation**

---

## 5. My design vs Schwab standard

| Schwab principle / control | Schwab standard | This design | Verdict |
|---|---|---|---|
| Software Defined | Source-controlled, automated network config | All network in Terraform, in Git, reproducible | Aligned |
| Mass Standardization | Highly standardized, templated | Symmetric primary/secondary via one parameterized module; `tfvars.example` | Aligned |
| Simplify | As simple as possible for MVP | Isolated subnets + NAT + targeted firewall rules | Aligned |
| Availability | Inter/intra-region resiliency | Regional control plane, nodes across zones, multi-region secondary cluster | Aligned |
| Micro-segmentation | Per-workload isolation; node enforces + inherits from VPC | VPC-native, private nodes, dedicated subnets (GKE, Envoy LB, Ops); **no Kubernetes NetworkPolicies** | Partial |
| Macro-segmentation (zones) | 6 firewalled zones | Single flat VPC, one environment | Gap (demo scope) |
| Zero Trust | Default-deny, least-privilege | Cloud Armor WAF + Rate Limiting, Private nodes + Workload Identity + least-priv IAM; broad `allow_internal` firewall | Partial |
| Secure / data protection | Confidentiality/integrity/availability | Binary Authorization, Secret Manager, Workload Identity, private endpoints | Aligned |
| Supportability (monitoring) | Real-time, pre-defined before deploy | Logging -> BigQuery -> Grafana + Cloud Monitoring, Uptime alerts | Aligned |
| Continuous Optimization | Lower cost, automation | Autoscaling 0-N, small nodes, free-tier toggles, `terraform destroy` | Aligned |
| Landing-zone consumption | Workloads land into Central Landing Zone Shared VPC | Builds its own custom-mode VPC | Expected difference |

### Gaps vs the standard (named proactively)
1. **No Kubernetes NetworkPolicies** — pod-to-pod traffic is unrestricted; Schwab
   expects micro-segmentation. *Quick win: default-deny + explicit allows.*
2. **Broad `allow_internal` firewall** — Zero Trust wants least-privilege; tighten
   to specific ports.
3. **No macro-zone separation** — demo runs one flat environment vs firewalled
   Prod/Non-Prod/Mgmt zones (scope difference, not a flaw).
4. **Self-built VPC vs CLZ** — at Schwab, inherit the Central Landing Zone Shared
   VPC rather than creating a custom-mode `gke-vpc` (see Section 6).

---

## 6. Self-built VPC vs Central Landing Zone (Shared VPC)

### What this demo does
`main.tf` creates the whole network stack itself:
`google_compute_network "gke-vpc"`, subnets, `google_compute_router_nat`,
`google_compute_firewall`. Full control, self-contained — ideal for demonstrating
the primitives.

### What Schwab does: Shared VPC (host vs service projects)
A **landing zone** is a pre-built, pre-secured, pre-approved cloud foundation the
platform team builds once so app teams deploy **into** it.

```
HOST PROJECT (Landing Zone / Network team)
  Shared VPC = the one enterprise network
    - subnets (CIDRs from central IPAM)
    - Cloud NAT (central egress)
    - firewall rules (segmentation policy)
    - Interconnect/VPN to on-prem, DNSSEC
        ^                    ^
        | attached           | attached
  SERVICE PROJECT       SERVICE PROJECT      <- app teams
   your GKE + apps       another workload
```

- **Host project** — owned by the network team; holds the Shared VPC. App teams
  cannot modify it.
- **Service project** — your app project attaches to the host project; your GKE
  nodes/pods use subnets from the host's Shared VPC while compute/billing stay in
  your project.
- **IPAM** — CIDRs are centrally allocated (non-overlapping, routable firm-wide).

### How the Terraform would change
```hcl
# No longer created:
#   google_compute_network "vpc"
#   google_compute_subnetwork "primary_subnet"
#   google_compute_subnetwork "lb_proxy_subnet"
#   google_compute_router_nat / google_compute_firewall
#   google_compute_global_address "psa_range"

# Instead, reference the landing zone's shared network:
resource "google_container_cluster" "primary" {
  name       = "gke-primary"
  network    = "projects/${var.host_project}/global/networks/${var.shared_vpc}"
  subnetwork = "projects/${var.host_project}/regions/${var.region}/subnetworks/${var.assigned_subnet}"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name      # pre-allocated
    services_secondary_range_name = var.services_range_name
  }
  # NAT, firewall, DNS, PSA, connectivity all inherited from the host project
}
```

**Stays your responsibility:** cluster, node pools, workloads, app-scoped IAM,
observability, Cloud Armor WAF on the Ingress, Uptime checks.
**Becomes the platform team's responsibility:** VPC, CIDRs, NAT, firewall, DNS,
PSA (Private Service Access), on-prem connectivity.

### Why enterprises do it this way
1. Consistency & compliance — every workload inherits segmentation / Zero Trust / DNSSEC.
2. Separation of duties — network team owns routing/firewall; app teams own apps.
3. IP governance — central IPAM prevents overlapping CIDRs and keeps routing sane.
4. Blast-radius control — an app project can't damage the shared network.
5. Speed — teams "land" in minutes instead of building networks.

### Why the demo choice was still correct
Self-built proves understanding of the primitives (VPC/NAT/firewall). Knowing the
same primitives would be **inherited from the CLZ Shared VPC** at Schwab is the
enterprise-maturity nuance.

---

## 7. Interview one-liners

- **Architecture:** "Nodes are private for security, so Cloud NAT gives them
  outbound-only egress; firewall rules permit internal service traffic and Google
  health-check probes."
- **Schwab alignment:** "My design already embodies Schwab's Network Strategy —
  software-defined, standardized, simplified, highly available, monitored-by-default.
  The delta is enterprise scope: macro-zone segmentation, micro-segmentation via
  NetworkPolicies, and landing into the Central Landing Zone Shared VPC instead of
  building my own."
- **Productionizing:** "I'd add Kubernetes NetworkPolicies, tighten the firewall to
  least-privilege, and reference the CLZ Shared VPC rather than creating `gke-vpc`."
