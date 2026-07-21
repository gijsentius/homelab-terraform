provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure
}

provider "github" {
  # Authenticates via the GITHUB_TOKEN environment variable.
  # Pull it from your existing gh CLI session before running terraform:
  #   export GITHUB_TOKEN=$(gh auth token)
  #
  # The token needs the 'repo' scope to manage deploy keys.
  # Check current scopes: gh auth status
  owner = local.github_owner
}

provider "helm" {
  kubernetes {
    config_path = "${path.module}/kubeconfig"
  }
}

provider "kubernetes" {
  config_path = "${path.module}/kubeconfig"
}

# hashicorp/tls, hashicorp/local, and terraform_data need no provider block
