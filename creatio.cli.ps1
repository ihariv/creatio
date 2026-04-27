# --- 0. Конфигурация ---
$GlobalConfig = [PSCustomObject]@{
    Prefix       = "creatio83-"
    BaseHttpPort = 5000
    BaseDbPort   = 4000
    Paths = @{
        Zip     = "$PSScriptRoot/../8.3.3.3192_StudioNet8_Softkey_PostgreSQL_ENU.zip"
        Creatio = "$PSScriptRoot/../creatio"
        Runtime = "$PSScriptRoot/../runtime"
        Backup  = "$PSScriptRoot/../BPMonline833StudioNet8.backup"
        ClioConfig = "$PSScriptRoot/clio-envs.json"
    }
}

# --- 1. Вспомогательные функции ---

function Get-DeployedEnvs {
    $containers = docker ps -a --format "{{.Names}}" 2>$null
    if (-not $containers) { return @() }
    $envs = $containers | Where-Object { $_ -match "^$($GlobalConfig.Prefix)(.+)$" } | ForEach-Object { $matches[1] } | Select-Object -Unique
    return $envs
}

function Get-ContainerPort {
    param($ContainerName, $InternalPort)
    $jsonStr = docker inspect $ContainerName 2>$null
    if (-not $jsonStr) { return "N/A" }
    $json = $jsonStr | ConvertFrom-Json
    if (-not $json -or $json.Count -eq 0) { return "N/A" }

    $ports = $json[0].NetworkSettings.Ports
    if (-not $ports) { return "N/A" }

    $targetKey = "$InternalPort/tcp"
    foreach ($prop in $ports.PSObject.Properties) {
        if ($prop.Name -eq $targetKey) {
            $mappings = $prop.Value
            if ($mappings -and $mappings.Count -gt 0) {
                $hostPort = $mappings[0].HostPort
                if ($hostPort) { return $hostPort }
            }
        }
    }
    return "N/A"
}

function Reset-SupervisorPassword {
    param($EnvName)
    $containerDb = "postgres17-creatio-$EnvName"

    if (-not (docker ps -a -q -f name=$containerDb)) {
        Write-Warning "Контейнер базы $containerDb не найден."
        return
    }

    Write-Host ">>> Resetting Supervisor password for [$EnvName]..." -ForegroundColor Yellow

    $sql = @"
update "SysAdminUnit" set "UserPassword" = 'JSDCg18tavKu1PPRqdP6t.AgqDORMm2cT7oDjw66hML64avIF/Qa2' where "Name" = 'Supervisor';
"@

    $result = $sql | docker exec -i $containerDb psql -U app -d app 2>&1

    if ($result -match "UPDATE 1") {
        Write-Host "Success: Password reset to 'Supervisor'." -ForegroundColor Green
    } else {
        Write-Host "DB Error: $result" -ForegroundColor Red
    }
}

# --- 2. Основные команды ---

function Show-Status {
    Write-Host "`n--- Managed Environments (Optimized) ---" -ForegroundColor Cyan
    $envs = Get-DeployedEnvs
    if ($envs.Count -eq 0) { Write-Host "No environments found." -ForegroundColor Gray; return }

    $allData = @()
    $targetNames = docker ps -a --format "{{.Names}}" | Where-Object { $_ -match "creatio|postgres|redis" }
    foreach ($name in $targetNames) {
        $item = docker inspect $name 2>$null | ConvertFrom-Json
        if ($item) { $allData += $item[0] }
    }

    foreach ($e in $envs) {
        $creatio = $allData | Where-Object { $_.Name -eq "/$($GlobalConfig.Prefix)$e" }
        $db      = $allData | Where-Object { $_.Name -eq "/postgres17-creatio-$e" }
        $redis   = $allData | Where-Object { $_.Name -eq "/redis7-creatio-$e" }

        if (-not $creatio) { continue }
        $isRunning = $creatio.State.Running

        $hPort = if ($creatio.NetworkSettings.Ports."5000/tcp".HostPort[0]) { $creatio.NetworkSettings.Ports."5000/tcp".HostPort[0] } else { "N/A" }
        $dPort = if ($db.NetworkSettings.Ports."5432/tcp".HostPort[0]) { $db.NetworkSettings.Ports."5432/tcp".HostPort[0] } else { "N/A" }
        $rPort = if ($redis.NetworkSettings.Ports."6379/tcp".HostPort[0]) { $redis.NetworkSettings.Ports."6379/tcp".HostPort[0] } else { "N/A" }

        $color = if ($isRunning) { "Green" } else { "Gray" }
        $statusText = if ($isRunning) { "RUNNING" } else { "STOPPED" }

        Write-Host "[$e] " -NoNewline
        Write-Host "$statusText " -ForegroundColor $color -NoNewline
        Write-Host "-> HTTP: $hPort, DB: $dPort, Redis: $rPort"
    }
}

