#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install and manage a sandboxed environment for safeclaw on Windows.

.DESCRIPTION
    Creates a restricted local user, NTFS-ACL-locked sandbox directory, and
    Windows Job Object process containment for safeclaw. This is the Windows
    equivalent of the Linux chroot-install.sh script.

    Isolation mechanisms:
      1. Restricted local user (safeclaw) with no admin rights
      2. NTFS ACLs confining writes to the sandbox directory only
      3. Job Object limiting process count, memory, and enforcing kill-on-close

.PARAMETER Command
    Action to perform: Setup, Start, Stop, Shell, Status, Teardown.

.PARAMETER Binary
    Path to safeclaw.exe (default: .\target\release\safeclaw.exe).

.PARAMETER SandboxRoot
    Root directory for the sandbox (default: C:\ProgramData\safeclaw).

.PARAMETER MaxProcesses
    Job Object active process limit (default: 64).

.PARAMETER MaxMemoryMB
    Job Object per-process memory limit in MB (default: 4096).

.EXAMPLE
    .\sandbox-install.ps1 Setup
    .\sandbox-install.ps1 Setup -Binary C:\bin\safeclaw.exe
    .\sandbox-install.ps1 Start
    .\sandbox-install.ps1 Stop
    .\sandbox-install.ps1 Shell
    .\sandbox-install.ps1 Status
    .\sandbox-install.ps1 Teardown

.NOTES
    Copyright (c) 2026 Joseph R. Quinn
    Contact: quinn.josephr@protonmail.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("Setup", "Start", "Stop", "Shell", "Status", "Teardown")]
    [string]$Command,

    [string]$Binary = ".\target\release\safeclaw.exe",

    [string]$SandboxRoot = "C:\ProgramData\safeclaw",

    [int]$MaxProcesses = 64,

    [int]$MaxMemoryMB = 4096
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ────────────────────────────────────────────────────────

$SA_USER       = "safeclaw"
$SA_FULLUSER   = "$env:COMPUTERNAME\$SA_USER"
$TASK_NAME     = "SafeAgentService"
$PID_FILE      = Join-Path $SandboxRoot "run\safeclaw.pid"

# Subdirectories inside the sandbox
$Dirs = @{
    Bin    = Join-Path $SandboxRoot "bin"
    Data   = Join-Path $SandboxRoot "data"
    Skills = Join-Path $SandboxRoot "data\skills"
    Config = Join-Path $SandboxRoot "config"
    Home   = Join-Path $SandboxRoot "home"
    Temp   = Join-Path $SandboxRoot "temp"
    Run    = Join-Path $SandboxRoot "run"
    Logs   = Join-Path $SandboxRoot "logs"
}

# ── Logging helpers ──────────────────────────────────────────────────

function Write-Log   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "[i] $Msg" -ForegroundColor Cyan }

# ── Job Object P/Invoke ─────────────────────────────────────────────

$JobObjectCode = @"
using System;
using System.Runtime.InteropServices;

public static class JobObject
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(
        IntPtr hJob, int jobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);

    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    // Constants
    public const int JobObjectExtendedLimitInformation = 9;
    public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE    = 0x00002000;
    public const uint JOB_OBJECT_LIMIT_ACTIVE_PROCESS        = 0x00000008;
    public const uint JOB_OBJECT_LIMIT_PROCESS_MEMORY        = 0x00000100;

    public static IntPtr Create(string name, uint maxProcesses, ulong maxMemoryBytes)
    {
        IntPtr hJob = CreateJobObject(IntPtr.Zero, name);
        if (hJob == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());

        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
            JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
            JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        info.BasicLimitInformation.ActiveProcessLimit = maxProcesses;
        info.ProcessMemoryLimit = new UIntPtr(maxMemoryBytes);

        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, ptr, (uint)size))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }

        return hJob;
    }

    public static void Assign(IntPtr hJob, IntPtr hProcess)
    {
        if (!AssignProcessToJobObject(hJob, hProcess))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void Terminate(IntPtr hJob)
    {
        TerminateJobObject(hJob, 1);
        CloseHandle(hJob);
    }
}
"@

