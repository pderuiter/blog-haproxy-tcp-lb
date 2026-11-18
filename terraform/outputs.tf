locals {
  groups = distinct(flatten([for vm in values(var.vms) : vm.groups]))
}

output "vm_ips" {
  description = "IPv4 address of every VM"
  value       = { for name, vm in var.vms : name => split("/", vm.ip)[0] }
}

output "ansible_inventory" {
  description = "Ansible inventory (YAML). terraform output -raw ansible_inventory > ../ansible/inventory.yml"
  value = yamlencode({
    all = {
      vars = { ansible_user = var.vm_user }
      children = {
        for group in local.groups : group => {
          hosts = {
            for name, vm in var.vms : name => {
              ansible_host = split("/", vm.ip)[0]
            } if contains(vm.groups, group)
          }
        }
      }
    }
  })
}