function Deploy-Instance {
    param($EnvName, $CleanData = $false)
    Write-Host "`n>>> Orchestrating environment: $EnvName" -ForegroundColor Cyan

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $existing = docker ps -a -f name=$creatioCont --format "{{.Names}}"

    $httpPort = 0
    $dbPort = 0

    if ($existing) {
        $hPortStr = Get-ContainerPort $creatioCont 5000
        $dPortStr = Get-ContainerPort "postgres17-creatio-$EnvName" 5432

        if ($hPortStr -ne "N/A") { $httpPort = [int]$hPortStr }
        if ($dPortStr -ne "N/A") { $dbPort = [int]$dPortStr }
    }

    if ($httpPort -eq 0 -or $dbPort -eq 0) {
        $usedPortsRaw = docker ps -a --format "{{.Ports}}"
        $usedPorts = @()
        if ($usedPortsRaw) {
            $usedPorts = $usedPortsRaw | ForEach-Object { [regex]::Matches($_, '(?<=:)\d+(?=->)') } | ForEach-Object { [int]$_.Value }
        }

        $httpPort = $GlobalConfig.BaseHttpPort
        while ($usedPorts -contains $httpPort -or $usedPorts -contains ($httpPort + 1)) { $httpPort += 10 }

        $dbPort = $GlobalConfig.BaseDbPort
        while ($usedPorts -contains $dbPort) { $dbPort += 10 }
    }

    $envPath = Join-Path $GlobalConfig.Paths.Runtime $EnvName
    if ($CleanData -and (Test-Path $envPath)) { Remove-Item -Recurse -Force $envPath -ErrorAction SilentlyContinue }
    if (-not (Test-Path $envPath)) { New-Item -ItemType Directory -Force -Path $envPath | Out-Null }
    if (-not (Test-Path "$envPath/Logs")) { New-Item -ItemType Directory -Force -Path "$envPath/Logs" | Out-Null }
    if (-not (Test-Path "$envPath/Terrasoft.Configuration")) { New-Item -ItemType Directory -Force -Path "$envPath/Terrasoft.Configuration" | Out-Null }

    $creatioDir = $GlobalConfig.Paths.Creatio
    $destWebConfig = Join-Path $envPath "Terrasoft.WebHost.dll.config"
    $destConnStrings = Join-Path $envPath "ConnectionStrings.config"

    $sourceWebConfig = Get-ChildItem -Path $creatioDir -Filter "Terrasoft.WebHost.dll.config" -Recurse | Select-Object -First 1
    if ($sourceWebConfig) {
        Copy-Item -Path $sourceWebConfig.FullName -Destination $destWebConfig -Force
        (Get-Content $destWebConfig) -replace '(<add key="CookiesSameSiteMode" value=)"None"', '$1"Lax"' | Set-Content $destWebConfig
    }

    $templatePath = Join-Path $PSScriptRoot "ConnectionStrings.config.template"
    if (Test-Path $templatePath) {
        (Get-Content $templatePath -Raw) -replace '{{ENV}}', $EnvName | Set-Content $destConnStrings
    } else {
        Write-Warning "Template $templatePath not found!"
    }

    if ((Get-ChildItem -Path "$envPath/Terrasoft.Configuration" -Force | Measure-Object).Count -eq 0) {
        Write-Host "Copying Terrasoft.Configuration (this may take a while)..." -ForegroundColor Gray
        $sourceConfigDir = Get-ChildItem -Path $creatioDir -Directory -Filter "Terrasoft.Configuration" -Recurse | Select-Object -First 1
        if ($sourceConfigDir) {
            robocopy $sourceConfigDir.FullName "$envPath/Terrasoft.Configuration" /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        }
    }

    $env:ENV_ID = $EnvName
    $env:DB_PORT = $dbPort
    $env:REDIS_PORT = $dbPort + 100
    $env:HTTP_PORT = $httpPort
    $env:HTTPS_PORT = $httpPort + 1

    docker compose -p "creatio-$EnvName" -f "docker-compose.yml" up -d --build

    $containerDb = "postgres17-creatio-$EnvName"
    Write-Host "Waiting for DB..." -ForegroundColor Gray
    while ($(docker inspect --format='{{.State.Health.Status}}' $containerDb 2>$null) -ne "healthy") { Start-Sleep -Seconds 2 }

    docker cp $GlobalConfig.Paths.Backup "${containerDb}:/tmp/restore.backup"
    docker exec $containerDb pg_restore -U app -d app --no-owner --no-privileges /tmp/restore.backup 2>$null

    Reset-SupervisorPassword $EnvName

    Remove-Item Env:ENV_ID, Env:DB_PORT, Env:REDIS_PORT, Env:HTTP_PORT, Env:HTTPS_PORT -ErrorAction SilentlyContinue
}

