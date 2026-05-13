resource "azurerm_public_ip" "dc" {
  name                = "pip-${var.vm_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "dc" {
  name                = "nic-${var.vm_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.private_ip_address
    public_ip_address_id          = azurerm_public_ip.dc.id
  }
}

resource "azurerm_windows_virtual_machine" "dc" {
  name                  = var.vm_name
  computer_name         = var.vm_name
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.dc.id]
  tags                  = var.tags

  os_disk {
    name                 = "osdisk-${var.vm_name}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "install_ad" {
  name                       = "install-ad"
  virtual_machine_id         = azurerm_windows_virtual_machine.dc.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    script = base64encode(var.install_script)
  })

  timeouts {
    create = "45m"
    update = "45m"
    delete = "15m"
  }
}

resource "azurerm_virtual_network_dns_servers" "this" {
  virtual_network_id = var.virtual_network_id
  dns_servers        = [var.private_ip_address]

  depends_on = [azurerm_virtual_machine_extension.install_ad]
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "dc" {
  virtual_machine_id    = azurerm_windows_virtual_machine.dc.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}