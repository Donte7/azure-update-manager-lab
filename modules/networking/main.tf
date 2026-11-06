variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "allowed_rdp_ip"      { type = string }
 
resource "azurerm_virtual_network" "main" {
  name                = "vnet-aumlab"
  address_space       = ["10.0.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group_name
}
 
resource "azurerm_subnet" "main" {
  name                 = "snet-aumlab"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}
resource "azurerm_network_security_group" "main" {
  name                = "nsg-aumlab"
  location            = var.location
  resource_group_name = var.resource_group_name
  security_rule {
    name                       = "AllowRDP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.allowed_rdp_ip
    destination_address_prefix = "*"
  }
}
 
# Without this association, the NSG exists but does not protect anything
resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}
 
output "subnet_id" { value = azurerm_subnet.main.id }