function Sync-ClioConfig {
    Write-Host "`n>>> Synchronizing Clio environments config..." -ForegroundColor Cyan
    $envs = Get-DeployedEnvs
    if ($envs.Count -eq 0) {
        Write-Warning "No environments found. Clio config will be empty."
    }

    $environments = @()
    foreach ($e in $envs) {
        $creatioCont = "$($GlobalConfig.Prefix)$e"
        $httpPort = Get-ContainerPort $creatioCont 5000

        if ($httpPort -eq "N/A") { continue }

        $environments += @{
            Name = $e
            Uri = "http://localhost:$httpPort"
            Maintainer = "Supervisor"
            Password = "Supervisor"
            IsNetCore = $true
            Safe = $true
        }
    }

    $clioConfig = @{ Environments = $environments }
    $json = $clioConfig | ConvertTo-Json -Depth 5
    Set-Content -Path $GlobalConfig.Paths.ClioConfig -Value $json -Encoding UTF8
    Write-Host "Clio config generated at: $($GlobalConfig.Paths.ClioConfig)" -ForegroundColor Green
}

function Install-ClioGate {
    param($EnvName)
    Write-Host "`n>>> Installing ClioGate for environment: $EnvName" -ForegroundColor Cyan
    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $httpPort = Get-ContainerPort $creatioCont 5000

    if ($httpPort -eq "N/A") {
        Write-Warning "Cannot find running environment '$EnvName'. Is it started?"
        return
    }

    $uri = "http://localhost:$httpPort"
    clio install-gate -u $uri -p "Supervisor" -l "Supervisor"

    if ($LASTEXITCODE -eq 0) { Write-Host "ClioGate installed successfully on $EnvName!" -ForegroundColor Green }
    else { Write-Host "Failed to install ClioGate on $EnvName. Exit code: $LASTEXITCODE" -ForegroundColor Red }
}

