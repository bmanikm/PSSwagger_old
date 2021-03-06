#########################################################################################
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Licensed under the MIT license.
#
# PSSwagger Tests
#
#########################################################################################
[CmdletBinding()]
param(
    [ValidateSet("All", "UnitTest", "ScenarioTest")]
    [string[]]$TestSuite = "All",
    [string[]]$TestName,
    [ValidateSet("net452", "netstandard1.7")]
    [string]$TestFramework = "net452",
    [switch]$EnableTracing
)

$executeTestsCommand = "Set-Location -Path '$PSScriptRoot'"
$nodeModuleVersions = @{}
$NodeJSVersion = '8.1.4'
$NodeJSPackageName = "node-v$NodeJSVersion-win-x64"

# Note: If we use the $PSScriptRoot, Expand-Archive cmdlet is failing with below error. So using $env:SystemDrive\$NodeJSPackageName path for now.
#    "The specified path, file name, or both are too long. The fully qualified file name must be less than 260 characters, and 
#    the directory name must be less than 248 characters"
$NodeJSLocalPath = Join-Path -Path $env:SystemDrive -ChildPath $NodeJSPackageName

if (-not (Test-Path -Path $NodeJSLocalPath -PathType Container)) {
    $NodeJSZipURL = "https://nodejs.org/dist/v$NodeJSVersion/$NodeJSPackageName.zip"
    $TempNodeJSZipLocalPath = Join-Path -Path $env:TEMP -ChildPath "$NodeJSPackageName.zip"
    Invoke-WebRequest -Uri $NodeJSZipURL -OutFile $TempNodeJSZipLocalPath -UseBasicParsing
    try {
        # Using Join-Path to get "$env:SystemDrive\" path.
        $DestinationPath = Join-Path -Path $env:SystemDrive -ChildPath ''
        Expand-Archive -Path $TempNodeJSZipLocalPath -DestinationPath $DestinationPath -Force

        if (-not (Test-Path -Path $NodeJSLocalPath -PathType Container)) {
            Throw "Unable to install '$NodeJSZipURL' to local machine."
        }
    }
    finally {
        Remove-Item -Path $TempNodeJSZipLocalPath -Force
    }
}

$NpmCmdPath = Join-Path -Path $NodeJSLocalPath -ChildPath 'npm.cmd'
if (-not (Test-Path -Path $NpmCmdPath -PathType Leaf)) {
    Throw "Unable to find $NpmCmdPath."
}
$nodeModuleVersions['npm'] = & $NpmCmdPath list -g npm

$NodeModulesPath = Join-Path -Path $PSScriptRoot -ChildPath 'NodeModules'
if (-not (Test-Path -Path $NodeModulesPath -PathType Container)) {
    $null = New-Item -Path $NodeModulesPath -ItemType Directory -Force
}

# Set up AutoRest
# Install AutoRest using NPM, if not installed already.
$AutorestCmdPath = Join-Path -Path $NodeModulesPath -ChildPath 'autorest.cmd'
if (-not (Test-Path -Path $AutorestCmdPath -PathType Leaf)) {
    Write-Verbose "Couldn't find $AutorestCmdPath. Running 'npm install -g autorest'."
    & $NpmCmdPath install -g --prefix $NodeModulesPath autorest --scripts-prepend-node-path
}
$nodeModuleVersions['autorest'] = & $NpmCmdPath list -g --prefix $NodeModulesPath autorest
$executeTestsCommand += ";`$env:Path =`"$NodeModulesPath;`$env:Path`""

$AutoRestPluginPath = Join-Path -Path $env:USERPROFILE -ChildPath '.autorest' | 
    Join-Path -ChildPath 'plugins' | 
    Join-Path -ChildPath 'autorest'

if (-not ((Test-Path -Path $AutoRestPluginPath -PathType Container) -and 
        (Get-ChildItem -Path $AutoRestPluginPath -Directory))) {
    # Create the generator plugins
    & $AutorestCmdPath  --reset
}

