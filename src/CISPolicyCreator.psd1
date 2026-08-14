@{
    RootModule = 'CISPolicyCreator.psm1'
    ModuleVersion = '0.2.0'
    GUID = 'f1b23b46-8c60-4e7f-ae86-0d5e079e04e9'
    Author = 'CISPolicyCreator contributors'
    Description = 'Fail-closed helpers for creating Microsoft Intune policy packs from supported CIS Intune benchmarks.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('*-Cpc*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Intune','MicrosoftGraph','Security','CIS','Policy')
            ProjectUri = 'https://github.com/JoeryVandenBosch/CISPolicyCreator'
            LicenseUri = 'https://github.com/JoeryVandenBosch/CISPolicyCreator/blob/main/LICENSE'
        }
    }
}
