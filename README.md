# gijsentius-terraform

Terraform project that provisions a Talos Linux Kubernetes cluster on a Proxmox host and bootstraps it with ArgoCD. After the initial apply, ArgoCD manages all further workloads (Teleport, Crossplane, Backstage, etc.) from a separate mono repo.

## How it works

```
terraform apply
  ├── Downloads Talos ISO to Proxmox
  ├── Creates control plane and worker VMs
  ├── Renders talconfig.yaml from your variables
  ├── Runs talhelper to generate per-node Talos machine configs
  ├── Applies configs to nodes and bootstraps etcd
  ├── Retrieves kubeconfig
  ├── Installs ArgoCD via Helm
  ├── Uploads an SSH deploy key to your GitHub mono repo
  └── Creates a root ArgoCD Application pointing at your mono repo
           └── ArgoCD takes over → deploys Teleport, Crossplane, Backstage, ...
```

Cluster nodes join your Tailscale tailnet on first boot via the Tailscale system extension, giving you remote access to the Kubernetes API without exposing it to the public internet.

---

## Prerequisites

### Tools

Install the following on the machine you will run Terraform from:

```bash
# macOS
brew install age sops terraform talhelper talosctl kubectl helm gh

# Arch Linux
pacman -S age sops terraform
yay -S talhelper-bin talosctl-bin
brew install gh   # or: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
```

| Tool | Purpose |
|---|---|
| `age` + `sops` | Encrypt cluster secrets so they can be committed to git |
| `terraform` | Provision VMs and orchestrate the full bootstrap |
| `talhelper` | Generate Talos machine configs from `talconfig.yaml` |
| `talosctl` | Interact with Talos nodes directly (debugging, health checks) |
| `kubectl` | Interact with the Kubernetes API |
| `helm` | Used by Terraform to install ArgoCD |
| `gh` | Authenticate with GitHub so Terraform can upload the ArgoCD deploy key |

### Proxmox

