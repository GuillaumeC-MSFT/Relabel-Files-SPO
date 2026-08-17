# Microsoft Purview File Labeling Utility

`Invoke-PurviewFileLabeling.ps1` is a guided PowerShell utility for reviewing and applying Microsoft Purview sensitivity labels to files. It supports two distinct sources: a file-system path (local, UNC, or SharePoint Server content exposed through a mounted path), or a native SharePoint Online document library. Dry run is the default. Apply mode requires an explicit selection and a second confirmation before any file is changed.

## Choosing a source

The first question of a guided run is where the files are. The two paths use different technology, so their requirements differ:

| | File path / SharePoint Server | SharePoint Online library |
| --- | --- | --- |
| Host | Windows PowerShell 5.1 or PowerShell 7 | PowerShell 7.2 or later |
| Module | `PurviewInformationProtection` | `PnP.PowerShell` |
| Read label | `Get-FileStatus` | `Get-PnPFileSensitivityLabel` |
| Apply label | `Set-FileLabel -PreserveFileDetails` | `Add-PnPFileSensitivityLabel`, which calls Graph `assignSensitivityLabel` |
| Sign-in | `Set-Authentication` | Delegated sign-in to survey; certificate-based confidential client to apply |
| Permissions | File-system access plus Rights Management rights | Delegated SharePoint `AllSites.Read` and Graph `Files.Read.All` to survey; application `Files.ReadWrite.All` to apply |

These choices deliberately do not share a write implementation. The file-path choice writes the label into the file with the Purview Information Protection client. It covers local and UNC content, a OneDrive-synced library, and SharePoint Server content only when that content is exposed to the machine as a file-system path. It does not call Microsoft Graph, create an Azure billing resource, or incur a metered API charge.