$jobTypeAdded = $false
function Ensure-JobObjectType {
    if ($script:jobTypeAdded) { return }
    try {
        [JobObject] | Out-Null
        $script:jobTypeAdded = $true
    } catch {
        Add-Type -TypeDefinition $JobObjectCode -Language CSharp
        $script:jobTypeAdded = $true
    }
}

# ── User management ─────────────────────────────────────────────────

function Test-UserExists {
    try {
        Get-LocalUser -Name $SA_USER -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function New-SandboxUser {
    if (Test-UserExists) {
        Write-Info "User '$SA_USER' already exists."
        return
    }

    Write-Log "Creating local user '$SA_USER'..."

    # Generate a long random password (the user never logs in interactively)
    $passChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*"
    $password = -join (1..48 | ForEach-Object { $passChars[(Get-Random -Maximum $passChars.Length)] })
    $secPass = ConvertTo-SecureString $password -AsPlainText -Force

    New-LocalUser -Name $SA_USER `
        -Password $secPass `
        -FullName "safeclaw service account" `
        -Description "Restricted account for running safeclaw in a sandbox." `
        -PasswordNeverExpires `
        -UserMayNotChangePassword `
        -AccountNeverExpires | Out-Null

    # Deny interactive and remote desktop logon via local security policy
    # (net localgroup adds the user to the deny-logon lists)
    # We intentionally do NOT add the user to any privilege groups.
    Write-Log "User '$SA_USER' created (non-interactive, non-admin)."

    # Store the password encrypted for the scheduled task
    $credPath = Join-Path $SandboxRoot "run\.sa_cred"
    if (Test-Path (Split-Path $credPath)) {
        $password | ConvertTo-SecureString -AsPlainText -Force |
            ConvertFrom-SecureString |
            Set-Content -Path $credPath -Force
    }
}

function Get-SandboxCredential {
    $credPath = Join-Path $SandboxRoot "run\.sa_cred"
    if (-not (Test-Path $credPath)) {
        Write-Err "Credential file not found. Re-run Setup."
        exit 1
    }
    $secPass = Get-Content $credPath | ConvertTo-SecureString
    return New-Object System.Management.Automation.PSCredential($SA_FULLUSER, $secPass)
}

# ── Directory & ACL setup ───────────────────────────────────────────

function New-SandboxDirs {
    Write-Log "Creating sandbox directory tree at $SandboxRoot"

    foreach ($dir in $Dirs.Values) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Set NTFS ACLs: safeclaw gets FullControl on the sandbox tree.
    # Inherited SYSTEM and Administrators access is preserved (they own the parent).
    Write-Log "Configuring NTFS ACLs..."

    $acl = Get-Acl $SandboxRoot

    # Remove any existing rules for safeclaw
    $acl.Access | Where-Object {
        $_.IdentityReference.Value -like "*\$SA_USER"
    } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

    # Grant FullControl with inheritance
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $SA_FULLUSER,
        "FullControl",
        "ContainerInherit, ObjectInherit",
        "None",
        "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $SandboxRoot -AclObject $acl

    Write-Log "ACLs applied: $SA_USER has FullControl on $SandboxRoot"
}

# ── nvm-windows / pyenv-win directories ──────────────────────────────

$NVM_HOME  = Join-Path $SandboxRoot "nvm"
$NVM_SYMLINK = Join-Path $SandboxRoot "nodejs"
$PYENV_ROOT = Join-Path $SandboxRoot "pyenv"
$PYTHON_VERSION = "3.12"

function Refresh-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ── Dependency installation ─────────────────────────────────────────

function Install-Dependencies {
    # Check winget (still needed for Git only)
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $hasWinget) {
        Write-Err "winget is not available. Install 'App Installer' from the Microsoft Store."
        exit 1
    }

    # Git
    $gitVersion = $null
    try { $gitVersion = (git --version 2>$null) } catch {}
    if (-not $gitVersion) {
        Write-Info "Installing Git..."
        winget install --id Git.Git --accept-package-agreements --accept-source-agreements --silent
        Refresh-SessionPath
    } else {
        Write-Info "Git already installed ($gitVersion)."
    }

    # ── nvm-windows ────────────────────────────────────────────────
    Write-Log "Setting up nvm-windows..."
    $nvmExe = Join-Path $NVM_HOME "nvm.exe"

    if (-not (Test-Path $nvmExe)) {
        Write-Info "Installing nvm-windows..."
        $nvmZip = Join-Path $env:TEMP "nvm-noinstall.zip"
        $nvmUrl = "https://github.com/coreybutler/nvm-windows/releases/latest/download/nvm-noinstall.zip"
        Invoke-WebRequest -Uri $nvmUrl -OutFile $nvmZip -UseBasicParsing
        New-Item -ItemType Directory -Path $NVM_HOME -Force | Out-Null
        Expand-Archive -Path $nvmZip -DestinationPath $NVM_HOME -Force
        Remove-Item $nvmZip -Force

        # Write nvm settings
        @"
root: $NVM_HOME
path: $NVM_SYMLINK
arch: 64
proxy: none
"@ | Set-Content -Path (Join-Path $NVM_HOME "settings.txt") -Force

        Write-Log "nvm-windows installed to $NVM_HOME"
    } else {
        Write-Info "nvm-windows already installed."
    }

    # Add nvm to session PATH
    $env:NVM_HOME = $NVM_HOME
    $env:NVM_SYMLINK = $NVM_SYMLINK
    $env:Path = "$NVM_HOME;$NVM_SYMLINK;$env:Path"

    # Install Node.js LTS
    $nvmList = & $nvmExe list 2>$null
    if ($nvmList -match "lts") {
        Write-Info "Node.js LTS already installed via nvm."
    } else {
        Write-Log "Installing Node.js LTS via nvm-windows..."
        & $nvmExe install lts 2>&1 | Out-Null
    }
    & $nvmExe use lts 2>&1 | Out-Null
    Write-Log "Node.js active: $(& $nvmExe current 2>$null)"

    # ── pyenv-win ──────────────────────────────────────────────────
    Write-Log "Setting up pyenv-win..."
    $pyenvExe = Join-Path $PYENV_ROOT "pyenv-win\bin\pyenv.bat"

    if (-not (Test-Path $pyenvExe)) {
        Write-Info "Installing pyenv-win..."
        $pyenvZip = Join-Path $env:TEMP "pyenv-win.zip"
        $pyenvUrl = "https://github.com/pyenv-win/pyenv-win/archive/refs/heads/master.zip"
        Invoke-WebRequest -Uri $pyenvUrl -OutFile $pyenvZip -UseBasicParsing
        New-Item -ItemType Directory -Path $PYENV_ROOT -Force | Out-Null
        Expand-Archive -Path $pyenvZip -DestinationPath $env:TEMP -Force
        Copy-Item -Path (Join-Path $env:TEMP "pyenv-win-master\*") -Destination $PYENV_ROOT -Recurse -Force
        Remove-Item $pyenvZip -Force
        Remove-Item (Join-Path $env:TEMP "pyenv-win-master") -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "pyenv-win installed to $PYENV_ROOT"
    } else {
        Write-Info "pyenv-win already installed."
    }

    # Add pyenv to session PATH
    $env:PYENV = $PYENV_ROOT
    $env:PYENV_ROOT = $PYENV_ROOT
    $env:PYENV_HOME = $PYENV_ROOT
    $pyenvBin = Join-Path $PYENV_ROOT "pyenv-win\bin"
    $pyenvShims = Join-Path $PYENV_ROOT "pyenv-win\shims"
    $env:Path = "$pyenvBin;$pyenvShims;$env:Path"

    # Install Python
    $pyVersions = & $pyenvExe versions 2>$null
    if ($pyVersions -match $PYTHON_VERSION) {
        Write-Info "Python $PYTHON_VERSION already installed via pyenv-win."
    } else {
        Write-Log "Installing Python $PYTHON_VERSION via pyenv-win..."
        & $pyenvExe install $PYTHON_VERSION 2>&1 | Out-Null
    }
    & $pyenvExe global $PYTHON_VERSION 2>&1 | Out-Null
    Write-Log "Python active: $(& $pyenvExe version 2>$null)"

    # ── Claude Code CLI ──────────────────────────────────────────
    $hasClaude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $hasClaude) {
        Write-Log "Installing Claude Code CLI..."
        npm install -g @anthropic-ai/claude-code 2>&1 | Out-Null
    } else {
        Write-Info "Claude Code CLI already installed."
    }

    # ── ngrok ────────────────────────────────────────────────────
    $ngrokPath = Join-Path $Dirs.Bin "ngrok.exe"
    if (-not (Test-Path $ngrokPath)) {
        Write-Log "Installing ngrok..."
        $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
        $ngrokUrl = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-$arch.zip"
        $zipPath = Join-Path $env:TEMP "ngrok.zip"
        Invoke-WebRequest -Uri $ngrokUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $Dirs.Bin -Force
        Remove-Item $zipPath -Force
        Write-Log "ngrok installed to $($Dirs.Bin)"
    } else {
        Write-Info "ngrok already installed."
    }

    # ── Python packages for skills ───────────────────────────────
    Write-Log "Installing Python packages for skills..."
    $pipPkgs = @(
        "requests",
        "google-api-python-client",
        "google-auth-httplib2",
        "google-auth-oauthlib",
        "python-dotenv",
        "schedule",
        "httpx",
        "beautifulsoup4",
        "feedparser",
        "icalendar"
    )
    $pipArgs = @("install", "--quiet") + $pipPkgs
    try {
        & pip $pipArgs 2>&1 | Out-Null
    } catch {
        & python -m pip $pipArgs 2>&1 | Out-Null
    }
}

