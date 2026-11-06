terraform {
  backend "azurerm" {
    resource_group_name  = "RG-TerraformState"
    storage_account_name = "tfstatentfsnerdlab"
    container_name       = "tfstate"
    key                  = "aum-lab.tfstate"
    # Separate from ntfs-lab.terraform.tfstate and rbac-lab.terraform.tfstate
    # All three labs share the same container without affecting each other
  }
}
