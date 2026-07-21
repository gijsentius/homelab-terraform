# gijsentius-terraform

Terraform project that provisions a homelab Kubernetes cluster on Proxmox using Talos Linux.

## What this manages

- **Proxmox VMs** running Talos Linux (immutable, API-driven Kubernetes OS)
- **talconfig.yaml** rendered from Terraform variables and a template
- **talhelper** execution: config generation, applying to nodes, bootstrapping etcd, kubeconfig retrieval

The cluster will run **Crossplane**, **Backstage**, and **ArgoCD** to manage all homelab resources.

Terraform also bootstraps **ArgoCD** itself: it generates a read-only GitHub deploy key,
uploads it to your mono repo, clones the repo fresh into `.homelab-apps-checkout/` (via
`GITHUB_TOKEN`, on every apply), and installs ArgoCD plus an AppProject/ApplicationSet
that discovers apps in that repo, using the chart at `apps/` in the clone. This step is
optional and only runs when `argocd_github_repo` is set.

## Providers

| Provider | Purpose |
|---|---|
| `bpg/proxmox` | Create/manage Proxmox VMs, download ISO images |
| `hashicorp/local` | Render and write `talconfig.yaml` from a template |
| `hashicorp/tls` | Generate the ArgoCD SSH deploy key pair |
| `integrations/github` | Upload the deploy key to your mono repo |
| `hashicorp/helm` | Install ArgoCD + bootstrap chart into the new cluster |

## File structure

```
versions.tf                      # Provider version constraints
providers.tf                     # Provider config (credentials via variables)
variables.tf                     # All input variables with descriptions
main.tf                          # Resources: ISO, VMs, talconfig, talhelper execution
outputs.tf                       # VM MAC addresses, paths to kubeconfig/talosconfig
terraform.tfvars.example         # Template — copy to terraform.tfvars and fill in
templates/
  talconfig.yaml.tftpl           # talhelper cluster definition template
modules/
  proxmox_vm/                    # Reusable module: creates one Proxmox VM

.homelab-apps-checkout/          # Gitignored — mono repo cloned fresh here on every apply
                                  # by terraform_data.homelab_apps_checkout; not a sibling dir
                                  # you maintain yourself, don't rely on its contents persisting
```

## talhelper workflow

talhelper is a wrapper around talosctl that turns a single `talconfig.yaml` into per-node
machine configs and the talosctl commands to apply/bootstrap them.

Terraform's role here:
1. Generate the age keypair (`age.key`) and `.sops.yaml`, and generate + SOPS-encrypt
   `talsecret.sops.yaml` — both run once via `terraform_data` resources with
   `ignore_changes = all`, so they're stable across applies (see main.tf)
2. Render `talconfig.yaml` from `templates/talconfig.yaml.tftpl` + your variables
3. Run `talhelper genconfig` when `talconfig.yaml` changes
4. Run the apply/bootstrap/kubeconfig commands in sequence
5. If `argocd_github_repo` is set: create a GitHub deploy key and install ArgoCD via Helm

## First-time setup

```bash
# Install tools
brew install age sops talhelper talosctl kubectl

# --- Terraform ---
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
tofu init
```

The age keypair (`age.key` + `.sops.yaml`) and the SOPS-encrypted `talsecret.sops.yaml` are
now generated automatically by `terraform_data` resources in `main.tf` on the first
`tofu apply` — no manual `age-keygen`/`talhelper gensecret` step needed. Each is guarded by
`ignore_changes = all`, so once created they're never regenerated or rotated by subsequent
applies. Commit `.sops.yaml` and `talsecret.sops.yaml` after the first apply; `age.key`
stays local (gitignored) since it's the private key.

To rotate cluster secrets: delete `talsecret.sops.yaml` and re-apply.

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

- **`for_each` over `count`** for VMs: adding/removing a middle node only affects that node
- **`terraform_data` + `local-exec`**: runs talhelper commands on the machine running Terraform
- **`triggers_replace`** on each talhelper step: re-runs the command when inputs change, and Terraform retries failed commands on the next apply (nodes not ready = tainted resource = automatic retry)
- **`local_file`** for `talconfig.yaml`: the file is owned by Terraform — edit the template and variables, not the generated file

## Talos image schematic

Generate at https://factory.talos.dev/ — pick extensions, copy the schematic ID.
Minimum for Proxmox: `siderolabs/qemu-guest-agent`
For Tailscale at the OS level: also add `siderolabs/tailscale`

## State and secrets

| File | In git? | Contains |
|---|---|---|
| `talsecret.sops.yaml` | ✅ yes | SOPS-encrypted cluster secrets (safe to commit) |
| `.sops.yaml` | ✅ yes | age public key + encryption rules (safe to commit) — written by `terraform_data.age_keygen` |
| `age.key` | ❌ never | age private key — generated by `terraform_data.age_keygen`, stays local |
| `terraform.tfvars` | ❌ never | Proxmox API token and IP addresses |
| `terraform.tfstate` | ❌ never | Terraform state (contains Proxmox token and the ArgoCD deploy key's private key) |
| `clusterconfig/` | ❌ never | Generated machine configs — recreated by Terraform |
| `kubeconfig` | ❌ never | Cluster access credentials |

Note: talhelper normally decrypts SOPS files using the key at `~/.config/sops/age/keys.txt`,
but this repo's `terraform_data` steps instead point `SOPS_AGE_KEY_FILE` at the local
`age.key`, so no global SOPS key setup is required on the machine running Terraform.

`.homelab-apps-checkout/` (gitignored) holds a fresh clone of the mono repo, re-cloned on
every apply by `terraform_data.homelab_apps_checkout` — never edit it by hand, it's
overwritten on the next apply. Requires `GITHUB_TOKEN` to be set (same one the `github`
provider needs) with read access to `argocd_github_repo`.
