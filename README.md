# homelab-terraform

Provisions a Talos Linux Kubernetes cluster on Proxmox and bootstraps it with ArgoCD. After the initial apply, ArgoCD manages all further workloads from the [homelab](../homelab) mono repo.

## What Terraform does

```
terraform apply
  ├── Downloads Talos ISO to Proxmox
  ├── Creates control plane and worker VMs
  ├── Renders talconfig.yaml from your variables
  ├── Runs talhelper genconfig (per-node machine configs)
  ├── Applies machine configs to all nodes
  ├── Bootstraps etcd
  ├── Retrieves kubeconfig
  ├── Uploads an SSH deploy key to your GitHub mono repo
  └── Installs the homelab-bootstrap Helm chart
        ├── ArgoCD
        ├── ArgoCD repo credential Secret (SSH deploy key)
        ├── AppProject
        └── ApplicationSet → ArgoCD discovers and deploys everything else
```

## Repo structure

```
main.tf                     All resources: ISO, VMs, Talos bootstrap, ArgoCD
variables.tf                Input variables with descriptions
outputs.tf                  VM MAC addresses, kubeconfig/talosconfig paths
providers.tf                Provider configuration
versions.tf                 Provider version constraints
terraform.tfvars.example    Copy to terraform.tfvars and fill in
.sops.yaml                  SOPS config — add your age public key here
talsecret.sops.yaml         SOPS-encrypted cluster secrets (safe to commit)
templates/
  talconfig.yaml.tftpl      talhelper cluster definition template
modules/
  proxmox_vm/               Creates one Proxmox VM from a Talos ISO
```

## Secrets and state

| File | In git? | Contains |
|---|---|---|
| `talsecret.sops.yaml` | ✅ yes | Cluster CA and bootstrap tokens — SOPS-encrypted |
| `.sops.yaml` | ✅ yes | Age public key and encryption rules |
| `~/.config/sops/age/keys.txt` | ❌ never | Age private key |
| `terraform.tfvars` | ❌ never | Proxmox token, node IPs |
| `terraform.tfstate` | ❌ never | Terraform state — contains the SSH deploy key |
| `clusterconfig/` | ❌ never | Generated per-node machine configs |
| `kubeconfig` | ❌ never | Cluster access credentials |

---

# Deployment guide

Start here if you have a bare Proxmox machine and nothing else.

## Prerequisites

### Tools — install on the machine running Terraform

```bash
brew install age sops terraform talhelper talosctl kubectl helm gh
```

| Tool | Purpose |
|---|---|
| `age` + `sops` | Encrypt cluster secrets so they are safe to commit |
| `terraform` | Provision VMs and orchestrate the bootstrap |
| `talhelper` | Generate per-node Talos machine configs from `talconfig.yaml` |
| `talosctl` | Talk to Talos nodes directly (health checks, logs) |
| `kubectl` | Interact with the Kubernetes API |
| `helm` | Used by Terraform to install the bootstrap chart |
| `gh` | Upload the ArgoCD SSH deploy key to GitHub |

### Proxmox

A Proxmox VE host reachable on your LAN with an API token. Create one:

1. Log in to Proxmox → **Datacenter → Permissions → API Tokens → Add**
2. User: `root@pam`, Token ID: `terraform`, uncheck "Privilege Separation"
3. Copy the token secret — shown only once
4. Grant the token the `Administrator` role at the `/` (Datacenter) level

Verify the API is reachable:
```bash
curl -sk https://<proxmox-ip>:8006/api2/json/version | jq .data.version
```

### GitHub

A GitHub account with:
- The [homelab](../homelab) mono repo pushed and accessible
- The `gh` CLI logged in with `repo` scope:

```bash
gh auth login
gh auth status   # confirm 'repo' scope is listed
# If missing: gh auth refresh -s repo
```

### Tailscale

A Tailscale account. The Tailscale **Kubernetes operator** (deployed by ArgoCD from the mono repo) exposes cluster services on your tailnet — the nodes themselves do not join Tailscale.

You need two things from the Tailscale admin console before deploying:
1. A **reusable auth key** is not needed — that was for node-level Tailscale which is not used
2. An **OAuth client** for the operator — created in step 5 below

### Cloudflare

A Cloudflare account managing your domain's DNS. You need an API token with:
- `Zone:DNS:Edit`
- `Zone:Zone:Read`

scoped to your domain's zone. Create it at **Cloudflare dashboard → My Profile → API Tokens**.

---

## Step 1 — SOPS age key

SOPS encrypts your Talos cluster secrets so they are safe to commit.

```bash
# Generate key pair — the public key is printed to stdout
age-keygen -o age.key

# Move the private key to the SOPS default location
mkdir -p ~/.config/sops/age
mv age.key ~/.config/sops/age/keys.txt
```

Open `.sops.yaml` in this repo and put your public key in it:

```yaml
creation_rules:
  - path_regex: talsecret\.sops\.yaml$
    age: >-
      age1YOUR_PUBLIC_KEY_HERE
```

Commit `.sops.yaml` — the public key is safe to store in git.

---

## Step 2 — Talos image schematic

