# =============================================================================
# Compute module — DC01 (Domain Controller) + WS01/WS02 (domain-joined servers)
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

variable "subnet_id" {
  type = string
}

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "domain_name" {
  type = string
}

variable "domain_netbios" {
  type = string
}

# -----------------------------------------------------------------------------
# Single source of truth for the DC's IP.
# Every DNS reference below points here, so the NIC, the workstation DNS
# settings, and the join script can never drift apart again.
# -----------------------------------------------------------------------------
locals {
  dc01_private_ip = "10.0.1.7"
}

# -----------------------------------------------------------------------------
# Public IPs — Static so addresses are reserved immediately and do not change
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "dc01" {
  name                = "pip-dc01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "ws01" {
  name                = "pip-ws01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "ws02" {
  name                = "pip-ws02"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# -----------------------------------------------------------------------------
# Network interfaces
# -----------------------------------------------------------------------------

# DC01 NIC — STATIC private IP so WS01/WS02 DNS pointing here never breaks
resource "azurerm_network_interface" "dc01" {
  name                = "nic-dc01"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.dc01_private_ip
    public_ip_address_id          = azurerm_public_ip.dc01.id
  }
}

# WS01 and WS02 NICs — Dynamic IPs are fine (they are not DNS targets),
# but their DNS server is set at the Azure NIC level to DC01 so it survives
# reboots and DHCP renewals.
resource "azurerm_network_interface" "ws01" {
  name                = "nic-ws01"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_servers         = [local.dc01_private_ip]

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ws01.id
  }
}

resource "azurerm_network_interface" "ws02" {
  name                = "nic-ws02"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_servers         = [local.dc01_private_ip]

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ws02.id
  }
}

# -----------------------------------------------------------------------------
# Shared image reference
# -----------------------------------------------------------------------------
locals {
  img = {
    pub   = "MicrosoftWindowsServer"
    offer = "WindowsServer"
    sku   = "2022-Datacenter"
    ver   = "latest"
  }
}

# -----------------------------------------------------------------------------
# Virtual machines — Windows Server 2022 Datacenter, Standard_D2s_v3
#
# Patch settings (required by Azure Update Manager scheduled patching):
#   patch_mode = AutomaticByPlatform         -> Azure orchestrates patching
#   patch_assessment_mode = AutomaticByPlatform -> periodic missing-update scans
#   bypass_platform_safety_checks_on_user_schedule_enabled = true
#                                            -> follow OUR maintenance window
# -----------------------------------------------------------------------------
resource "azurerm_windows_virtual_machine" "dc01" {
  name                  = "DC01"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = "Standard_D2s_v3"
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.dc01.id]

  provision_vm_agent                                     = true
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.img.pub
    offer     = local.img.offer
    sku       = local.img.sku
    version   = local.img.ver
  }
}

resource "azurerm_windows_virtual_machine" "ws01" {
  name                  = "WS01"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = "Standard_D2s_v3"
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.ws01.id]

  provision_vm_agent                                     = true
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.img.pub
    offer     = local.img.offer
    sku       = local.img.sku
    version   = local.img.ver
  }
}

resource "azurerm_windows_virtual_machine" "ws02" {
  name                  = "WS02"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = "Standard_D2s_v3"
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.ws02.id]

  provision_vm_agent                                     = true
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.img.pub
    offer     = local.img.offer
    sku       = local.img.sku
    version   = local.img.ver
  }
}

# -----------------------------------------------------------------------------
# DC01: promote to Domain Controller via CustomScriptExtension.
# LAB ONLY: DSRM password is hardcoded and the command sits in plain `settings`.
# Left unchanged on purpose: editing this resource on an existing DC would
# re-run Install-ADDSForest and fail. Move it to protected_settings on the
# next full rebuild.
# -----------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "setup_dc" {
  name                 = "SetupDC"
  virtual_machine_id   = azurerm_windows_virtual_machine.dc01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = join(" ", [
      "powershell -ExecutionPolicy Unrestricted -Command",
      "\"Install-WindowsFeature AD-Domain-Services -IncludeManagementTools;",
      "Import-Module ADDSDeployment;",
      "Install-ADDSForest -DomainName '${var.domain_name}'",
      "-DomainNetBiosName '${var.domain_netbios}'",
      "-SafeModeAdministratorPassword (ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force)",
      "-InstallDns -Force\""
    ])
  })
}

# -----------------------------------------------------------------------------
# WS01 and WS02 domain-join extensions.
#
# depends_on = [setup_dc] means these CANNOT start until DC01 promotion
# succeeds. The script then:
#   1. Points the OS DNS at DC01 (belt-and-braces with the NIC dns_servers)
#   2. Waits up to ~20 min for the domain to resolve (bounded, not infinite)
#   3. Retries Add-Computer up to ~10 min while AD DS finishes starting
#   4. Exits non-zero if the join never succeeds (so Terraform sees a real
#      failure instead of a silent timeout)
#   5. Schedules the reboot 60s out so the extension reports success FIRST
#
# The command is in protected_settings, so the admin password is encrypted
# and NOT visible in the portal or the VM's extension status.
# -----------------------------------------------------------------------------
locals {
  join_cmd = join(" ", [
    "powershell -ExecutionPolicy Unrestricted -Command",
    "\"$a=Get-NetAdapter|?{$_.Status -eq 'Up'}|Select -First 1;",
    "Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses '${local.dc01_private_ip}';",
    "$i=0; do{Start-Sleep 15; $i++}until(([bool](Resolve-DnsName '${var.domain_name}' -ErrorAction SilentlyContinue)) -or ($i -ge 80));",
    "$cred=New-Object PSCredential('${var.domain_netbios}\\${var.admin_username}',(ConvertTo-SecureString '${var.admin_password}' -AsPlainText -Force));",
    "$ok=$false; $j=0;",
    "do{try{Add-Computer -DomainName '${var.domain_name}' -Credential $cred -Force -ErrorAction Stop; $ok=$true}catch{Start-Sleep 30; $j++}}until($ok -or ($j -ge 20));",
    "if(-not $ok){exit 1};",
    "shutdown /r /t 60\""
  ])
}

resource "azurerm_virtual_machine_extension" "join_ws01" {
  name                 = "JoinDomain"
  virtual_machine_id   = azurerm_windows_virtual_machine.ws01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  protected_settings = jsonencode({
    commandToExecute = local.join_cmd
  })

  timeouts {
    create = "60m"
  }

  depends_on = [azurerm_virtual_machine_extension.setup_dc]
}

resource "azurerm_virtual_machine_extension" "join_ws02" {
  name                 = "JoinDomain"
  virtual_machine_id   = azurerm_windows_virtual_machine.ws02.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  protected_settings = jsonencode({
    commandToExecute = local.join_cmd
  })

  timeouts {
    create = "60m"
  }

  depends_on = [azurerm_virtual_machine_extension.setup_dc]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "dc01_id" {
  value = azurerm_windows_virtual_machine.dc01.id
}

output "ws01_id" {
  value = azurerm_windows_virtual_machine.ws01.id
}

output "ws02_id" {
  value = azurerm_windows_virtual_machine.ws02.id
}

output "dc01_private_ip" {
  value = local.dc01_private_ip
}

output "dc01_public_ip" {
  value = azurerm_public_ip.dc01.ip_address
}

output "ws01_public_ip" {
  value = azurerm_public_ip.ws01.ip_address
}

output "ws02_public_ip" {
  value = azurerm_public_ip.ws02.ip_address
}
