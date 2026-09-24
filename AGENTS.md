# gijsentius-terraform

Terraform project that provisions a homelab Kubernetes cluster on Proxmox using Talos Linux.

## What this manages

- **Proxmox VMs** running Talos Linux (immutable, API-driven Kubernetes OS)
- **Talos machine configs**, generated and applied directly via the `siderolabs/talos`
  provider: cluster secrets, per-node config, applying to nodes, bootstrapping etcd,
  kubeconfig/talosconfig retrieval

The cluster will run **Crossplane**, **Backstage**, and **ArgoCD** to manage all homelab resources.

Terraform also bootstraps **ArgoCD** itself: it generates a read-only GitHub deploy key,
uploads it to your mono repo, clones the repo fresh into `.homelab-apps-checkout/` (via
`GITHUB_TOKEN`, on every apply), and installs ArgoCD plus an AppProject/ApplicationSet
that discovers apps in that repo, using the chart at `apps/` in the clone. This step is
optional and only runs when `argocd_github_repo` is set.

Terraform also creates the `operator-oauth` Secret that `tailscale-operator` (one of the
apps ArgoCD discovers) needs — the mono repo can't hold real OAuth credentials, so
Terraform writes the Secret directly instead of it living in a Helm chart's values.
Optional, only created when `tailscale_oauth_client_id` is set.

## Providers

| Provider | Purpose |
|---|---|
| `bpg/proxmox` | Create/manage Proxmox VMs, download ISO images |
| `siderolabs/talos` | Generate cluster secrets/machine configs, apply them to nodes, bootstrap etcd, retrieve kubeconfig/talosconfig |
| `hashicorp/local` | Write the retrieved kubeconfig/talosconfig to disk |
| `hashicorp/tls` | Generate the ArgoCD SSH deploy key pair |
| `integrations/github` | Upload the deploy key to your mono repo |
| `hashicorp/helm` | Install ArgoCD + bootstrap chart into the new cluster |
| `hashicorp/kubernetes` | Create the tailscale-operator OAuth credentials Secret |

## File structure

```
versions.tf                      # Provider version constraints
providers.tf                     # Provider config (credentials via variables)
variables.tf                     # All input variables with descriptions
main.tf                          # Resources: ISO, VMs, Talos machine configs, bootstrap
outputs.tf                       # VM MAC addresses, paths to kubeconfig/talosconfig
terraform.tfvars.example         # Template — copy to terraform.tfvars and fill in
modules/
  proxmox_vm/                    # Reusable module: creates one Proxmox VM

.homelab-apps-checkout/          # Gitignored — mono repo cloned fresh here on every apply
                                  # by terraform_data.homelab_apps_checkout; not a sibling dir
                                  # you maintain yourself, don't rely on its contents persisting
```

## Talos config workflow

The `siderolabs/talos` provider replaces talhelper — Terraform talks to the Talos API
directly instead of shelling out to `talhelper`/`age`/`sops`. The chain, in `main.tf`:

1. `talos_machine_secrets` generates cluster CA/bootstrap secrets once (stored only in
   Terraform state — see [State and secrets](#state-and-secrets))
2. `data.talos_machine_configuration` renders one machine config per machine type
   (controlplane/worker) from your variables, with config patches built as
   `yamlencode(...)` locals instead of a talhelper template
3. `talos_machine_configuration_apply` (one per node, `for_each`) applies each node's
   config — the provider handles both a freshly-booted node (insecure maintenance-mode
   API) and an already-installed one (secure API) itself
4. `talos_machine_bootstrap` bootstraps etcd on the first control plane node
5. `talos_cluster_kubeconfig` / `data.talos_client_configuration` retrieve the
   kubeconfig/talosconfig, written to disk via `local_file`
6. If `argocd_github_repo` is set: create a GitHub deploy key and install ArgoCD via Helm

## First-time setup

```bash
# Install tools
brew install talosctl kubectl

# --- Terraform ---
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
tofu init
```

`talosctl` is optional — Terraform talks to the Talos API directly via the provider, so
it's only needed for manual node debugging (`talosctl health`, `talosctl logs`, etc).

Cluster secrets are generated automatically by `talos_machine_secrets` on the first
`tofu apply` — no manual `age-keygen`/`talhelper gensecret`/`sops` step needed, and
nothing to commit for it.

To rotate cluster secrets: `tofu taint talos_machine_secrets.this && tofu apply`.

## Workflow

```bash
# Phase 1: create VMs to get their MAC addresses for DHCP reservations
tofu apply -target=module.control_plane_vms -target=module.worker_vms

# → Check outputs for MAC addresses:
tofu output control_plane_mac_addresses
tofu output worker_mac_addresses

# → Configure DHCP reservations in your router: MAC → static IP
# → Power on the VMs in Proxmox, wait for them to boot into Talos maintenance mode
#    (you should see the Talos console on the Proxmox VM screen)

# Phase 2: generate configs, apply to nodes, bootstrap, get kubeconfig
# (also installs ArgoCD via Helm if argocd_github_repo is set)
tofu apply

# Use the cluster
export KUBECONFIG=$(tofu output -raw kubeconfig_path)
kubectl get nodes
```

This project uses **OpenTofu** (`tofu`), not Terraform — same HCL and workflow, different binary.

## Key design decisions

- **`for_each` over `count`** for VMs and machine config applies: adding/removing a middle node only affects that node
- **Typed `talos_*` resources instead of shelling out**: a failed `talos_machine_configuration_apply`/`talos_machine_bootstrap` (e.g. a node not powered on yet) simply isn't recorded in state, so the next `tofu apply` retries automatically — no custom taint/retry scripting needed
- **`local_file`** for kubeconfig/talosconfig: re-wraps the provider's in-state output onto disk for `talosctl`/`kubectl`/the `helm`+`kubernetes` providers to consume; the files themselves are never edited by hand, only regenerated

## Talos image schematic

Generate at https://factory.talos.dev/ — pick extensions, copy the schematic ID.
Minimum for Proxmox: `siderolabs/qemu-guest-agent`
For Tailscale at the OS level: also add `siderolabs/tailscale`

## State and secrets

| File | In git? | Contains |
|---|---|---|
| `terraform.tfvars` | ❌ never | Proxmox API token and IP addresses |
| `terraform.tfstate` | ❌ never | Terraform state — contains cluster secrets generated by `talos_machine_secrets`, the Proxmox token, and the ArgoCD deploy key's private key |
| `kubeconfig` | ❌ never | Cluster access credentials — regenerated by Terraform |
| `talosconfig` | ❌ never | Talos client config — regenerated by Terraform |

There's no more SOPS-encrypted file to commit: `talos_machine_secrets` generates cluster
secrets and Terraform keeps them only in `terraform.tfstate`, the same trust model this
repo already used for the Proxmox token and the ArgoCD deploy key's private key.

`.homelab-apps-checkout/` (gitignored) holds a fresh clone of the mono repo, re-cloned on
every apply by `terraform_data.homelab_apps_checkout` — never edit it by hand, it's
overwritten on the next apply. Requires `GITHUB_TOKEN` to be set (same one the `github`
provider needs) with read access to `argocd_github_repo`.

`terraform.tfvars` also holds the Tailscale OAuth client ID/secret if you set them —
another reason it's never committed. `terraform.tfstate` stores their values too.
