# =============================================================================
# Key Vault module — stores the VM admin password as a secret
# =============================================================================

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------
data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Unique suffix
# random_string generates an 8-char suffix — Key Vault names must be globally
# unique across all of Azure
# -----------------------------------------------------------------------------
resource "random_string" "kv_suffix" {
  length  = 8
  special = false
  upper   = false
}

# -----------------------------------------------------------------------------
# Key Vault
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                       = "kv-aum-${random_string.kv_suffix.result}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true # REQUIRED — without this, 403 on all secret operations
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

# -----------------------------------------------------------------------------
# RBAC
# Grant the identity running terraform apply write access to secrets.
# current.object_id resolves dynamically to whoever ran az login.
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# -----------------------------------------------------------------------------
# RBAC propagation delay
# Role assignments can take 60+ seconds to become active after creation.
# depends_on alone only waits for creation, so this pause prevents 403s.
# -----------------------------------------------------------------------------
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# -----------------------------------------------------------------------------
# Secrets
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "admin_password" {
  name         = "vm-admin-password"
  value        = var.admin_password
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [time_sleep.rbac_propagation]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_id" {
  value = azurerm_key_vault.main.id
}