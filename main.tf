module "resource_group" {
  source              = "./modules/resourcegroup"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

module "networking" {
  source              = "./modules/vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  vnet_name           = var.vnet_name
  vnet_address_space  = var.vnet_address_space
  subnets             = var.subnets
  nsg_name            = var.nsg_name
  admin_source_ip     = var.admin_source_ip
  tags                = var.tags
  depends_on          = [module.resource_group]
}

resource "random_password" "dc_admin" {
  length           = 20
  special          = true
  override_special = "!@#%^&*()-_=+[]{}<>?,."
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "dc_safe_mode" {
  length           = 20
  special          = true
  override_special = "!@#%^&*()-_=+[]{}<>?,."
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

module "domain_controller" {
  source = "./modules/dc"

  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = module.networking.subnet_ids["dc"]
  virtual_network_id  = module.networking.vnet_id

  vm_name        = var.dc_vm_name
  vm_size        = var.dc_vm_size
  admin_username = var.dc_admin_username
  admin_password = random_password.dc_admin.result

  private_ip_address = var.dc_private_ip
  domain_name        = var.domain_name
  safe_mode_password = random_password.dc_safe_mode.result

  auto_shutdown_time     = var.auto_shutdown_time
  auto_shutdown_timezone = var.auto_shutdown_timezone
  tags                   = var.tags

  depends_on = [module.networking]
}



# ============================================================================
# Wait for AD-DS to finish promoting and DNS service to be reachable
# ============================================================================
resource "time_sleep" "wait_for_dc_dns" {
  depends_on = [
    module.domain_controller
  ]

  create_duration = "180s"
}

module "avd_core" {
  source = "./modules/avd-core"

  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  depends_on = [module.resource_group]
}

module "session_host" {
  source = "./modules/session-host"

  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = module.networking.subnet_ids["avd"]

  vm_name        = var.sh_vm_name
  vm_size        = var.sh_vm_size
  admin_username = var.dc_admin_username
  admin_password = random_password.dc_admin.result

  domain_name           = var.domain_name
  domain_admin_user     = "${var.dc_admin_username}@${var.domain_name}"
  domain_admin_password = random_password.dc_admin.result

  host_pool_name     = module.avd_core.host_pool_name
  registration_token = module.avd_core.registration_token

  auto_shutdown_time     = var.auto_shutdown_time
  auto_shutdown_timezone = var.auto_shutdown_timezone
  tags                   = var.tags

  depends_on = [
    time_sleep.wait_for_dc_dns,
    module.avd_core
  ]
}

module "fslogix_storage" {
  source = "./modules/fslogix-storage"

  resource_group_name     = var.resource_group_name
  location                = var.location
  storage_account_name    = var.fslogix_storage_account_name
  share_quota_gb          = var.fslogix_share_quota_gb
  fslogix_initial_size_mb = var.fslogix_initial_size_mb
  session_host_vm_id      = module.session_host.vm_id
  session_host_vm_name    = module.session_host.vm_name
  tags                    = var.tags

  depends_on = [module.session_host]
}

module "fslogix_automation" {
  source = "./modules/fslogix-automation"

  resource_group_name  = var.resource_group_name
  location             = var.location
  session_host_vm_id   = module.session_host.vm_id
  session_host_vm_name = module.session_host.vm_name
  tags                 = var.tags

  depends_on = [module.fslogix_storage]
}