- A Proxmox VE host reachable on your LAN
- An API token with sufficient permissions (see [Proxmox setup](#proxmox-setup) below)

### Tailscale

- A Tailscale account and tailnet — [sign up free](https://tailscale.com/)

### GitHub

- A GitHub account with a mono repo for your homelab GitOps config
- The `gh` CLI logged in: `gh auth login`

---

## One-time setup

These steps are done once per machine. Skip any you have already done.

### 1. SOPS age key

SOPS encrypts your Talos cluster secrets so they can be safely committed to git.

```bash
# Generate a key pair
age-keygen -o age.key
# Output includes: Public key: age1...
# Copy that public key — you will need it in the next step

# Move the private key to SOPS's default location
mkdir -p ~/.config/sops/age
mv age.key ~/.config/sops/age/keys.txt
```

Open `.sops.yaml` in this repo and replace the placeholder with your public key:

```yaml
creation_rules:
  - path_regex: talsecret\.sops\.yaml$
    age: >-
      age1YOUR_PUBLIC_KEY_HERE
```

Commit `.sops.yaml` — the public key is safe to store in git.

### 2. Proxmox setup

Create an API token in the Proxmox web UI:

1. Log in to Proxmox → **Datacenter → Permissions → API Tokens → Add**
2. User: `root@pam`, Token ID: `terraform`, uncheck "Privilege Separation"
3. Copy the token secret — it is only shown once
4. Grant the token the `Administrator` role on `/` (Datacenter level)

Verify the API is reachable:

```bash
curl -sk https://<proxmox-ip>:8006/api2/json/version | jq .data.version
```

### 3. Talos image schematic

Talos uses a "schematic" to define which system extensions are baked into the OS image. You need at least two extensions for this setup:

- `siderolabs/qemu-guest-agent` — Proxmox VM communication (IP detection, graceful shutdown)
- `siderolabs/tailscale` — Tailscale VPN at the OS level

1. Go to [factory.talos.dev](https://factory.talos.dev/)
2. Add both extensions listed above
3. Copy the schematic ID — you will use it in `terraform.tfvars`

### 4. Tailscale auth key

Nodes use this key to join your tailnet on first boot.

1. Go to [Tailscale admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys)
2. Generate a key with **Reusable** enabled (all nodes share one key)
3. Copy the key — you will use it in `terraform.tfvars`

After the first apply, you must approve the subnet routes the nodes advertise in the [Tailscale admin console](https://login.tailscale.com/admin/machines). Until you do, traffic to your home LAN will not route through the tailnet.

### 5. GitHub authentication

```bash
# Log in if you have not already
gh auth login

# Ensure the token has the 'repo' scope (needed to create deploy keys)
gh auth status

# If 'repo' scope is missing:
gh auth refresh -s repo
```

---

## Configuration

```bash
git clone https://github.com/yourname/gijsentius-terraform.git
cd gijsentius-terraform

cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in every value. The table below explains each section:

| Section | What to fill in |
|---|---|
| **Proxmox connection** | API endpoint, token, node name, storage pool names |
| **Talos image** | Schematic ID from factory.talos.dev, Talos version |
| **Cluster definition** | Cluster name, node IPs and VM IDs, disk device |
| **Network** | LAN gateway, subnet prefix, DNS servers, Proxmox bridge name |
| **VM sizing** | CPU, RAM, disk per node type |
| **Tailscale** | Auth key from the Tailscale admin console |
| **ArgoCD** | GitHub repo in `owner/repo` format, branch, path to your app manifests |

### Node IPs and DHCP reservations

Talos nodes need stable IP addresses. The recommended approach is **DHCP reservations** in your router: once Terraform creates the VMs you get their MAC addresses, then you map each MAC to the IP you defined in `terraform.tfvars`. This keeps the IPs managed in one place (your router) rather than in multiple config files.

### Finding your Proxmox storage pool names

SSH into your Proxmox host and run:

```bash
pvesm status
```

- The pool listed under `Content: images` is your `proxmox_datastore_id` (e.g. `local-lvm`)
- The pool listed under `Content: iso` is your `proxmox_iso_datastore_id` (e.g. `local`)

### Finding your Proxmox network bridge

In the Proxmox web UI: **Node → System → Network**. The bridge name is usually `vmbr0`.

---

## Deploy

### Step 1 — Generate cluster secrets

```bash
talhelper gensecret > talsecret.sops.yaml
sops --encrypt --in-place talsecret.sops.yaml
```

The encrypted file is safe to commit:

```bash
git add .sops.yaml talsecret.sops.yaml
git commit -m "Add SOPS config and encrypted cluster secrets"
```

### Step 2 — Initialize Terraform

```bash
terraform init
```

This downloads all providers (`bpg/proxmox`, `integrations/github`, `hashicorp/tls`, `hashicorp/local`).

### Step 3 — Create VMs

```bash
terraform apply -target=module.control_plane_vms -target=module.worker_vms
```

This creates the VMs and downloads the Talos ISO to Proxmox. Once done, get the MAC addresses:

```bash
terraform output control_plane_mac_addresses
terraform output worker_mac_addresses
```

Set up DHCP reservations in your router for each MAC → IP pair from `terraform.tfvars`. The IPs must match exactly.

### Step 4 — Boot the VMs

Power on the VMs in the Proxmox web UI. Open the console for one — you should see the Talos boot screen within a minute. Talos will sit in **maintenance mode**, waiting for a machine config.

Wait until all VMs have booted and are reachable at their configured IPs before continuing:

```bash
# Test reachability (Talos maintenance API port)
nc -zv 192.168.1.110 50000
```

### Step 5 — Full apply

Export your GitHub token so Terraform can upload the ArgoCD deploy key:

```bash
export GITHUB_TOKEN=$(gh auth token)
```

Then apply everything:

```bash
terraform apply
```

Terraform will, in order:

1. Render `talconfig.yaml` from your variables
2. Run `talhelper genconfig` to generate per-node machine configs
3. Apply machine configs to all nodes (they reboot and configure themselves)
4. Bootstrap etcd on the first control plane node
5. Retrieve the kubeconfig
6. Install ArgoCD via Helm
7. Generate an SSH key pair and upload the public key to your GitHub repo as a deploy key
8. Create the Kubernetes Secret with the private key in the `argocd` namespace
9. Create the root ArgoCD Application pointing at your mono repo

This takes around 10–15 minutes end to end.

### Step 6 — Approve Tailscale subnet routes

After the apply completes, go to the [Tailscale admin console](https://login.tailscale.com/admin/machines), find your nodes, and approve the subnet routes they advertise. Your home LAN will then be reachable from anywhere on your tailnet.

---

## Accessing the cluster

### From your LAN (or via Tailscale after route approval)

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

### ArgoCD UI (initial bootstrap verification)

ArgoCD is not yet exposed externally — Teleport (deployed from your mono repo) will handle that. For the initial check:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 --kubeconfig kubeconfig
```

Open [https://localhost:8080](https://localhost:8080). Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  --kubeconfig kubeconfig \
  -o jsonpath="{.data.password}" | base64 -d
```

Once your mono repo is syncing, ArgoCD deploys Teleport, which provides permanent remote access. The port-forward is no longer needed after that.

### Talos nodes (debugging)

```bash
export TALOSCONFIG=$(pwd)/clusterconfig/talosconfig
talosctl --nodes 192.168.1.110 health
talosctl --nodes 192.168.1.110 logs kubelet
```

---

## What lives where

| Concern | Where it lives |
|---|---|
| VM provisioning | This repo (Terraform) |
| Talos OS config | This repo (`talconfig.yaml` template + `talsecret.sops.yaml`) |
| ArgoCD bootstrap | This repo (Terraform installs it once) |
| Everything else | Your mono repo (ArgoCD manages it) |

---

## Secrets and state reference

| File / location | In git? | What it contains |
|---|---|---|
| `talsecret.sops.yaml` | ✅ yes | Cluster CA keys and bootstrap tokens, SOPS-encrypted |
| `.sops.yaml` | ✅ yes | Your age public key and encryption rules |
| `~/.config/sops/age/keys.txt` | ❌ never | age private key — stays on your machine only |
| `terraform.tfvars` | ❌ never | Proxmox token, Tailscale auth key, node IPs |
| `terraform.tfstate` | ❌ never | Terraform state — contains the generated SSH deploy key |
| `clusterconfig/` | ❌ never | Generated per-node machine configs, regenerated by Terraform |
| `kubeconfig` | ❌ never | Cluster access credentials |
| `argocd-repo-secret.yaml` | ❌ never | Rendered Secret manifest with SSH private key |

---

## Project structure

```
versions.tf                       Provider version constraints
providers.tf                      Provider configuration
variables.tf                      All input variables with descriptions
main.tf                           All resources: ISO, VMs, Talos, ArgoCD
outputs.tf                        VM MAC addresses, kubeconfig/talosconfig paths
terraform.tfvars.example          Copy this to terraform.tfvars and fill in values
.sops.yaml                        SOPS encryption config (add your age public key here)
talsecret.sops.yaml               SOPS-encrypted cluster secrets (committed to git)
templates/
  talconfig.yaml.tftpl            talhelper cluster definition, rendered by Terraform
  argocd-app.yaml.tftpl           ArgoCD root Application manifest template
  argocd-repo-secret.yaml.tftpl   ArgoCD repo credential Secret template
modules/
  proxmox_vm/                     Reusable module: creates one Proxmox VM from a Talos ISO
```
