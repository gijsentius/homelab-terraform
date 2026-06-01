# gijsentius-terraform

Terraform project that provisions a homelab Kubernetes cluster on Proxmox using Talos Linux.

## What this manages

- **Proxmox VMs** running Talos Linux (immutable, API-driven Kubernetes OS)
- **talconfig.yaml** rendered from Terraform variables and a template
- **talhelper** execution: config generation, applying to nodes, bootstrapping etcd, kubeconfig retrieval

The cluster will run **Crossplane**, **Backstage**, and **ArgoCD** to manage all homelab resources.

## Providers

| Provider | Purpose |
|---|---|
| `bpg/proxmox` | Create/manage Proxmox VMs, download ISO images |
| `hashicorp/local` | Render and write `talconfig.yaml` from a template |

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
```

## talhelper workflow

talhelper is a wrapper around talosctl that turns a single `talconfig.yaml` into per-node
machine configs and the talosctl commands to apply/bootstrap them.

Terraform's role here:
1. Render `talconfig.yaml` from `templates/talconfig.yaml.tftpl` + your variables
2. Run `talhelper genconfig` when `talconfig.yaml` changes
3. Run the apply/bootstrap/kubeconfig commands in sequence

## First-time setup

```bash
# Install tools
brew install age sops talhelper talosctl kubectl

# --- SOPS key pair (once per machine) ---
# Generate an age key pair
age-keygen -o age.key
# Prints: "Public key: age1..."  ← copy this into .sops.yaml

# Move the private key to the default SOPS location (talhelper decrypts from here)
mkdir -p ~/.config/sops/age
mv age.key ~/.config/sops/age/keys.txt

# Put your public key in .sops.yaml, then commit .sops.yaml

# --- Cluster secrets (once per cluster) ---
# Generate and immediately encrypt with SOPS
talhelper gensecret > talsecret.sops.yaml
sops --encrypt --in-place talsecret.sops.yaml

# talsecret.sops.yaml is now safe to commit — the contents are encrypted
git add .sops.yaml talsecret.sops.yaml

# --- Terraform ---
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init
```

## Workflow

```bash
# Phase 1: create VMs to get their MAC addresses for DHCP reservations
terraform apply -target=module.control_plane_vms -target=module.worker_vms

# → Check outputs for MAC addresses:
terraform output control_plane_mac_addresses
terraform output worker_mac_addresses

# → Configure DHCP reservations in your router: MAC → static IP
# → Power on the VMs in Proxmox, wait for them to boot into Talos maintenance mode
#    (you should see the Talos console on the Proxmox VM screen)

# Phase 2: generate configs, apply to nodes, bootstrap, get kubeconfig
terraform apply

# Use the cluster
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes
```

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
| `.sops.yaml` | ✅ yes | age public key + encryption rules (safe to commit) |
| `~/.config/sops/age/keys.txt` | ❌ never | age private key — stays on your machine |
| `terraform.tfvars` | ❌ never | Proxmox API token and IP addresses |
| `terraform.tfstate` | ❌ never | Terraform state (contains Proxmox token) |
| `clusterconfig/` | ❌ never | Generated machine configs — recreated by Terraform |
| `kubeconfig` | ❌ never | Cluster access credentials |
