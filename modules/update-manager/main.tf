variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "resource_group_id"   { type = string }
variable "dc01_id"             { type = string }
variable "ws01_id"             { type = string }
variable "ws02_id"             { type = string }
 
# Azure Policy: auto-enroll ALL VMs in this resource group into periodic assessment.
# Policy 59efceea = built-in "Configure periodic checking for missing system updates on Azure VMs"
# This runs assessment only — it does not apply patches.
# Any new VM added to rg-aumlab is automatically enrolled without any additional action.
resource "azurerm_resource_group_policy_assignment" "aum_assessment" {
  name                 = "aum-periodic-assessment"
  resource_group_id    = var.resource_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/59efceea-0c96-497e-a4a1-4eb2290dac15"
  location             = var.location   # REQUIRED once an identity is attached

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "aum_policy_remediation" {
  scope                = var.resource_group_id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_resource_group_policy_assignment.aum_assessment.identity[0].principal_id
}
 
# Maintenance Configuration: WHEN to patch and WHAT to patch.
# scope = InGuestPatch: patches run inside the guest OS, not at the hypervisor.
# in_guest_user_patch_mode = User: this Terraform config owns the schedule.
# classifications: Critical, Security, UpdateRollup — not all available patches.
# reboot = IfRequired: only reboots if a patch requires it.
# IMPORTANT: Update start_date_time to a future date before running terraform apply.
resource "azurerm_maintenance_configuration" "weekly" {
  name                     = "aum-weekly-patches"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  scope                    = "InGuestPatch"
  in_guest_user_patch_mode = "User"
  window {
    start_date_time = "2026-08-01 02:00"   # Update to a future date before deploying
    time_zone       = "Eastern Standard Time"
    duration        = "03:00"
    recur_every     = "Week"
  }
  install_patches {
    windows { classifications_to_include = ["Critical","Security","UpdateRollup"] }
    reboot = "IfRequired"
  }
}
 
# Maintenance Assignments: link the weekly schedule to each VM.
# Without these, VMs are assessed (via policy) but never automatically patched.
# Assessment and patching are separate operations — both are required.
resource "azurerm_maintenance_assignment_virtual_machine" "dc01" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.weekly.id
  virtual_machine_id           = var.dc01_id
}
resource "azurerm_maintenance_assignment_virtual_machine" "ws01" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.weekly.id
  virtual_machine_id           = var.ws01_id
}
resource "azurerm_maintenance_assignment_virtual_machine" "ws02" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.weekly.id
  virtual_machine_id           = var.ws02_id
}
