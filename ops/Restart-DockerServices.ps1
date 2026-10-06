<#
.SYNOPSIS
  Reinicia los servicios Docker de varios servidores por SSH, en orden, y se detiene en el primer fallo.

.DESCRIPTION
  Sustituye a un script con IPs, rutas y nombre de clave escritos en el código: los servidores
  se definen en un JSON (fuera del repo) y la clave SSH se toma del agente o de ~/.ssh/config.

  hosts.json:
  [
    { "name": "web",    "host": "deploy@web.example.com",    "dir": "~/app", "script": "./restart-docker-services.prod.sh" },
    { "name": "worker", "host": "deploy@worker.example.com", "dir": "~/app", "script": "./restart-docker-services.celery.sh" }
  ]

.EXAMPLE
  .\Restart-DockerServices.ps1 -HostsFile .\hosts.json
  .\Restart-DockerServices.ps1 -HostsFile .\hosts.json -Only worker -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$HostsFile,

    [string[]]$Only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RestartTargets {
    param([Parameter(Mandatory)][string]$Json, [string[]]$Only)
    # En PowerShell 5.1 ConvertFrom-Json devuelve un array JSON como un único objeto: se enumera explícitamente
    $targets = @(($Json | ConvertFrom-Json) | ForEach-Object { $_ })
    foreach ($t in $targets) {
        foreach ($field in 'name', 'host', 'dir', 'script') {
            if (-not ($t.PSObject.Properties.Name -contains $field) -or -not $t.$field) { throw "Servidor sin '$field' en la configuración" }
        }
        # Evita inyección de comandos en la línea remota
        if ($t.dir -notmatch '^[\w~./-]+$' -or $t.script -notmatch '^[\w./-]+$') { throw "Ruta no válida en '$($t.name)'" }
    }
    if ($Only) { $targets = @($targets | Where-Object { $Only -contains $_.name }) }
    return $targets
}

function Invoke-ServiceRestart {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $targets = @(Get-RestartTargets -Json (Get-Content -LiteralPath $HostsFile -Raw) -Only $Only)
    $restarted = 0
    foreach ($t in $targets) {
        if (-not $PSCmdlet.ShouldProcess($t.host, "Ejecutar $($t.script)")) { continue }
        Write-Host "==> $($t.name) ($($t.host))" -ForegroundColor Cyan
        & ssh -o BatchMode=yes -o ConnectTimeout=15 $t.host "cd $($t.dir) && $($t.script)"
        if ($LASTEXITCODE -ne 0) { throw "Falló el reinicio en '$($t.name)' (exit $LASTEXITCODE): se detiene la secuencia" }
        $restarted++
    }
    Write-Host "Servicios reiniciados: $restarted de $($targets.Count)" -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-ServiceRestart }