The native SharePoint Online choice does not download files, change their labels, and upload them again. It calls [driveItem: assignSensitivityLabel](https://learn.microsoft.com/en-us/graph/api/driveitem-assignsensitivitylabel) through `Add-PnPFileSensitivityLabel`. Microsoft documents this as an advanced, protected, metered API. A successful call returns `202 Accepted`; the operation continues asynchronously, so the read-back verification and the `Not confirmed` outcome distinguish acceptance from completion.

A SharePoint Online library selected by URL is always handled by this native, metered path. The Purview client is used only for files available through a Windows file-system path.

SPO Apply is offered only when this run is connected with the configured certificate-based confidential client. That application needs Graph application permission `Files.ReadWrite.All`, administrator consent, protected-API approval from Microsoft, and an Azure billing association. A normal interactive/public-client connection can still enumerate files, read labels, and run a dry run, but it cannot call the metered API.

### Cost and client-type limits on the SharePoint Online apply path

The constraints below come from Microsoft's [metered API overview](https://learn.microsoft.com/en-us/graph/metered-api-overview), [metered API list](https://learn.microsoft.com/en-us/graph/metered-api-list), and [setup procedure](https://learn.microsoft.com/en-us/graph/metered-api-setup):

- `assignSensitivityLabel` is **billed by API usage**. One Apply attempt is one metered call; consult Microsoft's metered API list for the current rate. Reading existing labels, enumerating files, and dry runs do not call it.
- The calling application **must be a confidential client**. Microsoft's wording is "web application, web API, or daemon/service", and "public client applications (desktop and mobile applications) aren't supported". A confidential client is one that can keep a certificate or client secret private. A workstation PowerShell session signing in as *you* cannot, which is why the default sign-in is refused; an application signing in with its own certificate can, which is why the setup below works.
- The application must be associated with an active Azure subscription by a `Microsoft.GraphServices/accounts` resource. The subscription must be in the application's tenant, and the operator needs Contributor on the subscription and owner rights on the application registration.
- Metered APIs are available only in the Microsoft global environment. Public clients and Azure managed identities are not supported.

Reading labels, enumerating files, and dry runs against SharePoint cost nothing in either configuration. **Until you complete the setup below, no run this utility performs can incur a per-call charge**, because Apply is not offered for the SharePoint Online source at all. Once a usable confidential client is configured, Apply becomes selectable and each eligible file causes one metered API call. Dry run remains the default and a second confirmation is still required.

### One requirement this utility cannot satisfy for you

Microsoft classes [assignSensitivityLabel](https://learn.microsoft.com/en-us/graph/api/driveitem-assignsensitivitylabel) as a **protected API**: *"Protected APIs require you to have more validations, beyond permission and consent, before you can use them."* The [metered API list](https://learn.microsoft.com/en-us/graph/metered-api-list) adds that access to protected APIs must be **requested from Microsoft**. That approval is separate from the confidential client, the administrator consent, and the Azure billing link, and none of the three substitutes for it. The setup says so before you start, and the failure path repeats it, so a refusal after everything below is complete is not a sign that the setup went wrong.

There is no unmetered alternative **through Graph**. `assignSensitivityLabel` is the only Microsoft Graph API that writes a sensitivity label to a file in SharePoint or OneDrive, and it is available only in the global cloud.

There is, however, a way round it that costs nothing and needs no approval. The Purview Information Protection client writes labels to files on disk, and the OneDrive client syncs a SharePoint library to disk, so labeling a **synced copy** achieves the same result: OneDrive uploads each change straight back to SharePoint. When you choose the local source, the utility reads the OneDrive client's own list of mounted libraries and offers each one as a folder to scan, so there is no path to type and no guessing which folder maps to which library. When the SharePoint source refuses to apply, it offers to switch you to that route directly. A Purview auto-labeling policy is the other no-cost option, and runs service-side with no client at all.

### Nothing it creates is left behind

A setup that does not finish leaves nothing to find later. The certificate generated during registration is recorded, and on exit every one this run created is deleted **except** the credential the saved client still needs, so an abandoned or failed attempt cannot accumulate keys in your store. Certificates are matched by both name and creation time, so one that merely shares a name prefix is never touched. PnP's exported copies are written to a temporary folder and deleted immediately. If the Azure billing link fails, the setup offers to undo itself completely: it deletes the application, removes its certificate, and forgets the pending link, because a confidential client without billing cannot write anything and is only clutter. The default is to undo.

### Enabling the SharePoint Online apply path

Main menu option 3, *Enable SharePoint Online metered label writing*, performs the three steps Microsoft requires:

1. **Registers a confidential client.** It creates an Entra application whose credential is a certificate generated into your personal certificate store (`Cert:\CurrentUser\My`), where Windows protects the private key. PnP also writes exported copies of that certificate; those are directed to a temporary folder and **deleted immediately**, rather than being left in Downloads, because the store already holds the only copy that is needed. If another machine ever needs it, export it from the store deliberately. It requests Graph `Files.ReadWrite.All` and SharePoint `Sites.Read.All`, both application permissions, so **a Global Administrator must consent**. Only the client ID, tenant ID, and certificate thumbprint are remembered, in `PURVIEW_FILE_LABELING_CC_*` environment variables; none of the three is secret, a thumbprint is a public fingerprint, and none of them can authenticate without the private key. The saved tenant ID is checked against the site's tenant on every run, so the application is only ever used in the tenant it belongs to.
2. **Grants administrator consent**, from inside the utility. Registering creates the *application*; app-only sign-in additionally needs a **service principal** in the tenant, and only consent creates that. Until it exists, sign-in fails with `AADSTS700016: Application ... was not found in the directory`, which reads like the application is missing even though it exists. Rather than sending you to a portal, the utility offers to do it: it signs in to Microsoft Graph as an administrator, creates the service principal, reads the permissions the registration actually asks for, and assigns each one. Permissions already assigned are treated as success, so it is safe to repeat. If you decline, or it fails, it describes the portal path instead. It deliberately does **not** link to the `/adminconsent` endpoint, which requires a registered `redirect_uri` that a certificate-only application does not have and would land on an error page.
3. **Links Azure billing.** It creates the `Microsoft.GraphServices/accounts` resource that associates the application with the Azure subscription to be charged, per [Microsoft's metered API setup](https://learn.microsoft.com/en-us/graph/metered-api-setup). You are not asked to find a GUID: it offers to install `Az.Resources` if no Azure tooling is present, signs it in if needed, **lists your subscriptions and resource groups as numbered menus**, can **create a resource group** for you if none suits, and flags any subscription in a different tenant as unusable, since the subscription must live in the same tenant as the application. It registers the `Microsoft.GraphServices` resource provider and waits for that registration to report itself complete. If the creation call fails on Azure's side it does not give up, and it does not hand you commands to type. **The API versions are not hard-coded**: the provider is asked which ones it supports, newest stable first, so a version Microsoft adds or retires needs no change here; the documented pair is used only if the provider cannot be queried. It then tries the Az cmdlet, a direct ARM request that bypasses the Az resource pipeline, and an ARM **template deployment** — the three routes Microsoft documents — before falling back to older API versions. If all three routes return the same fault it stops immediately, because that is conclusive evidence the provider itself is at fault rather than the request. The exact link is then **remembered and finished automatically**: you can let it keep retrying there and then, and in any case the next run of the utility completes it on its own, without asking anything again. The request it sends matches [Microsoft's documented resource format](https://learn.microsoft.com/en-us/azure/templates/microsoft.graphservices/accounts) exactly, so a persistent failure is reported as Azure's, with the correlation IDs to quote in a support case. The step is idempotent, checking whether the resource already exists before creating and again after an error, since a failed call can still have created it. You need **Contributor** on the subscription.

The preferred billing route is Azure CLI. After the utility collects and validates the resource group, billing-resource name, subscription ID, and application client ID, it runs Microsoft's documented command with those values:

An exception applies when Microsoft.GraphServices returns the `OpenTelemetry` `TryCreateLogger` type-load failure, including from ARM template validation. That is a provider implementation error, not a subscription, tenant, resource-group, or authorization problem, and retrying from another PowerShell process or Cloud Shell cannot repair it. The utility does not issue a mutating create after that failed validation. It retains the pending link and full error in its log, but suppresses automatic retries of that exact signature until the provider recovers or Azure support resolves it.

```powershell
az graph-services account create --resource-group <resource-group> `
    --resource-name <billing-resource-name> --subscription <subscription-id> `
    --location global --app-id <application-client-id>
```

Before that call, the utility installs or upgrades the `graphservices` extension, selects the subscription, and registers the `Microsoft.GraphServices` provider with `--wait`. Each step must succeed before resource creation is attempted. If Azure CLI is unavailable, the Az/ARM routes remain as fallbacks.

### Billing preflight and verification

Immediately before it runs `az graph-services account create`, the utility performs a **non-mutating preflight**. It stops before creation, and does not save a retry, when it finds any of these user-fixable conditions:

- The application service principal is definitely missing. The utility offers to grant administrator consent first and verifies that condition again afterwards.
- The active Azure cloud is not the global `AzureCloud` environment, the subscription is not `Enabled`, or the subscription tenant differs from the Entra application tenant.
- The selected resource group cannot be read, or `Microsoft.GraphServices` does not finish registering.
- Azure Resource Manager rejects `az deployment group validate` for the exact `Microsoft.GraphServices/accounts` template that would be created. This is a validation-only call: it creates neither a billing resource nor a deployment. The known `OpenTelemetry` provider implementation failure is classified separately and retained without automatic retries.

The template validation exercises the current operator's Azure authorization, including the Contributor-level deployment access Microsoft requires, and lets the Graph Services provider validate the requested application association. It cannot prove that Microsoft's create backend is healthy or that Microsoft has approved access to the protected `assignSensitivityLabel` API. After creation, the utility follows Microsoft's documented verification sequence: `az resource list` confirms the resource state and `az resource show` confirms that `properties.appId` is the intended application ID.

A confidential client that is configured but not yet consented to does **not** break ordinary use. Before preferring it, the utility checks whether it is actually usable in that tenant; if it is not, it offers to grant consent there and then, and otherwise falls back to the read-only delegated sign-in so the run continues as a survey. Apply is offered only when the connection the run actually holds is app-only, not merely when an application is configured, so it can never be offered for a sign-in that could not write anyway.

### Sign-ins are reused rather than repeated

Enabling the apply path can involve several different services, so the utility avoids asking for the same identity twice:

- An open **SharePoint** connection is reused when the site and application match, proven with a live call rather than assumed.
- Every **Microsoft Graph** and **Azure** operation runs in a **separate PowerShell process**. This is not tidiness, it is required. `PnP.PowerShell` ships the `Microsoft.Extensions.*` assemblies at version 8.0, while `Az.Resources` ships the same assemblies at 2.2.0 and `Microsoft.Graph.Authentication` brings its own again. .NET cannot unload an assembly, so whichever binds first wins for the life of the process: run the Azure billing step and a later SharePoint sign-in fails with *"Method 'get_Services' in type Microsoft.Extensions.Logging.LoggingBuilder ... does not have an implementation"*, which looks like an authentication problem and is not. Keeping Az and Graph out of the process that hosts PnP removes that class of failure entirely. Both children reuse their own saved sign-in, so isolation costs no extra prompts.
- Registering an application announces the window it is about to open, and honours `-DeviceLogin` so it can never hide behind another window.
- The **Azure** sign-in is reused when a context already exists, and is pinned to the application's tenant so it cannot silently pick an account from a different directory.
- Discovered **sensitivity labels** are cached for the session, so a second run does not re-query them.
- [New-LabelTestSite.ps1](New-LabelTestSite.ps1) hands its site, library, and (with `-KeepApp`) its **application** over, so the labeling utility can reuse that sign-in instead of registering another. It also passes the source across, so you are not asked where the files are.

### Stale application IDs are removed, not proposed

A remembered application that the tenant no longer has is worse than none, because it is offered as the default. Before proposing one, the utility asks the tenant's device-authorization endpoint whether it is usable, which needs no sign-in and no consent. If the answer is no, it confirms against the directory itself whenever a Graph session is already open, and **clears the remembered value** when absence is confirmed. The one exception is an application registered moments earlier in the same run, which is kept because Entra replication has not caught up yet. Values owned by other tools are reported but never modified.

### How credentials are handled

Nothing secret is ever written to disk or to an environment variable:

- The **certificate private key** lives only in `Cert:\CurrentUser\My`, protected by Windows. Exported copies are deleted as soon as registration finishes.
- **No password, client secret, or token** is collected, stored, or logged. The utility never prompts for one.
- The values it remembers are a client ID, a tenant ID, a certificate thumbprint, a site URL, and a library name. None identifies a credential, and none can authenticate on its own.
- Sign-in always happens in Microsoft's own browser or device-code flow, so no credential passes through the script.
- Run logs and the CSV report record site URLs, tenant IDs, and paths, which is why `.gitignore` keeps them out of the repository.

Afterwards the SharePoint source signs in as the application rather than as you, and the run-mode prompt offers Apply. Three limits are worth knowing before you start:

- Metered APIs are **unavailable in national clouds**, including GCC.
- A token issued *before* the billing link exists is still refused, so restart the utility after linking.
- Some **IRM-protected labels cannot be applied app-only** and return `Not Supported`, because SharePoint cannot validate user rights without a user.

Option 3 also lets you re-link billing for an existing application, grant its consent, replace it, or forget it and return to survey-only mode. Replacing never deletes the old application until the replacement has been registered and saved, so a failed registration cannot leave you pointing at an application that no longer exists. Forgetting or replacing one offers to **remove it from Entra ID** as well, since an orphaned application holding `Files.ReadWrite.All` is worth cleaning up: it strips every requested permission and redirect URI, disables sign-in on the service principal, then deletes the application. If your sign-in lacks Graph `Application.ReadWrite.All` the delete is refused, but the strip and disable usually still succeed, so what is left behind can no longer reach data; the exact `Connect-MgGraph` commands to finish the job by hand are printed either way.

You do not have to find option 3 first: when a SharePoint run is forced to dry run because no confidential client exists, it explains why and **offers to run the setup there and then**. That returns you to the main menu afterwards, because registering the application replaces the sign-in the run was using.

If you would rather not pay per call at all:

- A **Microsoft Purview auto-labeling policy** for SharePoint and OneDrive, which labels content at rest as part of the compliance licensing rather than per API call.
- **Syncing the library with OneDrive** and running this utility's local source against the synced folder. That path uses the Purview Information Protection client and `Set-FileLabel`, never touches Graph, and syncs the labeled files back.

The SharePoint source needs PowerShell 7.2 or later, and the local source is most reliable in Windows PowerShell 5.1, so the utility does not force a host on you. Where the files are is asked **before** it signs in to anything, so if you pick SharePoint Online in Windows PowerShell it can offer to restart in the newest installed PowerShell 7 without discarding a Microsoft 365 sign-in. It closes its own connections first, hands over in the same window, and ends when that run ends. The restarted run **carries your source choice with it**, so the question is never asked twice. Answer no to stay where you are and use the local source. `-NoRelaunch` suppresses the offer, and the restarted run always carries it so the handover happens at most once.

Tenant label discovery, the priority rules, dry run, logging, and the CSV report are identical for both sources.

### The Entra application for the SharePoint Online source

You do not have to create one yourself. When you choose the SharePoint source, the utility offers to register an application named `PnP PowerShell - Purview File Labeling` with exactly two delegated permissions: SharePoint `AllSites.Read` to enumerate files, and Microsoft Graph `Files.Read.All` to read the label already on each file. Neither one can write. The tenant is taken from SharePoint's own authentication challenge, so the application is always single-tenant in the site's tenant, and no application ID is embedded in the script.

Both permissions are user-consentable, so an administrator is only needed if tenant policy restricts user consent. Accept the consent prompt the browser shows on first sign-in. To confirm afterwards which scopes the session actually obtained, run `Get-PnPAccessToken -Scopes` while connected.

The generated non-secret client ID is remembered per tenant, in `PURVIEW_FILE_LABELING_CLIENT_ID_<tenantid>`, so later runs against the same tenant simply offer it and runs against a different tenant never do. Registration is done through **Microsoft Graph directly**, which reports progress in the console; PnP's own registration command opens a sign-in window this utility cannot see and can appear to hang, so it is kept only as a fallback. Neither permission GUID is hard-coded: each is looked up from the resource that publishes it, so a renamed or reissued permission cannot silently produce a broken registration. The tenant itself is read from SharePoint's own authentication challenge before any sign-in, and it is passed to the sign-in explicitly, so an account cached from a previous tenant is never silently reused. You can also pick an existing application instead. A newly registered application is not visible immediately, so sign-in is retried while Entra replicates it.

This read-only application is what the SharePoint source uses by default. If you complete the confidential client setup from main menu option 3, that certificate-based application takes precedence instead **for the tenant it was registered in**, the sign-in becomes app-only, and this prompt no longer appears. Against any other tenant the utility says so and falls back to the delegated application described here. Forgetting the confidential client also returns you to it.

The application that [New-LabelTestSite.ps1](New-LabelTestSite.ps1) creates is **not** reusable here: it holds only SharePoint permissions, and it is deleted at the end of every provisioning run. If that delete is refused, its consent, permissions, redirect URIs, and sign-in are stripped first, so what remains is inert. A name collision is not fatal in either script: the helper registers under a timestamped name, and the labeling utility offers to reuse the existing application, register under a new name, or take an application ID you paste in.

Unlike the provisioning helper, this application is kept, because it is what you sign in with. Remove it in the Entra admin center when you no longer need the utility.

## Prerequisites

- Windows with Windows PowerShell 5.1 (`powershell.exe`) and .NET Framework 4.7.2 or later. PowerShell 7 (`pwsh`) also works; because the Purview client ships .NET Framework assemblies, the utility falls back to `Import-Module -UseWindowsPowerShell` when a native import fails. Use Windows PowerShell 5.1 if the module misbehaves. The SharePoint Online source needs PowerShell 7.2 or later.
- The Microsoft Purview Information Protection client and `PurviewInformationProtection` PowerShell module installed, for the local and UNC source. **This is the only prerequisite you must install yourself**, because it ships as a client installer rather than a gallery module.
- `PnP.PowerShell`, for the SharePoint Online source.
- The `ExchangeOnlineManagement` module, used to connect to Security & Compliance PowerShell and retrieve labels with `Get-Label`.
- Only to apply labels in SharePoint: the **Azure CLI** or the **`Az.Resources`** module, used once to create the billing link, and `Microsoft.Graph.Authentication` to grant consent. None of them is needed to survey. That step also needs an Azure subscription in the same tenant, Contributor rights on it, and an administrator to consent to the application permissions.
- A Microsoft Entra account with a published sensitivity label policy that includes the labels being applied.
- Purview permissions that allow the admin to run `Get-Label` in Security & Compliance PowerShell.
- Read and write access to the target local folder, UNC share, or SharePoint library and its files.
- Rights Management permissions needed to inspect or replace protection. For protected content outside the operator's normal access, configure the account as a Purview Information Protection super user according to Microsoft guidance.
- An authenticated module session for the local source. Run `Import-Module PurviewInformationProtection` and `Set-Authentication` before an apply run. The utility verifies authentication with `Get-FileStatus` and offers to re-check; it does not collect credentials or secrets.

The three gallery modules do not have to be installed in advance. When one is missing at the point it is needed, the utility says so and offers to install it for your user account, which requires no administrator. Declining just prints the `Install-Module` command instead.

One upgrade needs a decision from you. PnP.PowerShell moved from a Microsoft signing certificate to the .NET Foundation, and PowerShellGet refuses to install across a publisher change: *"a Microsoft-signed module ... conflicts with the new module ... use -SkipPublisherCheck"*. The utility recognises that error, explains that the check exists to catch a package changing hands unexpectedly, and asks before retrying with `-SkipPublisherCheck`. The default is to stop.

Because a loaded assembly cannot be replaced in a running session, the utility **restarts itself** after updating PnP.PowerShell, in the same window, carrying your source choice with it. It refuses to do that twice in a row, so a repeatedly failing update cannot loop.

### More than one PnP.PowerShell version installed

PnP.PowerShell loads .NET assemblies, and .NET cannot unload them. Whichever version a PowerShell session touches **first** therefore wins for the life of that session, and `Import-Module -RequiredVersion` will not replace it. If an older copy is still installed, it can silently disable newer features — registering a confidential client, for example — while every version check appears to pass.

This is easy to miss, because `Get-Module -ListAvailable` reports only the **newest** version per module; older copies are invisible unless you add `-All`. Both scripts now enumerate with `-All`, warn when more than one version is installed, and `Invoke-PurviewFileLabeling.ps1` offers to uninstall the older ones. That offer only appears in a session that has not yet loaded PnP, since a loaded module cannot be removed.

`Uninstall-Module` only sees modules in the current host's module paths, so a copy installed for the other PowerShell edition — typically under `Documents\WindowsPowerShell\Modules` while you are running PowerShell 7 — cannot be uninstalled that way. When that happens the utility offers to delete the version folder directly instead, and refuses any path that is not a `PnP.PowerShell` version folder. To clean up by hand:

```powershell
Get-Module -ListAvailable -Name PnP.PowerShell -All | Select-Object Version, ModuleBase
Uninstall-Module PnP.PowerShell -RequiredVersion <old-version> -Force
```

Then open a **new** PowerShell window before running either script again.

If the folder cannot be deleted because a file inside it is locked or access is denied, the utility offers to **rename** it instead. That works where deleting does not, because renaming a directory never opens the files inside it, and PowerShell only discovers a module in a folder whose name parses as a version number. A folder renamed to `1.12.0.disabled-<timestamp>` therefore stops shadowing the newer version immediately, with no reboot and no sign-out, and its files stay on disk for you to delete later. The version checks ignore such folders, so the warning does not come back.

Install and authentication guidance:

1. Install the Microsoft Purview Information Protection client from Microsoft Learn.
2. Install the label-discovery module with `Install-Module ExchangeOnlineManagement -Scope CurrentUser`.
3. Open Windows PowerShell 5.1 (or PowerShell 7) under the identity that will access the files.
4. Run `Import-Module PurviewInformationProtection`.
5. Run `Set-Authentication` and complete the Microsoft Entra sign-in.

The utility never asks for a password, application secret, label GUID, or tenant ID. Microsoft 365 authentication is completed in the browser.

## Label Discovery

The utility retrieves sensitivity labels directly from the customer's tenant. If the current PowerShell session does not already have `Get-Label`, it offers to:

1. Import `ExchangeOnlineManagement`.
2. Open an interactive browser sign-in with `Connect-IPPSSession`.
3. Run `Get-Label` and list enabled labels that can apply to files.
4. Show the friendly label name, tenant priority, and GUID in a numbered menu.
5. Use the selected GUID automatically with `Set-FileLabel`.

Parent labels or label groups that contain child labels are excluded because they are not valid file-labeling choices. Sublabels are displayed as `Parent \ Child` and the child GUID is used.

Higher tenant priority numbers mean higher sensitivity. The script skips a file when its existing label has equal or higher tenant priority. It also skips an existing label that was not returned by discovery because its priority cannot be established safely.

## Optional validation-only helper

This repo also includes [New-LabelTestSite.ps1](New-LabelTestSite.ps1). It is a small SharePoint Online helper that creates a temporary test site, a document library, nested folders, and synthetic Office files so you can validate how Microsoft Purview sensitivity labels behave in a realistic structure.

It is intentionally separate from the labeling utility and is not required for normal use. If you already have a local folder or a managed SharePoint library to test, you can skip this script entirely. It is only meant to create disposable validation data and should not be treated as a production or operational labeling workflow.

### Handing straight over to the labeling utility

When provisioning finishes, the helper remembers the site URL and library name it just created in `PURVIEW_FILE_LABELING_SITE_URL` and `PURVIEW_FILE_LABELING_LIBRARY`, so `Invoke-PurviewFileLabeling.ps1` proposes both as defaults: press Enter at the site prompt, and the new library is already the highlighted choice in the library menu.

If `Invoke-PurviewFileLabeling.ps1` sits in the same folder, it also offers to start it for you. That launch is deliberately deferred until **after** the helper's own cleanup has run, so the disposable application is removed before the next sign-in begins. Answer no, or pass `-AcceptDefaults` for an unattended run, and nothing is started.

### Working with more than one tenant

Both scripts are tenant-agnostic and remember nothing that could send a later run to the wrong tenant:

- The tenant is resolved from the SharePoint address itself, before any sign-in, and passed explicitly to the sign-in. Without that, MSAL reuses whichever account was cached last, which produces a confusing "user account does not exist in this tenant" error when you switch.
- Application IDs are remembered under a per-tenant name, so an application registered in one tenant is never proposed for another. A value found in a tenant-agnostic variable such as `AZURE_CLIENT_ID` is still offered, but labeled as possibly belonging to another tenant, and registering a fresh one becomes the default.
- The confidential client records the tenant it was registered in and is skipped, with an explanation, against any other tenant.
- `New-LabelTestSite.ps1` proposes its remembered root URL as an editable default rather than using it silently, so switching tenants is just typing a different address. `-TenantRootUrl` still overrides it outright.

Nothing tenant-specific is stored in the repository itself; the remembered values live in your own user environment variables. To forget a tenant entirely, clear them:

```powershell
'LABEL_TEST_SITE_TENANT_URL', 'PURVIEW_FILE_LABELING_CLIENT_ID' |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_, $null, 'User') }
Get-ChildItem Env: | Where-Object Name -like 'PURVIEW_FILE_LABELING_C*' |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'User') }
```

### Helper behavior and authentication

The helper focuses on validation, not production labeling. It creates a disposable SharePoint site and library so that the label experience can be tested without affecting live content. It is designed to run with as little input as possible: the tenant, admin URL, cloud, and application are discovered automatically, and the validated root URL is remembered in `LABEL_TEST_SITE_TENANT_URL` so later runs need no typed input.

Every prompt proposes a default in brackets that Enter accepts, and every default can also be supplied up front: `-LogFolder`, `-SiteName`, and `-LibraryName`. Pass `-AcceptDefaults` to take every proposed value without being asked.

Every action is written to a timestamped `New-LabelTestSite-*.log` in the log folder, which defaults to the script directory. The log records the host and account, each resolved value, each prompt and the answer given, every site, folder, and file created, every warning and error, and the outcome of the application cleanup. Lines recorded before the log file exists are buffered and flushed into it, so the log is complete even when the folder is chosen interactively. The log path is printed again on exit.

At most four questions can appear, and all of them can be answered in advance:

- The log folder, skipped with `-LogFolder` or `-AcceptDefaults`.
- The SharePoint root URL, skipped when `-TenantRootUrl` is passed, a PnP connection is already open, or `LABEL_TEST_SITE_TENANT_URL` is set. The value can be a full SharePoint URL, an admin or OneDrive host, a `<tenant>.onmicrosoft.com` domain, or just the tenant alias; the scheme is optional.
- A single confirmation before registering an Entra application, skipped with `-RegisterApp` or `-ClientId`.
- The site name and document library name, skipped with `-SiteName` and `-LibraryName`, or with `-AcceptDefaults`.

When the host cannot prompt, the helper takes every default and stops immediately if a value it cannot infer is missing, naming the parameter to supply instead of waiting for input. Transient failures such as timeouts, HTTP 429 throttling, and 5xx responses are retried with exponential backoff and honor the server's `Retry-After` header; if the generated site URL is already in use, the next available name is used automatically.

A tenant's SharePoint address does not always match its `onmicrosoft.com` prefix, and some tenants have no SharePoint provisioned. When the address is derived rather than typed, the helper confirms the host exists in DNS before contacting it, reports whether the Microsoft 365 tenant itself exists, and asks again instead of retrying a name that cannot exist. The check is skipped on networks that resolve names only through a proxy.

PnP PowerShell requires an Entra application for interactive authentication. The helper does not contain or fall back to a shared application ID. Tenant and application IDs are always discovered, supplied, or generated at runtime; applications created by the helper are single-tenant registrations in the resolved tenant.

Before opening a SharePoint sign-in, the helper automatically:

1. Validates and normalizes the SharePoint Online root URL and derives the matching admin URL.
2. Reads the anonymous SharePoint Bearer challenge to discover the tenant realm and login authority.
3. Resolves OpenID metadata, selects the matching PnP cloud environment, and rejects a tenant hint or authority that points outside the SharePoint tenant's cloud.
4. Finds a client ID from `-ClientId`, a tenant-specific saved environment variable, `ENTRAID_APP_ID`, `ENTRAID_CLIENT_ID`, or `AZURE_CLIENT_ID`.
5. Calls the resolved tenant's device-authorization endpoint to verify that the app is available to that tenant as a public client and can request SharePoint access. This catches `AADSTS700016` before a browser window opens; supplied multi-tenant apps can also pass this availability check.
6. After sign-in, verifies the connected admin host, client ID when PnP exposes it, tenant ID when available, and access to the SharePoint tenant-admin API.
7. Disconnects the current PnP session before replacing it and again on every exit path. It does not clear persisted login caches or disconnect unrelated Graph, Exchange, or Purview sessions.

When no usable application is found, the helper offers to run `Register-PnPEntraIDAppForInteractiveLogin` (or its legacy PnP name) and requests only delegated SharePoint `AllSites.FullControl`. Automatic registration requires PowerShell 7.2 or later, a compatible PnP.PowerShell version, and an account allowed to create app registrations; tenant policy may require an administrator to grant consent. On Windows PowerShell 5.1, pass an existing compatible app with `-ClientId`. The generated non-secret client ID is saved in a tenant-specific user environment variable for later runs. Use `-RegisterApp` to choose automatic registration without the menu.

### Removing the application the helper creates

An application the helper registered is removed again on every exit path, including failed runs. An application supplied with `-ClientId`, or found in an environment variable, is never touched. Pass `-KeepApp` to keep a newly created one; the helper then logs its name and client ID so it is not forgotten.

Deleting an app registration needs Microsoft Graph `Application.ReadWrite.All`, which the helper deliberately does not request for the app it creates. Cleanup therefore tries, in order:

1. `Remove-PnPEntraIDApp` on the existing PnP session, which succeeds only when that session already has Graph rights.
2. A **separate PowerShell process** that signs in with `Connect-MgGraph -Scopes Application.ReadWrite.All` and disconnects immediately afterwards. A child process is required because PnP.PowerShell and Microsoft.Graph load incompatible versions of `Microsoft.Identity.Client`, so an in-process Graph sign-in fails once PnP has been used. This step needs `Microsoft.Graph.Authentication`, which the helper does not install. On this path the application's access is stripped **before** the delete is attempted: every delegated consent grant is revoked, the service principal's sign-in is disabled, and all requested API permissions and redirect URIs are removed.
3. If neither works, the helper logs exactly what was left behind: the display name, client ID, tenant ID, whether the access strip succeeded, and the commands to finish the removal by hand.

When the application is deleted, or when it survives but its access was stripped, the saved client ID is cleared so no later run reuses it. When nothing could be changed, the saved client ID is deliberately kept, so a later run reuses that one application instead of leaving another orphan behind.

The helper selects a PnP.PowerShell version the host can load: `1.12.0` on Windows PowerShell 5.1, `2.12.0` on PowerShell 7.2 and 7.3, and the current release on PowerShell 7.4 or later. It recognizes the commercial, US Government (`sharepoint.us`), German, and 21Vianet (`sharepoint.cn`) SharePoint hosts, and stops when the SharePoint host and the resolved sign-in authority are not in the same cloud.

Only PowerShell 7.2 and later can register an Entra application, because the PnP release for Windows PowerShell has no registration command. When started from Windows PowerShell, the helper finds the newest installed PowerShell 7, restarts itself there with the same parameters, and returns that run's exit code. Pass `-NoRelaunch` to stay in the current host. If PowerShell 7 is not installed, the run continues and explains that `-ClientId` is required.

Run the full preflight without creating a SharePoint site:

```powershell
.\New-LabelTestSite.ps1 -TenantRootUrl 'https://contoso.sharepoint.com' -PreflightOnly
```

Allow the helper to register the tenant app if needed, then run the same checks:

```powershell
.\New-LabelTestSite.ps1 -TenantRootUrl 'https://contoso.sharepoint.com' -RegisterApp -PreflightOnly
```

After preflight succeeds, omit `-PreflightOnly`. A site name is generated automatically unless `-SiteName` is supplied. Device-code authentication remains available with `-AuthMode DeviceCode`; browser authentication is the default.

A fully unattended run supplies the tenant and the application decision up front:

```powershell
.\New-LabelTestSite.ps1 -TenantRootUrl 'https://contoso.sharepoint.com' -RegisterApp -AcceptDefaults
```

Keep the generated application, write the log elsewhere, and name the site and library explicitly:

```powershell
.\New-LabelTestSite.ps1 -TenantRootUrl 'https://contoso.sharepoint.com' -RegisterApp -KeepApp `
    -SiteName 'Label Test March' -LibraryName 'Label Test Library' -LogFolder 'C:\Logs'
```

The helper's application has only delegated SharePoint access, so it cannot be reused for the SharePoint source of `Invoke-PurviewFileLabeling.ps1`, and it is deleted when the provisioning run ends. `Invoke-PurviewFileLabeling.ps1` registers its own read-only application, with the Microsoft Graph permission needed to read each file's current label, the first time you use the SharePoint source.

## Run

From Windows PowerShell 5.1 or PowerShell 7:

```powershell
Set-Location "C:\path\to\the\utility"
.\Invoke-PurviewFileLabeling.ps1
```

Use Windows PowerShell 5.1 for local and UNC folders, because the Purview Information Protection client is most reliable there. For SharePoint Online either start it with `pwsh`, or start it anywhere and accept the restart it offers when you choose that source.

### If the browser insists on a passkey

The embedded browser sometimes offers only a passkey, and on a device enrolled with an Android Work Profile it can fail outright with *"We couldn't sign you in... please use the camera app in that profile"*. That is the sign-in page choosing a credential for you, not a fault in the utility. Two ways past it:

```powershell
.\Invoke-PurviewFileLabeling.ps1 -DeviceLogin
```

`-DeviceLogin` prints a short code and a URL to open in any normal browser, where **Microsoft Authenticator** can be chosen like any other method. The same choice is offered automatically after a failed sign-in, together with an option to retry in the browser forcing a fresh account picker, which discards the cached credential choice. A failed sign-in keeps the site you already entered, so only the sign-in is retried, and choosing a different application does not make you retype the URL.

You are not asked to sign in repeatedly either. Before authenticating, the utility checks whether the connection it already holds serves the same site with the same application, and proves it with a live call rather than trusting a stale object. If it does, that sign-in is reused and no browser window opens at all, which matters when a window can appear behind the console and be missed. Forcing a fresh sign-in always bypasses the reuse.

`New-LabelTestSite.ps1` behaves the same way: a failed sign-in no longer ends the run. It explains the failure — naming the tenant when the application belongs to a different one — and offers to retry with device code, forget the remembered application and register a fresh one for this tenant, enter a different client ID, or stop. `-AuthMode DeviceCode` selects device code from the start.

### Run artifacts contain tenant information

The log and CSV report record site URLs, tenant IDs, folder paths, and the signed-in account, and both scripts default to writing them **next to the script**, which is this repository. A `.gitignore` excludes the timestamped `Invoke-PurviewFileLabeling-*.log`, `Invoke-PurviewFileLabeling-*.csv`, and `New-LabelTestSite-*.log` names so they can never be committed by accident. Point the log prompt somewhere outside the repository if you would rather keep them further away.

No positional parameters are required. **Where the files are is asked once, before the main menu**, so an unreachable source costs no sign-in and the question is not repeated for every run. The menu shows the current choice and option 4 changes it. The guided session then asks, in this order:

- Microsoft 365 interactive sign-in when tenant label discovery is needed.
- The target folder, or for SharePoint Online the site URL, the sign-in application, and then the document library picked from a numbered list of the libraries that site actually has, plus an optional subfolder.
- Whether to include subfolders.
- Which files to scan: all Office documents and PDF including legacy and macro-enabled formats, the current formats only (`.docx .xlsx .pptx .pdf`), or a list you type.
- Target sensitivity label.
- Dry run or apply mode.
- Log and CSV report folder, defaulting to the script directory.

Every prompt that has a sensible default proposes it in brackets, so pressing Enter accepts it. You never have to know a library's internal URL: the utility signs in first and lists the libraries for you. A site URL that signs in successfully is remembered and proposed the next time any site is asked for, including by the confidential client setup, and typing a different one replaces it.

This is an interactive utility, so it is meant to be run in a console. If its input is redirected and runs out, it stops with a clear message instead of driving every menu at its default.

Start with a representative dry run and inspect the CSV report. Back up important data and test label behavior, encryption, access, and application compatibility before a production apply run.

## Main menu

Everything starts from one menu, and every option returns to it:

| Option | What it does |
| --- | --- |
| 1. Guided run | Applies one label to one folder or library, with the prompts listed above. |
| 2. Batch run from a CSV | Applies a different label per folder in a single pass. See below. |
| 3. Enable SharePoint Online metered label writing | One-time setup that registers a confidential client, grants its administrator consent, and links Azure billing, so the SPO source can apply labels instead of only surveying. Also re-links billing, grants consent for an existing application, replaces it, or forgets it. |
| 4. Change where the files are | Switches between the local/UNC/SharePoint Server file-path source and native SharePoint Online without restarting. |
| 5. Forget settings remembered from previous runs | Lists every value this utility remembers, with its scope, and clears them on confirmation. Also signs out of Microsoft Graph, which is otherwise kept so later runs do not prompt. Variables owned by other tools are listed but never modified. |
| 6. Show current session summary | Totals so far for this session: scanned, labeled, unconfirmed, skipped, failed, and elapsed time. |
| 7. Exit cleanly | Exports the report, prints the summary, and closes every session the utility opened. |

To ignore remembered values for a single run **without deleting anything**, start it with `-Fresh`:

```powershell
.\Invoke-PurviewFileLabeling.ps1 -Fresh
```

That suppresses every remembered application ID, site URL, library, and confidential client, so nothing from an earlier run or a different tenant is proposed as a default. The startup banner says so, and the setting carries across the PowerShell 7 relaunch.

Option 3 changes what the other options can do, and it is the only one that can lead to a charge. It is described in full under [Enabling the SharePoint Online apply path](#enabling-the-sharepoint-online-apply-path). Until you run it, the SharePoint Online source is survey-only and costs nothing.

## Batch runs from a CSV

A guided run applies one label to one folder. When different folders need different labels, the main menu's batch option takes a CSV instead, so one sign-in covers the whole set:

```csv
Folder,Label,Recurse,Extensions
HR/Policies,Confidential,true,".docx,.pdf"
Public,General \ Anyone (unrestricted),false,
Archive/2019,Highly Confidential,true,
,Confidential,false,
```

Reading those four rows in order: `HR/Policies` and everything beneath it gets `Confidential`, but only Word documents and PDFs are touched. `Public` gets a parented label and is not recursed, so its subfolders are left alone. `Archive/2019` and everything beneath it gets `Highly Confidential` using the extension set you chose at the prompt, because its `Extensions` cell is empty. The last row has an empty `Folder`, which means the root itself, so it labels the loose files sitting directly in the root without descending into any of the folders above.

- `Folder` is relative to the library or root folder you pick after choosing the source. Leave it empty, or use `.`, to mean the root itself. Forward and backward slashes both work.
- `Label` accepts the display name shown in the label menu, the child name on its own for a parented label such as `Anyone (unrestricted)`, or the label GUID.
- `Recurse` is optional and defaults to `true`. It accepts `true`/`false`, `yes`/`no`, or `1`/`0`.
- `Extensions` is optional and falls back to the extension set you choose before the file is read.

The whole plan is validated before anything runs. A row naming a label that does not exist in the tenant, or an unreadable `Recurse` value, is dropped and reported, and the remaining rows still run. If nothing usable is left, the file is rejected. The resolved plan is printed for review, and apply mode still requires its own confirmation. All folders share one log and one CSV report.

Rows are processed in the order they appear, and overlapping folders are not detected. A recursive row combined with a row for one of its own subfolders therefore visits those files twice and reports them twice. In apply mode the priority rule still prevents the second visit from lowering a label that the first one raised.

## Outputs and Safety

Each run creates timestamped `.log` and `.csv` files. The CSV records every processed file, previous label, requested new label, outcome, and details. The closing summary reports totals scanned, labeled, not confirmed, skipped, failed, and elapsed time.

For the file-path source, the utility uses `Get-FileStatus` per file and calls `Set-FileLabel -PreserveFileDetails` only after apply mode and explicit confirmation. For SharePoint Online it reads labels with `Get-PnPFileSensitivityLabel`; Apply calls `Add-PnPFileSensitivityLabel`, which submits the metered `assignSensitivityLabel` request. Note the near-identical `Get-PnPFileSensitivityLabelInfo`: despite the more descriptive name it is a SharePoint tenant-admin CSOM call that fails with `Attempted to perform an unauthorized operation` for anyone who is not a SharePoint Administrator, so this utility deliberately does not use it. Failures are collected and reported instead of terminating the whole run. Operator menus allow retry, changed input, skip, main menu, or clean exit. Every session it opens, to Security &amp; Compliance PowerShell or to SharePoint, is closed on exit.

At startup the utility records its version, the host, and the version of every module it can use into the run log, and warns when one is older than expected. A billing attempt additionally records the Azure CLI executable and version, `graphservices` extension version when installed, active cloud, subscription state and tenant, application and application tenant, resource group and location, provider registration state, advertised `Microsoft.GraphServices/accounts` API versions, validation deployment name, requested API version, nested ARM error codes, and tracking or correlation IDs. These diagnostics are log-only so the console stays readable. They contain no password, token, client secret, certificate material, or signed-in account name.

PowerShell execution policy may block local scripts. Follow the customer's approved policy; do not weaken organization-wide policy solely to run this utility.

## As-Is Disclaimer

This sample is provided **as is**, without warranty of any kind. The customer is responsible for validating discovered labels and priorities, permissions, retention and encryption effects, backups, change controls, and compliance requirements before production use. Applying a sensitivity label can encrypt content and change who can open it. Microsoft and the script author are not responsible for data loss, loss of access, or unintended policy effects arising from its use.
