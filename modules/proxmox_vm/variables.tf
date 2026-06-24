variable "vm_id" {
  description = "Proxmox VM ID — must be unique across your Proxmox instance"
  type        = number
}

variable "name" {
  description = "VM hostname"
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name to create the VM on"
  type        = string
}

variable "datastore_id" {
  description = "Storage pool for VM disks"
  type        = string
}

variable "iso_datastore_id" {
  description = "Storage pool where the Talos ISO lives"
  type        = string
}

variable "talos_iso_file_id" {
  description = "File ID of the uploaded Talos ISO, returned by proxmox_virtual_environment_download_file"
  type        = string
}

variable "cpu_cores" {
  description = "Number of vCPU cores"
  type        = number
}

variable "memory_mb" {
  description = "Memory in MB"
  type        = number
}

variable "disk_gb" {
  description = "Boot disk size in GB"
  type        = number
}

variable "network_bridge" {
  description = "Proxmox bridge to attach the VM's network interface to"
  type        = string
}

variable "mac_address" {
  description = "Static MAC address for the VM's network interface. Leave empty to let Proxmox assign one."
  type        = string
  default     = ""
}