$testRunGuid = [guid]::NewGuid().GUID
Write-Verbose -message "Test run GUID: $testRunGuid"
# Set up scenario test requirements
if ($TestSuite.Contains("All") -or $TestSuite.Contains("ScenarioTest")) {

    # Ensure we have json-server
    $jsonServerPath = Join-Path -Path $NodeModulesPath -ChildPath 'json-server.cmd'
    if (-not (Test-Path -Path $jsonServerPath -PathType Leaf)) {
        Write-Verbose "Couldn't find $jsonServerPath. Running 'npm install -g json-server@0.9.6'."
        & $NpmCmdPath install -g --prefix $NodeModulesPath json-server@0.9.6 --scripts-prepend-node-path
    }
    $nodeModuleVersions['json-server'] = & $NpmCmdPath list -g --prefix $NodeModulesPath json-server

    $localnode_modulesPath = Join-Path -Path $PSScriptRoot -ChildPath 'node_modules'
    <#
    # Create package.json under $PSScriptRoot using below command.
    # Otherwise, you will get following error in AppVeyor build.
    #    "npm.cmd : npm WARN saveError ENOENT: no such file or directory, open 'C:\projects\psswagger\Tests\package.json'""
    Set-Location -Path $PSScriptRoot
    & $NpmCmdPath install express --scripts-prepend-node-path
    & $NpmCmdPath init -y
    #>
    # For these node modules, it's easier on the middleware script devs to just install the modules locally instead of globally
    # Ensure we have request (for easy HTTP request creation for some test middlewares)
    if (-not (Test-Path -Path (Join-Path -Path $localnode_modulesPath -ChildPath 'request'))) {
        Write-Verbose "Couldn't find 'request' module. Running 'npm install request'."
        & $NpmCmdPath install request --scripts-prepend-node-path
    }

    # Ensure we have async (for HTTP request resolution synchronously in some test middlewares)
    if (-not (Test-Path -Path (Join-Path -Path $localnode_modulesPath -ChildPath 'async'))) {
        Write-Verbose "Couldn't find 'async' module. Running 'npm install async'."
        & $NpmCmdPath install async --scripts-prepend-node-path
    }

    $executeTestsCommand += ";`$global:testRunGuid=`"$testRunGuid`""

    # Set up the common generated modules location
    $generatedModulesPath = Join-Path -Path "$PSScriptRoot" -ChildPath 'Generated'
    # Remove existing Generated folder contents.
    if (Test-Path -Path $generatedModulesPath -PathType Container) {
        Remove-Item -Path $generatedModulesPath -Recurse -Force
    }
    $null = New-Item -Path $generatedModulesPath -ItemType Directory
}

# AzureRM.Profile requirement
$azureRmProfile = Get-Package -Name AzureRM.Profile -Provider PowerShellGet -ErrorAction Ignore
if (-not $azureRmProfile) {
    if (-not (Get-PackageSource -Name PSGallery -ErrorAction Ignore)) {
        Register-PackageSource -Name PSGallery -ProviderName PowerShellGet
    }

    $azureRmProfile = Install-Package -Name AzureRM.Profile -Provider PowerShellGet -Source PSGallery -Force | Where-Object { $_.Name -eq 'AzureRM.Profile' }
}

$powershellFolder = $null
if ("netstandard1.7" -eq $TestFramework) {
    # beta > alpha
    $powershellCore = Get-Package -Name PowerShell* -ProviderName msi | Sort-Object -Property Name -Descending | Select-Object -First 1
    if ($null -eq $powershellCore) {
        throw "PowerShellCore not found on this machine. Run: tools\Get-PowerShellCore"
    }
    $psVersion = $powershellCore.Name.Substring(11)
    $powershellFolder = "$Env:ProgramFiles\PowerShell\$($psVersion)"
    $executeTestsCommand += ";`$env:PSModulePath_Backup=`"$env:PSModulePath`""
}

if ($EnableTracing) {
    $executeTestsCommand += ";`$global:PSSwaggerTest_EnableTracing=`$true"
}

$executeTestsCommand += ";`$verbosepreference=`"continue`";Invoke-Pester -ExcludeTag KnownIssue -OutputFormat NUnitXml -OutputFile ScenarioTestResults.xml -Verbose"

# Set up Pester params
$pesterParams = @{'ExcludeTag' = 'KnownIssue'; 'OutputFormat' = 'NUnitXml'; 'OutputFile' = 'TestResults.xml'}
if ($PSBoundParameters.ContainsKey('TestName')) {
    $executeTestsCommand += " -TestName `"$TestName`""
}

if ($TestSuite.Contains("All")) {
    Write-Verbose "Invoking all tests."
}
else {
    Write-Verbose "Running only tests with tag: $TestSuite"
    $executeTestsCommand += " -Tag $TestSuite"
}

Write-Verbose "Dependency versions:"
Write-Verbose " -- AzureRM.Profile: $($azureRmProfile.Version)"
Write-Verbose " -- Pester: $((get-command invoke-pester).Version)"
if ($autoRestModule) {
    Write-Verbose " -- AutoRest: $($autoRestModule.Version)"
}
foreach ($entry in $nodeModuleVersions.GetEnumerator()) {
    Write-Verbose " -- $($entry.Key): $($entry.Value)"
}
$PesterCommandFilePath = Join-Path -Path $PSScriptRoot -ChildPath 'PesterCommand.ps1'
Write-Verbose "Executing: $executeTestsCommand"
$executeTestsCommand | Out-File -FilePath $PesterCommandFilePath

if ($TestFramework -eq "netstandard1.7") {
    try {
        $null = Get-CimInstance Win32_OperatingSystem
        Write-Verbose -Message "Invoking PowerShell Core at: $powershellFolder"
        & "$powershellFolder\powershell" -command $PesterCommandFilePath
    }
    catch {
        # For non-Windows, keep using the basic command
        powershell -command $PesterCommandFilePath
    }
}
else {
    powershell -command $PesterCommandFilePath
}

# Verify output
$x = [xml](Get-Content -raw "ScenarioTestResults.xml")
if ([int]$x.'test-results'.failures -gt 0) {
    throw "$($x.'test-results'.failures) tests failed"
}