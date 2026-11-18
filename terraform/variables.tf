variable "proxmox_endpoint" {
  description = "Proxmox VE API URL, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification of the Proxmox API (self-signed certificates)"
  type        = bool
  default     = false
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox node (the provider uploads cloud-init snippets over SSH)"
  type        = string
  default     = "root"
}

variable "node_name" {
  description = "Proxmox node that hosts the VMs"
  type        = string
}

variable "vm_datastore_id" {
  description = "Datastore for VM disks and cloud-init drives"
  type        = string
  default     = "local-lvm"
}

variable "image_datastore_id" {
  description = "Datastore (with 'iso' content) that stores the downloaded cloud image"
  type        = string
  default     = "local"
}

variable "image_url" {
  description = "Ubuntu 24.04 cloud image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "bridge" {
  description = "Linux bridge the VMs attach to"
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "IPv4 default gateway for the VMs"
  type        = string
}

variable "dns_servers" {
  description = "DNS servers handed to cloud-init"
  type        = list(string)
  default     = ["192.0.2.53"]
}

variable "vm_user" {
  description = "User created by cloud-init; Ansible connects as this user"
  type        = string
  default     = "ansible"
}

variable "ssh_public_key" {
  description = "SSH public key for vm_user"
  type        = string
}

variable "vms" {
  description = "VMs to create. ip is CIDR notation; groups become Ansible inventory groups."
  type = map(object({
    ip        = string
    groups    = list(string)
    cores     = optional(number, 1)
    memory    = optional(number, 1024)
    disk_size = optional(number, 10)
  }))
}