function Enable-FsdMode {
    param($EnvName)
    Write-Host "`n>>> Enabling File System Development Mode for environment: $EnvName" -ForegroundColor Cyan

    $envPath = Join-Path $GlobalConfig.Paths.Runtime $EnvName
    $webConfigPath = Join-Path $envPath "Terrasoft.WebHost.dll.config"

    if (-not (Test-Path $webConfigPath)) {
        Write-Error "Configuration file not found at $webConfigPath. Is the environment deployed?"
        return
    }

    $xml = [xml](Get-Content $webConfigPath)

    $terrasoftNode = $xml.configuration.terrasoft
    if ($null -eq $terrasoftNode) {
        $terrasoftNode = $xml.CreateElement("terrasoft")
        $xml.configuration.AppendChild($terrasoftNode) | Out-Null
    }

    $fileDesignMode = $terrasoftNode.fileDesignMode
    if ($null -eq $fileDesignMode) {
        $fileDesignMode = $xml.CreateElement("fileDesignMode")
        $terrasoftNode.AppendChild($fileDesignMode) | Out-Null
    }
    $fileDesignMode.SetAttribute("enabled", "true")

    $appSettings = $xml.configuration.appSettings
    if ($null -ne $appSettings) {
        $staticFileNode = $appSettings.add | Where-Object { $_.key -eq "UseStaticFileContent" }
        if ($null -eq $staticFileNode) {
            $staticFileNode = $xml.CreateElement("add")
            $staticFileNode.SetAttribute("key", "UseStaticFileContent")
            $staticFileNode.SetAttribute("value", "false")
            $appSettings.AppendChild($staticFileNode) | Out-Null
        } else {
            $staticFileNode.SetAttribute("value", "false")
        }
    }

    $xml.Save($webConfigPath)
    Write-Host "Config updated at $webConfigPath" -ForegroundColor Green

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    Write-Host "Restarting container $creatioCont..." -ForegroundColor Gray
    docker compose -p "creatio-$EnvName" restart creatio

    Write-Host "FSD Mode enabled! Please log in to Creatio again." -ForegroundColor Green
}

function Restart-Environment {
    param($EnvName)
    Write-Host "`n>>> Restarting environment: $EnvName" -ForegroundColor Cyan
    $projectName = "creatio-$EnvName"
    docker compose -p $projectName restart creatio
    Write-Host "Restart completed for $EnvName!" -ForegroundColor Green
}

function Rebuild-Image {
    param($EnvName)
    Write-Host "`n>>> Rebuilding creatio image (--no-cache) for: $EnvName" -ForegroundColor Cyan

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $existing = docker ps -a -f name=$creatioCont --format "{{.Names}}"

    $httpPort = 0
    $dbPort = 0

    if ($existing) {
        $hPortStr = Get-ContainerPort $creatioCont 5000
        $dPortStr = Get-ContainerPort "postgres17-creatio-$EnvName" 5432

        if ($hPortStr -ne "N/A") { $httpPort = [int]$hPortStr }
        if ($dPortStr -ne "N/A") { $dbPort = [int]$dPortStr }
    }

    if ($httpPort -eq 0 -or $dbPort -eq 0) {
        Write-Error "Cannot determine ports for $EnvName. Please run 'deploy' first."
        return
    }

    $env:ENV_ID = $EnvName
    $env:DB_PORT = $dbPort
    $env:REDIS_PORT = $dbPort + 100
    $env:HTTP_PORT = $httpPort
    $env:HTTPS_PORT = $httpPort + 1

    $projectName = "creatio-$EnvName"
    $composeFile = "docker-compose.yml"

    Write-Host "Stopping and removing containers for $projectName..." -ForegroundColor Gray
    docker compose -p $projectName -f $composeFile down

    Write-Host "Building creatio image (--no-cache --pull)..." -ForegroundColor Gray
    docker compose -p $projectName -f $composeFile build --no-cache --pull creatio

    Write-Host "Starting creatio container (--force-recreate)..." -ForegroundColor Gray
    docker compose -p $projectName -f $composeFile up -d --force-recreate creatio

    Remove-Item Env:ENV_ID, Env:DB_PORT, Env:REDIS_PORT, Env:HTTP_PORT, Env:HTTPS_PORT -ErrorAction SilentlyContinue
    Write-Host "Image rebuild completed for $EnvName!" -ForegroundColor Green
}