Go to [factory.talos.dev](https://factory.talos.dev/) and build a schematic with one extension:

- `siderolabs/qemu-guest-agent` — allows Proxmox to detect VM IPs and do graceful shutdowns

Copy the **schematic ID**. You will put it in `terraform.tfvars` as `talos_schematic_id`.

---

## Step 3 — Generate and encrypt cluster secrets

```bash
talhelper gensecret > talsecret.sops.yaml
sops --encrypt --in-place talsecret.sops.yaml

git add .sops.yaml talsecret.sops.yaml
git commit -m "add SOPS config and encrypted cluster secrets"
git push
```

---

## Step 4 — Configure terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Fill in every value. Key things to set:

| Variable | What to put |
|---|---|
| `proxmox_endpoint` | `https://<proxmox-ip>:8006` |
| `proxmox_api_token` | Token from Step 1 in format `root@pam!terraform=<secret>` |
| `proxmox_node` | Node name shown in the Proxmox sidebar (usually `pve`) |
| `proxmox_datastore_id` | Storage pool for VM disks — run `pvesm status` on the host |
| `proxmox_iso_datastore_id` | Storage pool for ISO files |
| `talos_schematic_id` | Schematic ID from Step 2 |
| `control_plane_nodes` | Name, IP, and VM ID for each control plane node |
| `worker_nodes` | Name, IP, and VM ID for each worker node |
| `node_network_gateway` | Your LAN gateway IP |
| `network_bridge` | Proxmox network bridge (check **Node → System → Network**, usually `vmbr0`) |
| `argocd_github_repo` | `yourname/homelab` |

---

## Step 5 — Create VMs and get MAC addresses

```bash
terraform init
terraform apply -target=module.control_plane_vms -target=module.worker_vms
```

Once done, get the MAC addresses:

```bash
terraform output control_plane_mac_addresses
terraform output worker_mac_addresses
```

Go to your router and create a **DHCP reservation** for each MAC → IP pair matching what you set in `terraform.tfvars`. The IPs must match exactly — Talos machine configs are generated with those IPs baked in.

---

## Step 6 — Boot the VMs into Talos maintenance mode

Power on the VMs in the Proxmox web UI. Open the console on one — you should see the Talos boot screen within a minute. Talos waits in **maintenance mode** until it receives a machine config.

Wait until all nodes are reachable before continuing:

```bash
# Talos maintenance API port
nc -zv 192.168.1.110 50000
```

---

## Step 7 — Full apply

```bash
export GITHUB_TOKEN=$(gh auth token)
terraform apply
```

Terraform will, in order:

1. Render `talconfig.yaml` from your variables
2. Run `talhelper genconfig` → per-node machine configs in `clusterconfig/`
3. Apply machine configs to all nodes (they reboot and configure themselves)
4. Bootstrap etcd on the first control plane node
5. Retrieve `kubeconfig`
6. Install the `homelab-bootstrap` Helm chart which deploys:
   - ArgoCD
   - The ArgoCD repo credential Secret (SSH deploy key)
   - The `homelab` AppProject
   - The `infrastructure` ApplicationSet

ArgoCD immediately begins syncing the mono repo and deploying infrastructure in phase order.

This takes **10–15 minutes** end to end.

---

## Step 8 — Apply the Tailscale operator OAuth secret

The Tailscale operator needs an OAuth client to register devices on your tailnet. This secret must be applied manually before the operator can function.

Create the OAuth client first:
1. Go to [Tailscale admin → Settings → OAuth](https://login.tailscale.com/admin/settings/oauth)
2. Create a client with **Devices: write** scope, tagged `tag:k8s`
3. Copy the client ID and secret

Apply the secret to the cluster:

```bash
export KUBECONFIG=$(pwd)/kubeconfig

kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: tailscale
stringData:
  client_id: "YOUR_CLIENT_ID"
  client_secret: "YOUR_CLIENT_SECRET"
EOF
```

Once applied, the operator registers the Envoy Gateway and Teleport as tailnet devices. Approve them in the [Tailscale admin console](https://login.tailscale.com/admin/machines).

---

## Step 9 — Unseal OpenBao and configure secrets

OpenBao starts sealed on first deploy. Port-forward to it and initialise:

```bash
kubectl port-forward -n openbao svc/openbao 8200 &
export BAO_ADDR=http://localhost:8200

# Initialise — prints 5 unseal keys and a root token
# Store these somewhere safe (password manager)
bao operator init

# Unseal — run 3 times, each time with a different key from the output above
bao operator unseal

# Enable Kubernetes auth so External Secrets Operator can read secrets
bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# Create a policy that allows reading any secret
bao policy write external-secrets - <<EOF
path "secret/data/*" { capabilities = ["read"] }
EOF

# Create a role bound to the ESO service account
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h

# Write the Cloudflare API token so cert-manager can do DNS-01 challenges
bao kv put secret/cert-manager/cloudflare \
  api-token="YOUR_CLOUDFLARE_API_TOKEN"
```

Once the Cloudflare token is written, `cert-manager-config` syncs successfully and the Envoy Gateway gets its Let's Encrypt certificate.

---

## Step 10 — Create the first Teleport user

```bash
kubectl exec -n teleport deploy/teleport -- \
  tctl users add admin --roles=editor,access --logins=root
```

Follow the printed URL to set a password. Then log in from your local machine:

```bash
# Connect to Teleport via its Tailscale hostname
tsh login --proxy=teleport:443 --user=admin

# Register the cluster with kubectl
tsh kube login homelab

# Verify
kubectl get nodes
```

From this point on, use `tsh` and `kubectl` through Teleport for all cluster access. The local `kubeconfig` is only needed for recovery.

---

## Accessing the cluster during bootstrap

Before Teleport is running you can use the local kubeconfig:

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

To check ArgoCD sync status during bootstrap:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 --kubeconfig kubeconfig
# Open https://localhost:8080
# Password:
kubectl get secret argocd-initial-admin-secret -n argocd \
  --kubeconfig kubeconfig \
  -o jsonpath="{.data.password}" | base64 -d
```

For Talos node debugging:

```bash
export TALOSCONFIG=$(pwd)/clusterconfig/talosconfig
talosctl --nodes 192.168.1.110 health
talosctl --nodes 192.168.1.110 logs kubelet
```