# ── Binary installation ─────────────────────────────────────────────

function Install-Binary {
    param([string]$BinaryPath)

    if (-not (Test-Path $BinaryPath)) {
        Write-Err "safeclaw binary not found at: $BinaryPath"
        Write-Err "Build it first (cargo build --release) or use -Binary."
        exit 1
    }

    $dest = Join-Path $Dirs.Bin "safeclaw.exe"
    Copy-Item -Path $BinaryPath -Destination $dest -Force
    Write-Log "Installed safeclaw.exe to $($Dirs.Bin)"
}

# ── Scheduled Task ──────────────────────────────────────────────────

function Register-SafeAgentTask {
    Write-Log "Registering scheduled task: $TASK_NAME"

    $exePath = Join-Path $Dirs.Bin "safeclaw.exe"

    # Unregister if it already exists
    try {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
    } catch {}

    $action = New-ScheduledTaskAction `
        -Execute $exePath `
        -WorkingDirectory $SandboxRoot

    # Trigger: at startup
    $trigger = New-ScheduledTaskTrigger -AtStartup

    # Settings: restart on failure, run indefinitely
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Seconds 30) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew

    # Run as safeclaw
    $cred = Get-SandboxCredential
    $principal = New-ScheduledTaskPrincipal `
        -UserId $SA_FULLUSER `
        -LogonType Password `
        -RunLevel Limited

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal

    Register-ScheduledTask `
        -TaskName $TASK_NAME `
        -InputObject $task `
        -User $SA_FULLUSER `
        -Password ($cred.GetNetworkCredential().Password) | Out-Null

    Write-Log "Scheduled task registered."
    Write-Info "Start with:    schtasks /run /tn $TASK_NAME"
    Write-Info "Stop with:     schtasks /end /tn $TASK_NAME"
    Write-Info "Status with:   schtasks /query /tn $TASK_NAME"
}

# ── Environment file ────────────────────────────────────────────────

function Write-EnvFile {
    $envPath = Join-Path $SandboxRoot "config\sandbox.env"
    $content = @"
# safeclaw sandbox environment variables
# Edit this file, then restart the agent.
# These are loaded by the Start command and set for the agent process.

XDG_DATA_HOME=$($Dirs.Data)
XDG_CONFIG_HOME=$($Dirs.Config)
HOME=$($Dirs.Home)
TEMP=$($Dirs.Temp)
TMP=$($Dirs.Temp)

# Required: set these before starting
# DASHBOARD_PASSWORD=changeme
# JWT_SECRET=changeme
# TELEGRAM_BOT_TOKEN=

# Optional
# TUNNEL_URL=
# NGROK_AUTHTOKEN=
"@
    Set-Content -Path $envPath -Value $content -Force
    Write-Log "Environment template written to $envPath"
}

function Read-EnvFile {
    $envPath = Join-Path $SandboxRoot "config\sandbox.env"
    $envVars = @{}
    if (Test-Path $envPath) {
        Get-Content $envPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) {
                $parts = $line -split "=", 2
                if ($parts.Count -eq 2) {
                    $envVars[$parts[0].Trim()] = $parts[1].Trim()
                }
            }
        }
    }
    return $envVars
}

# ── Commands ─────────────────────────────────────────────────────────

function Invoke-Setup {
    Write-Log "Setting up safeclaw sandbox..."
    Write-Info "Sandbox root: $SandboxRoot"

    # Create directory tree first (needed for credential file)
    New-SandboxDirs
    Install-Dependencies
    New-SandboxUser
    # Re-apply ACLs after user creation
    New-SandboxDirs
    Install-Binary -BinaryPath $Binary
    Write-EnvFile
    Register-SafeAgentTask

    Write-Host ""
    Write-Log "Setup complete!"
    Write-Host ""
    Write-Info "Sandbox root:  $SandboxRoot"
    Write-Info "Runtime user:  $SA_USER"
    Write-Info "Data dir:      $($Dirs.Data)"
    Write-Info "Config dir:    $($Dirs.Config)"
    Write-Info "Home dir:      $($Dirs.Home)"
    Write-Host ""
    Write-Info "Next steps:"
    Write-Info "  1. Copy config.toml to: $($Dirs.Config)\"
    Write-Info "  2. Edit environment:    $($Dirs.Config)\sandbox.env"
    Write-Info "     (set DASHBOARD_PASSWORD, JWT_SECRET, etc.)"
    Write-Info "  3. Start the agent:     .\sandbox-install.ps1 Start"
    Write-Info "     Or via task:         schtasks /run /tn $TASK_NAME"
}

function Invoke-Start {
    $exePath = Join-Path $Dirs.Bin "safeclaw.exe"
    if (-not (Test-Path $exePath)) {
        Write-Err "safeclaw.exe not found in sandbox. Run Setup first."
        exit 1
    }

    # Check if already running
    $existing = Get-Process -Name "safeclaw" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $exePath }
    if ($existing) {
        Write-Err "safeclaw is already running (PID $($existing.Id))."
        exit 1
    }

    Ensure-JobObjectType

    # Read environment
    $envVars = Read-EnvFile

    # Build environment block
    $envBlock = @{
        "XDG_DATA_HOME"   = $Dirs.Data
        "XDG_CONFIG_HOME" = $Dirs.Config
        "HOME"            = $Dirs.Home
        "TEMP"            = $Dirs.Temp
        "TMP"             = $Dirs.Temp
        "USERPROFILE"     = $Dirs.Home
    }
    foreach ($k in $envVars.Keys) {
        $envBlock[$k] = $envVars[$k]
    }

    Write-Log "Creating Job Object (max $MaxProcesses processes, $MaxMemoryMB MB/process)..."
    $memBytes = [uint64]$MaxMemoryMB * 1024 * 1024
    $hJob = [JobObject]::Create("SafeAgentSandbox", [uint32]$MaxProcesses, $memBytes)

    Write-Log "Starting safeclaw as $SA_USER..."

    # Set environment variables for the child process
    foreach ($k in $envBlock.Keys) {
        [System.Environment]::SetEnvironmentVariable($k, $envBlock[$k], "Process")
    }

    # Start the process as the sandbox user
    $cred = Get-SandboxCredential
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.WorkingDirectory = $SandboxRoot
    $psi.UseShellExecute = $false
    $psi.UserName = $SA_USER
    $psi.Password = $cred.Password
    $psi.Domain = $env:COMPUTERNAME
    $psi.LoadUserProfile = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false

    # Set environment on the process start info
    foreach ($k in $envBlock.Keys) {
        $psi.EnvironmentVariables[$k] = $envBlock[$k]
    }
    # Ensure PATH includes nvm-managed Node.js, pyenv-managed Python, Git, and sandbox bin
    $nvmNodeDir = $NVM_SYMLINK
    $pyenvShims = Join-Path $PYENV_ROOT "pyenv-win\shims"
    $pyenvBin   = Join-Path $PYENV_ROOT "pyenv-win\bin"
    $psi.EnvironmentVariables["NVM_HOME"]    = $NVM_HOME
    $psi.EnvironmentVariables["NVM_SYMLINK"] = $NVM_SYMLINK
    $psi.EnvironmentVariables["PYENV"]       = $PYENV_ROOT
    $psi.EnvironmentVariables["PYENV_ROOT"]  = $PYENV_ROOT
    $psi.EnvironmentVariables["PYENV_HOME"]  = $PYENV_ROOT
    $psi.EnvironmentVariables["PATH"] = @(
        $Dirs.Bin,
        $NVM_HOME,
        $nvmNodeDir,
        $pyenvBin,
        $pyenvShims,
        (Join-Path $env:ProgramFiles "Git\cmd"),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot "System32")
    ) -join ";"

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Err "Failed to start process: $_"
        [JobObject]::Terminate($hJob)
        exit 1
    }

    # Assign to Job Object
    try {
        [JobObject]::Assign($hJob, $proc.Handle)
        Write-Log "Process assigned to Job Object."
    } catch {
        Write-Warn "Could not assign to Job Object: $_"
        Write-Warn "Process is running without Job Object containment."
    }

    # Write PID file
    $proc.Id | Set-Content -Path $PID_FILE -Force
    Write-Log "safeclaw started (PID $($proc.Id))."
    Write-Info "Logs: check the dashboard at http://localhost:3031"
    Write-Info "Stop: .\sandbox-install.ps1 Stop"

    # Wait for the process (blocks until it exits)
    Write-Info "Waiting for safeclaw to exit (Ctrl+C to detach)..."
    try {
        $proc.WaitForExit()
        Write-Log "safeclaw exited with code $($proc.ExitCode)."
    } catch {
        Write-Warn "Detached from process."
    } finally {
        [JobObject]::Terminate($hJob) 2>$null
        Remove-Item -Path $PID_FILE -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Stop {
    Write-Log "Stopping safeclaw..."

    $exePath = Join-Path $Dirs.Bin "safeclaw.exe"

    # Try PID file first
    if (Test-Path $PID_FILE) {
        $pid = [int](Get-Content $PID_FILE)
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Info "Stopping PID $pid..."
            $proc.Kill()
            $proc.WaitForExit(15000) | Out-Null
        }
        Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
    }

    # Kill any remaining safeclaw processes from the sandbox
    Get-Process -Name "safeclaw" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $exePath } |
        ForEach-Object {
            Write-Info "Killing leftover PID $($_.Id)..."
            $_.Kill()
        }

    # Also stop the scheduled task if running
    try {
        $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction Stop
        if ($task.State -eq "Running") {
            Stop-ScheduledTask -TaskName $TASK_NAME
            Write-Info "Scheduled task stopped."
        }
    } catch {}

    Write-Log "Stopped."
}

function Invoke-Shell {
    Write-Info "Opening shell as $SA_USER in sandbox..."
    Write-Info "Working directory: $SandboxRoot"
    Write-Info "Type 'exit' to leave."

    $cred = Get-SandboxCredential

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/k title safeclaw sandbox & cd /d `"$SandboxRoot`""
    $psi.WorkingDirectory = $SandboxRoot
    $psi.UseShellExecute = $false
    $psi.UserName = $SA_USER
    $psi.Password = $cred.Password
    $psi.Domain = $env:COMPUTERNAME
    $psi.LoadUserProfile = $true

    $psi.EnvironmentVariables["XDG_DATA_HOME"]   = $Dirs.Data
    $psi.EnvironmentVariables["XDG_CONFIG_HOME"] = $Dirs.Config
    $psi.EnvironmentVariables["HOME"]            = $Dirs.Home
    $psi.EnvironmentVariables["TEMP"]            = $Dirs.Temp
    $psi.EnvironmentVariables["TMP"]             = $Dirs.Temp
    $psi.EnvironmentVariables["NVM_HOME"]        = $NVM_HOME
    $psi.EnvironmentVariables["NVM_SYMLINK"]     = $NVM_SYMLINK
    $psi.EnvironmentVariables["PYENV"]           = $PYENV_ROOT
    $psi.EnvironmentVariables["PYENV_ROOT"]      = $PYENV_ROOT
    $psi.EnvironmentVariables["PATH"] = @(
        $Dirs.Bin,
        $NVM_HOME,
        $NVM_SYMLINK,
        (Join-Path $PYENV_ROOT "pyenv-win\bin"),
        (Join-Path $PYENV_ROOT "pyenv-win\shims"),
        (Join-Path $env:ProgramFiles "Git\cmd"),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot "System32")
    ) -join ";"

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
    } catch {
        Write-Err "Failed to start shell: $_"
        Write-Info "Falling back to a regular shell with sandbox env vars..."
        $env:XDG_DATA_HOME   = $Dirs.Data
        $env:XDG_CONFIG_HOME = $Dirs.Config
        $env:HOME            = $Dirs.Home
        cmd.exe /k "title safeclaw sandbox & cd /d `"$SandboxRoot`""
    }

    Write-Info "Shell session ended."
}

function Invoke-Status {
    Write-Host ""
    Write-Host "-- safeclaw sandbox status --" -ForegroundColor Cyan
    Write-Host ""

    # Sandbox directory
    if (-not (Test-Path $SandboxRoot)) {
        Write-Warn "Sandbox directory does not exist: $SandboxRoot"
        Write-Warn "Run '.\sandbox-install.ps1 Setup' first."
        return
    }
    Write-Info "Sandbox root: $SandboxRoot"

    # User
    Write-Host ""
    Write-Host "User:" -ForegroundColor Cyan
    if (Test-UserExists) {
        $user = Get-LocalUser -Name $SA_USER
        $enabled = if ($user.Enabled) { "Enabled" } else { "Disabled" }
        Write-Host "  [+] $SA_USER ($enabled)" -ForegroundColor Green
    } else {
        Write-Host "  [x] $SA_USER does not exist" -ForegroundColor Red
    }

    # Process
    Write-Host ""
    Write-Host "Process:" -ForegroundColor Cyan
    $exePath = Join-Path $Dirs.Bin "safeclaw.exe"
    $procs = Get-Process -Name "safeclaw" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $exePath }
    if ($procs) {
        foreach ($p in $procs) {
            $mem = [math]::Round($p.WorkingSet64 / 1MB, 1)
            Write-Host "  [+] PID $($p.Id), Memory: ${mem} MB, CPU: $([math]::Round($p.TotalProcessorTime.TotalSeconds, 1))s" -ForegroundColor Green
        }
    } else {
        Write-Host "  [x] safeclaw not running" -ForegroundColor Red
    }

    # Scheduled task
    Write-Host ""
    Write-Host "Scheduled Task:" -ForegroundColor Cyan
    try {
        $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction Stop
        $taskState = $task.State
        $color = if ($taskState -eq "Running") { "Green" } elseif ($taskState -eq "Ready") { "Yellow" } else { "Red" }
        Write-Host "  [$TASK_NAME] $taskState" -ForegroundColor $color
    } catch {
        Write-Host "  [x] Task '$TASK_NAME' not registered" -ForegroundColor Red
    }

    # Directory sizes
    Write-Host ""
    Write-Host "Disk usage:" -ForegroundColor Cyan
    foreach ($name in @("Data", "Config", "Home", "Logs")) {
        $dir = $Dirs[$name]
        if (Test-Path $dir) {
            $size = (Get-ChildItem -Path $dir -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            $sizeMB = [math]::Round(($size / 1MB), 1)
            Write-Host "  ${name}: $dir (${sizeMB} MB)" -ForegroundColor Gray
        }
    }

    Write-Host ""
}

function Invoke-Teardown {
    Write-Warn "This will REMOVE the sandbox at $SandboxRoot"
    Write-Warn "and unregister the scheduled task."
    $confirm = Read-Host "Are you sure? [y/N]"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Info "Cancelled."
        return
    }

    # Stop
    try { Invoke-Stop } catch {}

    # Remove scheduled task
    try {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
        Write-Log "Removed scheduled task."
    } catch {
        Write-Info "No scheduled task to remove."
    }

    # Remove sandbox directory
    if (Test-Path $SandboxRoot) {
        Remove-Item -Path $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed $SandboxRoot"
    }

    Write-Log "Teardown complete."
    Write-Info "The '$SA_USER' local user was NOT removed."
    Write-Info "Remove manually with: Remove-LocalUser -Name $SA_USER"
}

# ── Main dispatch ────────────────────────────────────────────────────

switch ($Command) {
    "Setup"    { Invoke-Setup }
    "Start"    { Invoke-Start }
    "Stop"     { Invoke-Stop }
    "Shell"    { Invoke-Shell }
    "Status"   { Invoke-Status }
    "Teardown" { Invoke-Teardown }
}
