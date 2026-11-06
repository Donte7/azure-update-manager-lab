resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

module "networking" {
  source              = "./modules/networking"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allowed_rdp_ip      = var.allowed_rdp_ip
}

module "keyvault" {
  source              = "./modules/keyvault"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  admin_password      = var.admin_password
}

module "compute" {
  source              = "./modules/compute"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = module.networking.subnet_id
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  domain_name         = var.domain_name
  domain_netbios      = var.domain_netbios
}

# update_manager depends on compute outputs (dc01_id, ws01_id, ws02_id)
# Terraform infers this dependency automatically from the variable references
module "update_manager" {
  source              = "./modules/update-manager"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  resource_group_id   = azurerm_resource_group.main.id
  dc01_id             = module.compute.dc01_id
  ws01_id             = module.compute.ws01_id
  ws02_id             = module.compute.ws02_id
}