function Uninstall-Package {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvName,

        [Parameter(Mandatory=$true)]
        [string]$PackageName
    )

    Write-Host "`n>>> Force Uninstalling Package [$PackageName] from: $EnvName" -ForegroundColor Cyan

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $httpPort = Get-ContainerPort $creatioCont 5000

    if ($httpPort -eq "N/A") {
        Write-Error "Cannot determine HTTP port for $EnvName."
        return
    }

    $uri = "http://localhost:$httpPort"

    Write-Host "Using uninstall-app-remote to bypass archive lock..." -ForegroundColor Yellow
    # Эта команда более "агрессивна" и удалит пакет, даже если он из архива
    clio uninstall-app-remote "$PackageName" -u $uri -p "Supervisor" -l "Supervisor"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Package '$PackageName' removed successfully from $EnvName!" -ForegroundColor Green
    } else {
        Write-Host "Failed to uninstall package. Exit code: $LASTEXITCODE" -ForegroundColor Red
    }
}

function Uninstall-Application {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvName,

        [Parameter(Mandatory=$true)]
        [string]$ApplicationCode
    )

    Write-Host "`n>>> Uninstalling Application [$ApplicationCode] from: $EnvName" -ForegroundColor Cyan

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $httpPort = Get-ContainerPort $creatioCont 5000

    if ($httpPort -eq "N/A") {
        Write-Error "Cannot determine HTTP port."
        return
    }

    $uri = "http://localhost:$httpPort"

    # Используем проверенную команду из вашего лога
    clio uninstall-app-remote "$ApplicationCode" -u $uri -p "Supervisor" -l "Supervisor"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Application '$ApplicationCode' uninstalled successfully!" -ForegroundColor Green
    } else {
        Write-Host "Failed. Exit code: $LASTEXITCODE" -ForegroundColor Red
    }
}

function Install-Package {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvName,

        [Parameter(Mandatory=$true)]
        [string]$ZipFilePath
    )

    Write-Host "`n>>> Installing Package from zip to: $EnvName" -ForegroundColor Cyan

    if (-not (Test-Path $ZipFilePath)) {
        Write-Error "File not found: $ZipFilePath"
        return
    }

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $httpPort = Get-ContainerPort $creatioCont 5000

    if ($httpPort -eq "N/A") {
        Write-Error "Cannot determine HTTP port for $EnvName. Is it running?"
        return
    }

    $uri = "http://localhost:$httpPort"
    Write-Host "Target URI: $uri" -ForegroundColor Gray
    Write-Host "Package File: $ZipFilePath" -ForegroundColor Gray

    if (-not (Get-Command clio -ErrorAction SilentlyContinue)) {
        Write-Error "Clio tool is not installed or not in PATH."
        return
    }

    Write-Host "Pushing package via clio (push-pkg)..." -ForegroundColor Yellow
    clio push-pkg "$ZipFilePath" -u $uri -p "Supervisor" -l "Supervisor"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Package installed successfully on $EnvName!" -ForegroundColor Green
    } else {
        Write-Host "Failed to install package on $EnvName. Exit code: $LASTEXITCODE" -ForegroundColor Red
    }
}

function Install-Application {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvName,

        [Parameter(Mandatory=$true)]
        [string]$ZipFilePath
    )

    Write-Host "`n>>> Installing Application from zip to: $EnvName" -ForegroundColor Cyan

    if (-not (Test-Path $ZipFilePath)) {
        Write-Error "File not found: $ZipFilePath"
        return
    }

    $creatioCont = "$($GlobalConfig.Prefix)$EnvName"
    $httpPort = Get-ContainerPort $creatioCont 5000

    if ($httpPort -eq "N/A") {
        Write-Error "Cannot determine HTTP port for $EnvName. Is it running?"
        return
    }

    $uri = "http://localhost:$httpPort"
    Write-Host "Target URI: $uri" -ForegroundColor Gray
    Write-Host "Application File: $ZipFilePath" -ForegroundColor Gray

    if (-not (Get-Command clio -ErrorAction SilentlyContinue)) {
        Write-Error "Clio tool is not installed or not in PATH."
        return
    }

    Write-Host "Pushing application via clio (push-app)..." -ForegroundColor Yellow
    clio push-app "$ZipFilePath" -u $uri -p "Supervisor" -l "Supervisor"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Application installed successfully on $EnvName!" -ForegroundColor Green
    } else {
        Write-Host "Failed to install application on $EnvName. Exit code: $LASTEXITCODE" -ForegroundColor Red
    }
}

