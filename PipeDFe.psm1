#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Module State
$Script:NativeDllDirectoryInitialized = $false
$Script:NativeDllDirectoryCookie      = [System.IntPtr]::Zero

$Script:JsonSchemaVersion             = 1
$Script:SmtpSchemaVersion             = 1
#endregion

#region Configuration
$Script:ModuleRoot = $PSScriptRoot

$Script:SQLite = [PSCustomObject]@{
    AssemblyName   = 'System.Data.SQLite'
    MinimumVersion = [version]'2.0.3.0'
    SupportedMajor = 2
}

# Compatibility strategy:
# - Desktop → Windows PowerShell 5.1 / .NET Framework
# - Core    → PowerShell 7+ / .NET
$Script:TargetFramework = @{
    Desktop  = 'net471'
    Core     = 'netstandard2.0'
}.Item($PSVersionTable.PSEdition)

$Script:Architecture = if ([System.Environment]::Is64BitProcess) {
    'x64'
} else {
    'x86'
}

$Script:SQLiteAssemblyPath = Join-Path -Path $Script:ModuleRoot -ChildPath (
    'lib/{0}/System.Data.SQLite.dll' -f $Script:TargetFramework
)

$Script:SQLiteNativePath = Join-Path -Path $Script:ModuleRoot -ChildPath (
    'lib/native/{0}' -f $Script:Architecture
)
#endregion

#region NativeDllLoader
$interopPath = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/Interop'

$nativeDllLoaderScripts = @(
    'Invoke-NativeSetDefaultDllDirectory.ps1'
    'Invoke-NativeAddDllDirectory.ps1'
    'Invoke-NativeSetDllDirectory.ps1'
    'Initialize-NativeDllLoader.ps1'
)

foreach ($scriptName in $nativeDllLoaderScripts) {
    . (Join-Path -Path $interopPath -ChildPath $scriptName)
}

#
# Native SQLite provider
#
# Required for native SQLite runtime resolution.
if (-not (Test-Path -LiteralPath $Script:SQLiteNativePath -PathType Container)) {
    throw [System.IO.DirectoryNotFoundException]::new(
        "SQLite native library directory not found: '$($Script:SQLiteNativePath)'."
    )
}

if (-not (Test-Path -LiteralPath $Script:SQLiteAssemblyPath -PathType Leaf)) {
    throw [System.IO.FileNotFoundException]::new(
        "SQLite managed assembly not found.",
        $Script:SQLiteAssemblyPath
    )
}

Initialize-NativeDllLoader -LiteralPath $Script:SQLiteNativePath

$sqliteAssembly = [System.AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.GetName().Name -eq $Script:SQLite.AssemblyName } |
    Select-Object -First 1

# Avoid duplicate loading
if (-not $sqliteAssembly) {
    try {
        $sqliteAssembly = [System.Reflection.Assembly]::LoadFrom($Script:SQLiteAssemblyPath)
    } catch {
        throw [System.InvalidOperationException]::new(
            "Failed loading SQLite assembly '$($Script:SQLiteAssemblyPath)'.",
            $_.Exception
        )
    }
}
#endregion

#region Version validation
if ($null -eq $sqliteAssembly) {
    throw [System.InvalidOperationException]::new(
        "System.Data.SQLite assembly was not loaded."
    )
}

$assemblyName = $sqliteAssembly.GetName()

if ($assemblyName.Name -ne $Script:SQLite.AssemblyName) {
    throw [System.InvalidOperationException]::new(
        "Unexpected SQLite assembly loaded: '$($assemblyName.Name)'."
    )
}

if ($assemblyName.Version.Major -ne $Script:SQLite.SupportedMajor) {
    throw [System.InvalidOperationException]::new(
        "An incompatible System.Data.SQLite assembly is already loaded. " +
        "Loaded '$($assemblyName.Version)', expected major version '$($Script:SQLite.SupportedMajor)'."
    )
}

if ($assemblyName.Version -lt $Script:SQLite.MinimumVersion) {
    throw [System.InvalidOperationException]::new(
        "Unsupported SQLite assembly version '$($assemblyName.Version)'. " +
        "Expected version '$($Script:SQLite.MinimumVersion)' or higher."
    )
}
#endregion

#region Dot-source Scripts
# Loads scripts in dependency order.
# Layers are loaded sequentially, while scripts within each layer are loaded
# alphabetically to ensure deterministic initialization.
$dotSourceLayers = [ordered]@{
    Enum    = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Enum'
    Company = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/Company'
    Core    = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/Core'
    Crypt   = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/Crypt'
    IO      = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/IO'
    Parser  = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/Parser'
    Store   = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Private/Store'
    Public  = Join-Path -Path $Script:ModuleRoot -ChildPath 'src/Public'
}

foreach ($layer in $dotSourceLayers.GetEnumerator()) {
    $layerPath = $layer.Value

    if (-not (Test-Path -LiteralPath $layerPath -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new(
            "Required script layer not found: '$($layer.Key)' ($layerPath)."
        )
    }

    $getChildItemParams = @{
        LiteralPath = $layerPath
        Filter      = '*.ps1'
        File        = $true
        Recurse     = $true
    }

    foreach ($file in (Get-ChildItem @getChildItemParams | Sort-Object FullName)) {
        try {
            . $file.FullName
        } catch {
            throw [System.InvalidOperationException]::new(
                "Failed to dot-source script '$($file.FullName)'.",
                $_.Exception
            )
        }
    }
}
#endregion
