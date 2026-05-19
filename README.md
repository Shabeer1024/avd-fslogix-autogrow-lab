# AVD with FSLogix Profile Auto-Grow Automation

> Self-healing Azure Virtual Desktop infrastructure that detects FSLogix profile capacity issues and resizes individual user containers automatically — zero human intervention.

[![Terraform](https://img.shields.io/badge/Terraform-1.15+-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Azure](https://img.shields.io/badge/Azure-Virtual_Desktop-0089D6?logo=microsoftazure&logoColor=white)](https://azure.microsoft.com/products/virtual-desktop)
[![HCP Terraform](https://img.shields.io/badge/HCP_Terraform-VCS--driven-844FBA?logo=terraform&logoColor=white)](https://www.hashicorp.com/products/terraform)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-5391FE?logo=powershell&logoColor=white)](https://docs.microsoft.com/powershell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

---

## The Problem This Solves

> *"My FSLogix profile is full, please resize it."*

The most repetitive support ticket in any production AVD environment. Without automation:

```
User hits "disk full"  →  Ticket raised  →  Admin investigates  →  
Coordinates user signoff  →  Manually runs Resize-VHD  →  Verifies  →  Closes
```

**4-24 hours of disruption per incident. Multiplied across hundreds of users, it's a constant fire drill.**

This project replaces that cycle with a closed-loop automation that detects and resolves capacity issues before users even notice.

---

## How It Works

```
            ┌──────────────────────────────────────────────────────┐
            │              Closed-Loop Automation                  │
            └──────────────────────────────────────────────────────┘

  ┌─────────────┐      ┌──────────┐      ┌──────────────────┐
  │  Logic App  │─────►│ Webhook  │─────►│ PowerShell       │
  │  (hourly)   │      │          │      │ Runbook          │
  └─────────────┘      └──────────┘      └────────┬─────────┘
                                                  │
                                          executes on
                                                  │
                                                  ▼
  ┌─────────────────────┐                ┌──────────────────┐
  │  Azure Files Share  │◄───────────────│  Hybrid Worker   │
  │  (FSLogix VHDXes)   │   Resize-VHD   │  (= sh01)        │
  │  100 GB hard cap    │     +5 GB      │                  │
  └─────────────────────┘                └──────────────────┘
```

**Per-VHDX decision logic:**

1. Mount VHDX read-only (skip if user is signed in — file is locked)
2. Read free space percentage
3. Dismount
4. If used > 80% AND (total allocated + 5GB) ≤ 100GB → **Resize-VHD +5GB**
5. Log result as JSON

The runbook treats each profile independently — only grows what truly needs it, leaves healthy profiles alone, enforces a hard cap on total allocated capacity to prevent budget surprises.

---

## What Gets Deployed

| Layer | Resources |
|-------|-----------|
| **Foundation** | Resource Group, VNet (10.0.0.0/16), 2 subnets, NSG, custom DNS |
| **Identity** | Domain Controller (`dc01`, Windows Server 2022 Datacenter), AD DS forest `lab.local` |
| **AVD Control Plane** | Workspace, Host Pool (Pooled/BreadthFirst), Desktop Application Group |
| **Session Host** | `sh01` (Windows 11 Multi-Session 23H2), domain-joined, AVD agent registered, FSLogix installed |
| **FSLogix Storage** | Storage Account, SMB file share `profiles` (100 GB cap), VHDX profile containers |
| **Automation** | Azure Automation Account, Hybrid Worker Group, PowerShell Runbook, Webhook |
| **Scheduler** | Logic App with hourly recurrence trigger |

Roughly **25 Azure resources** deployed via **8 Terraform modules**, all version-controlled and reproducible.

---

## Repository Structure

```
.
├── main.tf                          # Composes all modules
├── variables.tf                     # Root inputs
├── outputs.tf                       # Exposes useful values
├── provider.tf                      # AzureRM + HCP Terraform backend
├── terraform.tfvars                 # Lab-specific values
├── LAB-SETUP.md                     # Post-deploy manual steps
│
└── modules/
    ├── resourcegroup/               # Resource Group
    ├── vnet/                        # VNet + subnets + NSG
    ├── dc/                          # Domain Controller + AD DS install
    │   └── scripts/install-ad.ps1.tftpl
    ├── avd-core/                    # AVD Workspace + Host Pool + App Group
    ├── session-host/                # Win11 VM + domain join + AVD agent
    ├── fslogix-storage/             # Storage Account + Share + FSLogix install
    │   └── scripts/install-fslogix.ps1.tftpl
    └── fslogix-automation/          # Automation Account + Runbook + Logic App
        └── scripts/fslogix-autogrow.ps1
```

---

## Quick Start

### Prerequisites

- Azure subscription with Contributor access
- HCP Terraform account (free tier) with workspace connected to this repo
- Azure CLI and Terraform CLI installed locally
- Globally unique storage account name (3-24 lowercase alphanumeric chars)

### 1. Configure

Update `terraform.tfvars`:

```hcl
resource_group_name           = "AVD-Lab"
location                      = "southeastasia"
domain_name                   = "lab.local"
admin_source_ip               = "<your-public-ip>/32"
fslogix_storage_account_name  = "stfslogix<unique-suffix>"
```

### 2. Configure HCP Terraform

In your TFC workspace, add 4 environment variables (mark secret as Sensitive):

```
ARM_CLIENT_ID        = <service-principal-app-id>
ARM_CLIENT_SECRET    = <service-principal-secret>      [Sensitive]
ARM_TENANT_ID        = <azure-tenant-id>
ARM_SUBSCRIPTION_ID  = <azure-subscription-id>
```

Connect the workspace to this GitHub repo, branch `main`.

### 3. Deploy

```bash
git commit --allow-empty -m "Initial deploy"
git push
```

TFC auto-triggers a plan. Review in the UI → **Confirm & Apply** → ~25 minute deploy.

### 4. Post-Deploy

Follow [`LAB-SETUP.md`](./LAB-SETUP.md) to create the test user and validate FSLogix.

---

## Validating the Automation

### Verify infrastructure

```bash
# All VM extensions Succeeded
az vm extension list -g AVD-Lab --vm-name sh01 -o table

# Resize-VHD available on session host
az vm run-command invoke -g AVD-Lab -n sh01 --command-id RunPowerShellScript \
  --scripts "Import-Module Hyper-V; Get-Command Resize-VHD"

# Hybrid Worker registered
az automation hrwg show --automation-account-name aa-fslogix-avdlab \
  -g AVD-Lab --name hwg-fslogix
```

### Demo the auto-grow firing

1. **RDP to DC** (public IP) as `labadmin@lab.local`
2. **From DC, RDP to sh01** (10.0.2.x) as `testuser1@lab.local` → triggers FSLogix VHDX creation
3. **Fill the profile past 80%** from inside the session:
```powershell
   $fs = New-Object IO.FileStream("C:\Users\testuser1\Documents\bigfile.dat", [IO.FileMode]::Create)
   $fs.SetLength(8.5GB); $fs.Close()
```
4. **Sign out testuser1** (so the VHDX unlocks)
5. **Trigger the Logic App manually**:
```bash
   az rest --method POST \
     --uri "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/AVD-Lab/providers/Microsoft.Logic/workflows/lapp-fslogix-autogrow/triggers/hourly-trigger/run?api-version=2016-06-01"
```
6. **Check Automation Account → Jobs → Output** — should show:
```json
   {
     "Status": "Resized",
     "CurrentSizeGB": 10,
     "NewSizeGB": 15,
     "UsedPercent": 85.5
   }
```

The VHDX grew from 10 GB to 15 GB. Automatically. No manual intervention.

---

## Why This Architecture

| Decision | Why |
|----------|-----|
| **Per-VHDX resize** (not share-quota expansion) | Surgical — only grows profiles that truly need it, gives per-user visibility |
| **Hybrid Worker** (not cloud sandbox runbook) | `Resize-VHD` requires the Hyper-V PowerShell module, unavailable in Azure cloud runbooks |
| **`AccessNetworkAsComputerObject=1`** | FSLogix defaults to using the logged-in user's credentials for SMB. The user has no creds for the storage account — only SYSTEM does (via cmdkey). This setting makes FSLogix use computer-account creds → finds the cmdkey entry → mounts successfully |
| **Hard cap at runbook level** | Refuses to resize if total allocated would exceed 100 GB. Predictable budget, no surprises |
| **80% threshold, 5 GB increments** | Triggers before user hits "disk full," grows gradually rather than over-provisioning |
| **Logic App scheduler** (vs Cron on a VM) | Serverless, idempotent, easy retry, audit trail in Azure |
| **Windows Server 2022 Datacenter (not Azure Edition)** for DC | Azure Edition restricts the AD-DS role due to Hotpatching requirements |
| **VCS-driven HCP Terraform** | Code review gate via PR, audit trail in git, separation of plan vs apply approval |

---

## Benefits

### For end users
- No more "disk full" panic mid-work
- Profile grows quietly between sessions
- Zero perceived disruption

### For ops teams
- Zero profile-resize tickets
- ~10 hours/week saved per 100 users
- No after-hours pages for profile issues

### For finance
- Predictable storage growth in 5 GB increments
- Hard cap (100 GB) prevents runaway costs
- Only grows what truly needs it

### For security / compliance
- Every resize action logged as JSON (timestamp + before/after sizes + caller)
- MSI-based authentication (no stored credentials at runtime)
- Every code change tracked in git
- Hard cap enforced by code, not policy hope

### Quantitative ROI — 200-user environment

| Item | Without automation | With automation |
|------|-------------------|-----------------|
| Profile-full incidents | 8/month | 0 |
| Ops time per incident | 45 min | 0 |
| User productivity lost per incident | 2 hr | 0 |
| Annual cost | **~$11,280** | **~$60** |

**Net savings: ~$11,200/year** plus intangibles (user trust, ops morale, no off-hours pages).

---

## Production Considerations

This lab is functional but simplified for clarity. For production:

| Concern | Lab approach | Production approach |
|---------|--------------|---------------------|
| Storage authentication | Storage key via cmdkey | AD DS authentication on storage account |
| FSLogix config delivery | Direct registry write | Group Policy ADMX or Microsoft Intune |
| Network access | Public endpoint | Private Endpoint + VNet integration |
| Session host scale | Single VM | Pooled host pool with auto-scale (Azure Functions or scaling plan) |
| Profile backup | None | Azure Backup of file share + retention policy |
| Disaster recovery | None | GRS storage + paired-region failover |
| Monitoring | Runbook JSON output | Log Analytics workspace + alerts + Action Groups |
| Cap-reached notification | Log only | Teams/email alert via Action Group |
| Cap value | Hardcoded 100 GB | Per-environment variable + drift detection |

The **core pattern** (Logic App → Runbook → Hybrid Worker → action with cap enforcement) stays identical at scale.

---

## Cost

Lab session (5 hours, two B2s VMs running):

| Component | Cost |
|-----------|------|
| 2× B2s Windows VMs (5 hr) | ~₹70 |
| OS disks | ~₹6 |
| Public IP | ~₹2 |
| Azure Files (100 GB quota, <1 GB used) | ~₹0.10 |
| Logic App (free tier) | ₹0 |
| Automation Account (free tier — under 500 min/month) | ₹0 |
| **Total** | **~₹80 (~$0.95)** |

For production sizing, cost is dominated by session host VMs and depends on scaling profile.

---

## Teardown

```bash
# Stops billing immediately
az group delete --name AVD-Lab --yes --no-wait
```

Or via HCP Terraform UI: **Settings → Destruction and Deletion → Queue destroy plan → Confirm & Apply**.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| DC `install-ad` extension fails with `0x80070057` | Using Windows Server 2022 Azure Edition (doesn't support AD-DS role) | Use `2022-datacenter-g2` SKU instead |
| FSLogix login is fast (no delay), Desktop file doesn't persist | `AccessNetworkAsComputerObject` not set | Verify `HKLM:\SOFTWARE\FSLogix\Profiles\AccessNetworkAsComputerObject = 1` |
| Runbook errors with `Resize-VHD not recognized` | Hyper-V module not loaded | Ensure runbook does `Import-Module Hyper-V` at start; reboot session host once if module discovery fails |
| Runbook returns `Locked` for all profiles | Test user is currently signed in | Sign out before triggering runbook |
| VM extension stuck in `Updating` / `Deleting` | Azure ARM operation queue stuck | `az vm deallocate` then `az vm start`. Last resort: delete + recreate VM |
| `Multiple VMExtensions per handler not supported` | Two `CustomScriptExtension` resources on same Windows VM | Use `azurerm_virtual_machine_run_command` for the second one |
| `osdisk-sh01 already exists` after VM rebuild | Managed disk orphaned by `az vm delete` | `az disk delete -g AVD-Lab -n osdisk-sh01 --yes`, then retry apply |

---

## What This Project Demonstrates

**Infrastructure as Code**
- Multi-module Terraform composition
- HCP Terraform VCS-driven workflow with manual approval gate
- State backend management
- Module input/output design

**Azure architecture**
- Active Directory Domain Services integration
- Azure Virtual Desktop full deployment (Workspace + Host Pool + App Group + Session Host)
- FSLogix profile container configuration
- Storage account authentication patterns (cmdkey SYSTEM context)
- System-Assigned Managed Identity for runtime auth

**Automation engineering**
- Azure Automation Runbooks on Hybrid Workers
- Logic Apps as schedulers
- Webhook integration patterns
- Closed-loop self-healing systems

**PowerShell**
- Idempotent script design (`-Force`, existence checks)
- Hyper-V cmdlet usage (`Resize-VHD`, `Mount-DiskImage`)
- Robust error handling with try/catch and exit codes
- JSON structured output for log parsing

**Production engineering practices**
- Capacity guardrails (hard cap enforcement)
- Audit logging (every action recorded)
- Graceful failure modes (skip locked profiles, log and continue)
- Documentation for ops handoff

---

## Roadmap

Planned future work:

- [ ] Switch storage to AD DS authentication (production-grade)
- [ ] Add private endpoint for storage (network isolation)
- [ ] Integrate Log Analytics workspace for centralized runbook logging
- [ ] Action Group for cap-reached alerts (email/Teams)
- [ ] Multi-session-host support with worker selection logic
- [ ] Migrate to GitHub Actions as alternative to HCP Terraform
- [ ] Add scheduled drift detection workflow
- [ ] Per-OU FSLogix configuration via GPO (hybrid IaC + Group Policy pattern)

---

## Author

**Shabeer S** — Azure Cloud Enthusiast ☁️ | CloudOps  | Exploring Azure Administration | AVD Specialist | AZ-700 | AZ-140 | Terraform | Azure Networking | Modern Workspace | ITIL V4 |

- 13+ years enterprise IT (EUC → Cloud Architect transition)
- Certifications: AZ-140, AZ-700, ITIL v4 (AZ-305 + Terraform Associate in progress)
- GitHub: [@Shabeer1024](https://github.com/Shabeer1024)
- LinkedIn: [linkedin.com/in/shabeer-s-82690a156](https://linkedin.com/in/shabeer-s-82690a156)

---

## License

MIT — see [LICENSE](./LICENSE)

---

## Acknowledgments

- Microsoft FSLogix documentation team
- HashiCorp Terraform AzureRM provider maintainers
- The Azure Virtual Desktop product team
- Inspiration from the broader AVD ops community sharing automation patterns publicly

---

*If you found this useful, give it a star ⭐ and feel free to open an issue or PR with improvements.*