# --- 3. CLI Logic ---

$Cmd = $args[0]
$Target = $args[1]

switch ($Cmd) {
    "status" { Show-Status }
    "reset-password" {
        if (-not $Target) { Write-Error "Name required"; break }
        Reset-SupervisorPassword $Target
    }
    "clean" {
        if (-not $Target) {
            Write-Error "Target environment name required (use 'all' to remove everything)"
            break
        }

        if ($Target -eq "all") {
            Write-Host ">>> Cleaning ALL environments..." -ForegroundColor Red
            $envs = Get-DeployedEnvs
            foreach ($e in $envs) { docker compose -p "creatio-$e" down -v }
            if (Test-Path $GlobalConfig.Paths.Runtime) { Remove-Item -Recurse -Force $GlobalConfig.Paths.Runtime }
        } else {
            Write-Host ">>> Cleaning environment: $Target..." -ForegroundColor Yellow
            docker compose -p "creatio-$Target" down -v
            $envPath = Join-Path $GlobalConfig.Paths.Runtime $Target
            if (Test-Path $envPath) { Remove-Item -Recurse -Force $envPath }
        }
    }
    "deploy" {
        if (-not $Target) { Write-Error "Name required"; break }
        Deploy-Instance $Target $false
        Sync-ClioConfig
    }
    "reset-all" {
        $envs = Get-DeployedEnvs
        if ($envs.Count -eq 0) {
            Write-Host "No existing environments found. Defaulting to dev1 and dev2." -ForegroundColor Yellow
            $envs = @("dev1", "dev2")
        }
        foreach ($e in $envs) { Deploy-Instance $e $true }
        Sync-ClioConfig
    }
    "restart" {
        if (-not $Target) { Write-Error "Target environment name required"; break }
        Restart-Environment $Target
    }
    "rebuild-image" {
        if (-not $Target) { Write-Error "Target environment name required"; break }
        Rebuild-Image $Target
    }
    "sync-clio" {
        Sync-ClioConfig
    }
    "install-gate" {
        if (-not $Target) { Write-Error "Target environment name required (or 'all')"; break }
        if ($Target -eq "all") {
            $envs = Get-DeployedEnvs
            foreach ($e in $envs) { Install-ClioGate $e }
        } else {
            Install-ClioGate $Target
        }
    }
    "install-pkg" {
        $zipPath = $args[2]
        if (-not $Target) { Write-Error "Target environment name required"; break }
        if (-not $zipPath) { Write-Error "Zip file path required as third argument"; break }
        Install-Package -EnvName $Target -ZipFilePath $zipPath
    }
    "install-app" {
        $zipPath = $args[2]
        if (-not $Target) { Write-Error "Target environment name required"; break }
        if (-not $zipPath) { Write-Error "Zip file path required as third argument"; break }
        Install-Application -EnvName $Target -ZipFilePath $zipPath
    }
    "uninstall-pkg" {
        $pkgName = $args[2]
        if (-not $Target) { Write-Error "Target environment name required"; break }
        if (-not $pkgName) { Write-Error "Package name required as third argument"; break }
        Uninstall-Package -EnvName $Target -PackageName $pkgName
    }
    "uninstall-app" {
        $appCode = $args[2]
        if (-not $Target) { Write-Error "Target environment name required"; break }
        if (-not $appCode) { Write-Error "Application code required as third argument"; break }
        Uninstall-Application -EnvName $Target -ApplicationCode $appCode
    }
    "enable-fsd" {
        if (-not $Target) { Write-Error "Target environment name required"; break }
        Enable-FsdMode $Target
    }
    Default { Show-Status }
}