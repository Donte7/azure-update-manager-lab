output "dc01_public_ip" { value = module.compute.dc01_public_ip }
output "ws01_public_ip" { value = module.compute.ws01_public_ip }
output "ws02_public_ip" { value = module.compute.ws02_public_ip }
output "key_vault_name" { value = module.keyvault.key_vault_name }
output "resource_group" { value = azurerm_resource_group.main.name }
