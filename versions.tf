terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.77"
    }

    # Writes files to the local filesystem (talconfig.yaml, ArgoCD manifests)
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    # Generates the SSH key pair for the ArgoCD deploy key
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # Uploads the public key as a read-only deploy key to your GitHub repo
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
