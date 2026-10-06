<#
.SYNOPSIS
  Genera locuciones (WAV) de una audioguía a partir de la exportación JSON de su CMS.

.DESCRIPTION
  La app de audioguías guarda los textos normalizados: cada monumento, ruta o waypoint apunta a
  un id_text y las traducciones viven aparte (id_text + id_language). Este script reconstruye
  el texto de cada elemento en el idioma pedido y lo sintetiza con las voces de Windows
  (System.Speech). Sirve para prototipar o rellenar huecos antes de grabar con locutor.

  Salida: <OutDir>/<idioma>/<tipo>/<id>/<campo>.wav

.EXAMPLE
  .\New-AudioguideTts.ps1 -ExportPath .\export.json -Language es,en -OutDir .\tts
  .\New-AudioguideTts.ps1 -ExportPath .\export.json -Language fr -WhatIf   # solo muestra qué generaría
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ExportPath,

    [ValidateSet('es', 'en', 'fr', 'it', 'de', 'pt')]
    [string[]]$Language = @('es'),

    [string]$OutDir = (Join-Path (Get-Location) 'tts'),

    # Fuerza la regeneración aunque el WAV ya exista
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# id_language del CMS → código de idioma y cultura de la voz
$script:Languages = @{
    1 = @{ Code = 'es'; Culture = 'es-ES' }
    2 = @{ Code = 'en'; Culture = 'en-US' }
    3 = @{ Code = 'fr'; Culture = 'fr-FR' }
    4 = @{ Code = 'it'; Culture = 'it-IT' }
    5 = @{ Code = 'de'; Culture = 'de-DE' }
    6 = @{ Code = 'pt'; Culture = 'pt-PT' }
}

$script:Collections = @(
    @{ Key = 'monuments_texts'; Type = 'monuments'; IdField = 'id_monument' }
    @{ Key = 'routes_texts'; Type = 'routes'; IdField = 'id_route' }
    @{ Key = 'waypoints_texts'; Type = 'waypoints'; IdField = 'id_waypoint' }
)

function Get-LanguageId {
    param([Parameter(Mandatory)][string]$Code)
    foreach ($k in $script:Languages.Keys) { if ($script:Languages[$k].Code -eq $Code) { return [int]$k } }
    throw "Idioma no soportado: $Code"
}

<# Índice de traducciones: idioma → id_text → texto. Función pura. #>
function New-TranslationIndex {
    param([Parameter(Mandatory)]$Translations)
    $index = @{}
    foreach ($t in $Translations) {
        $lang = [int]$t.id_language
        if (-not $index.ContainsKey($lang)) { $index[$lang] = @{} }
        if ($t.text) { $index[$lang][[int]$t.id_text] = [string]$t.text }
    }
    return $index
}

<#
  Lista de locuciones a generar para un idioma: { Type, Id, Field, Text, RelativePath }.
  Los textos sin traducción en ese idioma se omiten (y se informan). Función pura.
#>
function Get-AudioguideItems {
    param(
        [Parameter(Mandatory)]$Values,
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][int]$LanguageId
    )
    $code = $script:Languages[$LanguageId].Code
    $texts = if ($Index.ContainsKey($LanguageId)) { $Index[$LanguageId] } else { @{} }

    foreach ($c in $script:Collections) {
        if (-not ($Values.PSObject.Properties.Name -contains $c.Key)) { continue }
        foreach ($item in $Values.($c.Key)) {
            foreach ($field in 'title', 'description') {
                if (-not ($item.PSObject.Properties.Name -contains $field) -or -not $item.$field) { continue }
                $textId = [int]$item.$field
                $id = $item.($c.IdField)
                if ($texts.ContainsKey($textId)) {
                    [pscustomobject]@{
                        Type         = $c.Type
                        Id           = $id
                        Field        = $field
                        Text         = $texts[$textId]
                        RelativePath = Join-Path $code (Join-Path $c.Type (Join-Path $id "$field.wav"))
                    }
                } else {
                    Write-Warning "[$code] sin traducción: $($c.Type)/$id/$field (id_text $textId)"
                }
            }
        }
    }
}

function Save-Speech {
    param([string]$Text, [string]$Path, [string]$Culture)
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $voice = $synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -eq $Culture } | Select-Object -First 1
        if ($voice) { $synth.SelectVoice($voice.VoiceInfo.Name) } else { Write-Warning "Sin voz $Culture instalada: se usa la predeterminada" }
        New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
        $synth.SetOutputToWaveFile($Path)
        $synth.Speak($Text)
    } finally {
        $synth.Dispose()
    }
}

function Invoke-AudioguideTts {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $export = Get-Content -LiteralPath $ExportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $values = $export.responseInformation.values[0]
    $index = New-TranslationIndex $values.translations

    foreach ($code in $Language) {
        $langId = Get-LanguageId $code
        $items = @(Get-AudioguideItems -Values $values -Index $index -LanguageId $langId)
        $done = 0
        foreach ($it in $items) {
            $path = Join-Path $OutDir $it.RelativePath
            if ((Test-Path $path) -and -not $Force) { continue }
            if ($PSCmdlet.ShouldProcess($path, "Sintetizar ($($it.Text.Length) caracteres)")) {
                Save-Speech -Text $it.Text -Path $path -Culture $script:Languages[$langId].Culture
                $done++
            }
        }
        Write-Host "[$code] $done locuciones generadas de $($items.Count)"
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-AudioguideTts }
