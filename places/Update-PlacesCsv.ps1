<#
.SYNOPSIS
  Enriquece un CSV de puntos de encuentro con los datos de Google Places (API v1) en el formato
  `place_info` que exige el feed de Google Things To Do.

.DESCRIPTION
  Para cada fila lee uno o varios Place IDs (separados por saltos de línea dentro de la celda),
  consulta Places API (New) y escribe en la columna de salida un JSON por lugar con nombre,
  teléfono, web, coordenadas y dirección estructurada.

  - Pide solo los campos necesarios (FieldMask): Places factura por campos solicitados.
  - Un fallo en un lugar no detiene el proceso: se escribe {"error": "..."} en su línea.
  - Lee la API key de -ApiKey o de la variable de entorno GOOGLE_PLACES_API_KEY.

.EXAMPLE
  $env:GOOGLE_PLACES_API_KEY = '...'
  .\Update-PlacesCsv.ps1 -CsvPath .\meeting-points.csv -IdColumn 1 -OutputColumn 5 -Verbose
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$ApiKey = $env:GOOGLE_PLACES_API_KEY,

    # Índices de columna (0 = A)
    [int]$IdColumn = 1,
    [int]$OutputColumn = 5,

    [string]$BaseUrl = 'https://places.googleapis.com/v1/places',

    # La primera fila son datos, no cabecera
    [switch]$NoHeader,

    # Pausa entre llamadas para no superar la cuota por minuto
    [int]$DelayMs = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FieldMask = 'displayName,internationalPhoneNumber,nationalPhoneNumber,websiteUri,location,addressComponents'

function Get-AddressComponent {
    param($Components, [string]$Type, [ValidateSet('longText', 'shortText')][string]$Form = 'longText')
    if (-not $Components) { return '' }
    $match = $Components | Where-Object { $_.types -contains $Type } | Select-Object -First 1
    if ($match -and $match.PSObject.Properties.Name -contains $Form) { return [string]$match.$Form }
    return ''
}

function Get-StreetAddress {
    param($Components)
    $route = Get-AddressComponent $Components 'route'
    $number = Get-AddressComponent $Components 'street_number'
    if ($route -and $number) { return "$route, $number" }
    if ($route) { return $route }
    $sub = Get-AddressComponent $Components 'sublocality'
    if (-not $sub) { $sub = Get-AddressComponent $Components 'sublocality_level_1' }
    return $sub
}

function Get-FirstNonEmpty {
    foreach ($v in $args) { if ($v) { return $v } }
    return ''
}

<#
  Convierte la respuesta de Places API en el bloque place_info del feed de Things To Do.
  Función pura: se testea sin red.
#>
function ConvertTo-PlaceInfo {
    param([Parameter(Mandatory)]$Place)

    $comps = $null
    if ($Place.PSObject.Properties.Name -contains 'addressComponents') { $comps = $Place.addressComponents }

    $name = ''
    if ($Place.PSObject.Properties.Name -contains 'displayName' -and $Place.displayName) { $name = $Place.displayName.text }

    $props = $Place.PSObject.Properties.Name
    $phone = Get-FirstNonEmpty $(if ($props -contains 'internationalPhoneNumber') { $Place.internationalPhoneNumber }) `
                            $(if ($props -contains 'nationalPhoneNumber') { $Place.nationalPhoneNumber })
    $web = Get-FirstNonEmpty $(if ($props -contains 'websiteUri') { $Place.websiteUri })

    $coords = $null
    if ($props -contains 'location' -and $Place.location) {
        $coords = [ordered]@{ latitude = [double]$Place.location.latitude; longitude = [double]$Place.location.longitude }
    }

    [ordered]@{
        location = [ordered]@{
            place_info = [ordered]@{
                name               = $name
                phone_number       = $phone
                website_url        = $web
                coordinates        = $coords
                structured_address = [ordered]@{
                    street_address      = Get-StreetAddress $comps
                    locality            = Get-AddressComponent $comps 'locality'
                    administrative_area = Get-FirstNonEmpty (Get-AddressComponent $comps 'administrative_area_level_2' 'shortText') `
                                                         (Get-AddressComponent $comps 'administrative_area_level_1' 'shortText')
                    postal_code         = Get-AddressComponent $comps 'postal_code'
                    country_code        = Get-AddressComponent $comps 'country' 'shortText'
                }
            }
        }
    }
}

function Get-PlaceDetails {
    param([Parameter(Mandatory)][string]$PlaceId)
    $headers = @{ 'X-Goog-Api-Key' = $ApiKey; 'X-Goog-FieldMask' = $script:FieldMask }
    Invoke-RestMethod -Method Get -Uri "$BaseUrl/$([uri]::EscapeDataString($PlaceId))" -Headers $headers
}

function Split-PlaceIds {
    param([string]$Cell)
    if (-not $Cell) { return @() }
    return @($Cell -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Read-CsvRows {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path, [Text.Encoding]::UTF8)
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true
    $rows = New-Object System.Collections.Generic.List[string[]]
    try {
        while (-not $parser.EndOfData) { $rows.Add([string[]]$parser.ReadFields()) }
    } finally { $parser.Close() }
    return , $rows
}

function ConvertTo-CsvLine {
    param([string[]]$Cells)
    ($Cells | ForEach-Object {
        $s = [string]$_ -replace '"', '""'
        if ($s -match '[,"\r\n]') { '"' + $s + '"' } else { $s }
    }) -join ','
}

function Invoke-PlacesUpdate {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $ApiKey) { throw 'Falta la API key: usa -ApiKey o $env:GOOGLE_PLACES_API_KEY' }
    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "No existe el CSV: $CsvPath" }

    $rows = Read-CsvRows -Path $CsvPath
    $ok = 0; $failed = 0

    $first = if ($NoHeader) { 0 } else { 1 }
    for ($i = $first; $i -lt $rows.Count; $i++) {
        $row = [System.Collections.Generic.List[string]]$rows[$i]
        while ($row.Count -le $OutputColumn) { $row.Add('') }

        $ids = @(Split-PlaceIds $row[$IdColumn])
        if ($ids.Count -eq 0) { continue }

        $lines = foreach ($id in $ids) {
            try {
                Write-Verbose "[$($i + 1)/$($rows.Count)] $id"
                $json = ConvertTo-PlaceInfo (Get-PlaceDetails -PlaceId $id) | ConvertTo-Json -Depth 10 -Compress
                $ok++
                $json
            } catch {
                $failed++
                @{ placeId = $id; error = $_.Exception.Message } | ConvertTo-Json -Compress
            }
            Start-Sleep -Milliseconds $DelayMs
        }
        $row[$OutputColumn] = ($lines -join "`n")
        $rows[$i] = $row.ToArray()
    }

    if ($PSCmdlet.ShouldProcess($CsvPath, 'Sobrescribir con los datos de Places')) {
        $content = ($rows | ForEach-Object { ConvertTo-CsvLine $_ }) -join "`r`n"
        [IO.File]::WriteAllText((Resolve-Path -LiteralPath $CsvPath), $content + "`r`n", (New-Object Text.UTF8Encoding($false)))
    }
    Write-Host "Lugares OK: $ok · con error: $failed"
}

# Al hacer dot-source (tests) solo se cargan las funciones
if ($MyInvocation.InvocationName -ne '.') { Invoke-PlacesUpdate }
