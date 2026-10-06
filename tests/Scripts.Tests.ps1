#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot
    . (Join-Path $root 'places/Update-PlacesCsv.ps1') -CsvPath 'unused.csv' -ApiKey 'x'
    . (Join-Path $root 'audioguides/New-AudioguideTts.ps1') -ExportPath 'unused.json'
    . (Join-Path $root 'ops/Restart-DockerServices.ps1') -HostsFile 'unused.json'
}

Describe 'ConvertTo-PlaceInfo' {
    BeforeAll {
        $place = Get-Content (Join-Path $PSScriptRoot 'fixtures/place.json') -Raw | ConvertFrom-Json
        $info = (ConvertTo-PlaceInfo $place).location.place_info
    }

    It 'mapea nombre, teléfono internacional y web' {
        $info.name | Should -Be 'Puerta del Museo Demo'
        $info.phone_number | Should -Be '+34 910 00 00 00'
        $info.website_url | Should -Be 'https://museo.example.com/'
    }

    It 'construye la dirección "calle, número" y usa códigos cortos de provincia y país' {
        $addr = $info.structured_address
        $addr.street_address | Should -Be 'Calle Mayor, 1'
        $addr.locality | Should -Be 'Madrid'
        $addr.administrative_area | Should -Be 'M'
        $addr.postal_code | Should -Be '28013'
        $addr.country_code | Should -Be 'ES'
    }

    It 'conserva las coordenadas como números' {
        $info.coordinates.latitude | Should -BeOfType [double]
        $info.coordinates.latitude | Should -Be 40.4168
    }

    It 'tolera lugares incompletos (sin teléfono, sin número ni coordenadas)' {
        $partial = [pscustomobject]@{
            displayName       = @{ text = 'Plaza' }
            nationalPhoneNumber = '910 000 000'
            addressComponents = @(
                [pscustomobject]@{ types = @('sublocality'); longText = 'Centro'; shortText = 'Centro' },
                [pscustomobject]@{ types = @('administrative_area_level_1'); longText = 'Comunidad de Madrid'; shortText = 'MD' }
            )
        }
        $p = (ConvertTo-PlaceInfo $partial).location.place_info
        $p.phone_number | Should -Be '910 000 000'
        $p.structured_address.street_address | Should -Be 'Centro'
        $p.structured_address.administrative_area | Should -Be 'MD'
        $p.coordinates | Should -BeNullOrEmpty
    }

    It 'serializa a una sola línea JSON' {
        $json = ConvertTo-PlaceInfo $place | ConvertTo-Json -Depth 10 -Compress
        $json | Should -Not -Match "`n"
        ($json | ConvertFrom-Json).location.place_info.name | Should -Be 'Puerta del Museo Demo'
    }
}

Describe 'Update-PlacesCsv · flujo completo' {
    It 'rellena la columna de salida, un JSON por ID, y registra los errores sin parar' {
        $place = Get-Content (Join-Path $PSScriptRoot 'fixtures/place.json') -Raw | ConvertFrom-Json
        Mock Get-PlaceDetails { if ($PlaceId -eq 'BAD') { throw 'HTTP 404 Not Found' }; $place }

        $CsvPath = Join-Path $TestDrive 'points.csv'
        $NoHeader = $false
        $DelayMs = 0
        $lines = @('Tour,Place IDs,c,d,e,place_info', "Tour A,`"OK1`nBAD`",,,,", 'Tour B,,,,,', '"Tour, con coma",OK2')
        [IO.File]::WriteAllText($CsvPath, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

        Invoke-PlacesUpdate *> $null

        $rows = Read-CsvRows $CsvPath
        $rows.Count | Should -Be 4
        $out = $rows[1][5] -split "`n"
        $out.Count | Should -Be 2
        ($out[0] | ConvertFrom-Json).location.place_info.name | Should -Be 'Puerta del Museo Demo'
        ($out[1] | ConvertFrom-Json).error | Should -Match '404'
        $rows[2][5] | Should -BeNullOrEmpty
        $rows[3][0] | Should -Be 'Tour, con coma'
        $rows[3].Count | Should -Be 6
        Should -Invoke Get-PlaceDetails -Times 3 -Exactly
    }
}

Describe 'Split-PlaceIds / CSV' {
    It 'separa varios IDs por línea e ignora vacíos' {
        Split-PlaceIds "ChIJ1`r`n`n ChIJ2 " | Should -Be @('ChIJ1', 'ChIJ2')
        @(Split-PlaceIds '').Count | Should -Be 0
    }

    It 'escapa comas, comillas y saltos de línea' {
        ConvertTo-CsvLine @('a', 'b,c', 'di "x"', "l1`nl2") | Should -Be "a,`"b,c`",`"di `"`"x`"`"`",`"l1`nl2`""
    }
}

Describe 'Audioguías' {
    BeforeAll {
        $values = (Get-Content (Join-Path $PSScriptRoot 'fixtures/audioguide-export.json') -Raw | ConvertFrom-Json).responseInformation.values[0]
        $index = New-TranslationIndex $values.translations
    }

    It 'indexa traducciones por idioma e id_text' {
        $index[1][100] | Should -Be 'Museo Demo'
        $index[2][100] | Should -Be 'Demo Museum'
    }

    It 'genera una locución por elemento y campo traducido' {
        $items = @(Get-AudioguideItems -Values $values -Index $index -LanguageId 1 -WarningAction SilentlyContinue)
        $items.Count | Should -Be 4
        ($items | Where-Object { $_.Type -eq 'waypoints' -and $_.Field -eq 'description' }).Text | Should -Be 'Entrada principal del museo.'
        $items[0].RelativePath | Should -Be (Join-Path 'es' (Join-Path 'monuments' (Join-Path '7' 'title.wav')))
    }

    It 'omite (y avisa de) los textos sin traducción' {
        $items = @(Get-AudioguideItems -Values $values -Index $index -LanguageId 2 -WarningVariable w -WarningAction SilentlyContinue)
        $items.Count | Should -Be 2
        $w.Count | Should -Be 2
    }

    It 'resuelve códigos de idioma' {
        Get-LanguageId 'fr' | Should -Be 3
        { Get-LanguageId 'xx' } | Should -Throw
    }
}

Describe 'Get-RestartTargets' {
    It 'filtra por nombre' {
        $json = '[{"name":"web","host":"d@web","dir":"~/app","script":"./r.sh"},{"name":"worker","host":"d@w","dir":"~/app","script":"./c.sh"}]'
        $t = @(Get-RestartTargets -Json $json -Only 'worker')
        $t.Count | Should -Be 1
        $t[0].host | Should -Be 'd@w'
    }

    It 'rechaza configuraciones incompletas' {
        { Get-RestartTargets -Json '[{"name":"web","host":"d@web","dir":"~/app"}]' } | Should -Throw '*script*'
    }

    It 'rechaza rutas que permitirían inyectar comandos' {
        { Get-RestartTargets -Json '[{"name":"web","host":"d@web","dir":"~/app; rm -rf ~","script":"./r.sh"}]' } | Should -Throw '*no válida*'
    }
}
