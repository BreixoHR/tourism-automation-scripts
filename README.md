# Tourism Automation Scripts

Scripts de **PowerShell** del día a día de un departamento de sistemas en una agencia de turismo: enriquecer datos para Google Things To Do, generar locuciones de audioguías y reiniciar servicios en varios servidores.

Funcionan en **Windows PowerShell 5.1 y PowerShell 7**, tienen tests con **Pester 5** (los dos motores en CI) y todos admiten `-WhatIf`.

![pester](https://img.shields.io/badge/Pester-15%20tests-brightgreen) ![ps](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE) ![license](https://img.shields.io/badge/license-MIT-blue)

| Script | Qué hace |
|---|---|
| [`places/Update-PlacesCsv.ps1`](places/Update-PlacesCsv.ps1) | Lee Place IDs de un CSV, consulta **Google Places API (New)** y escribe el bloque `place_info` (dirección estructurada, coordenadas, teléfono, web) que exige el feed de **Google Things To Do** para los puntos de encuentro. |
| [`audioguides/New-AudioguideTts.ps1`](audioguides/New-AudioguideTts.ps1) | Reconstruye los textos de una audioguía a partir de su exportación JSON (textos normalizados por `id_text` + traducciones) y genera un **WAV por monumento, ruta y parada, y por idioma**, con las voces de Windows. |
| [`ops/Restart-DockerServices.ps1`](ops/Restart-DockerServices.ps1) | Reinicia por SSH, en orden, los servicios Docker de varios servidores (web y workers) y se detiene en el primer fallo. |

## Ejemplos

```powershell
# Things To Do: rellena la columna F con un JSON por lugar
$env:GOOGLE_PLACES_API_KEY = '...'
.\places\Update-PlacesCsv.ps1 -CsvPath .\meeting-points.csv -IdColumn 1 -OutputColumn 5 -Verbose

# Audioguías: español e inglés; -WhatIf muestra qué generaría sin sintetizar nada
.\audioguides\New-AudioguideTts.ps1 -ExportPath .\export.json -Language es,en -OutDir .\tts -WhatIf

# Reinicio de servicios (hosts.json fuera del repo; ver ops/hosts.example.json)
.\ops\Restart-DockerServices.ps1 -HostsFile .\hosts.json -Only worker
```

Salida de `Update-PlacesCsv` para cada lugar, en una línea dentro de la celda:

```json
{"location":{"place_info":{"name":"Puerta del Museo Demo","phone_number":"+34 910 00 00 00","website_url":"https://museo.example.com/","coordinates":{"latitude":40.4168,"longitude":-3.7038},"structured_address":{"street_address":"Calle Mayor, 1","locality":"Madrid","administrative_area":"M","postal_code":"28013","country_code":"ES"}}}}
```

## Diseño

- **Funciones puras y testeables**: la transformación (`ConvertTo-PlaceInfo`, `Get-AudioguideItems`, `Get-RestartTargets`) está separada de la E/S. Los scripts se pueden cargar con dot-sourcing (`. .\script.ps1`) sin ejecutarse, que es como los usan los tests.
- **Sin secretos ni infraestructura en el código**: la API key va por parámetro o variable de entorno, y los servidores en un JSON ignorado por git. Las claves SSH las gestiona `ssh-agent` o `~/.ssh/config`.
- **Errores aislados**: un Place ID que falla deja `{"error": …}` en su línea y el resto continúa. Un reinicio que falla detiene la secuencia para no dejar el worker en una versión distinta de la web.
- **Coste controlado**: `X-Goog-FieldMask` pide solo los 6 campos necesarios. La versión anterior pedía `*`, y Places factura por campos solicitados.
- **Validación de configuración**: las rutas remotas se validan con una lista blanca para evitar inyección de comandos en la línea SSH (hay un test que lo comprueba).

## Lo que encontraron los tests

Al escribir los tests para la versión pública aparecieron fallos que la versión original también tenía o habría tenido:

| Fallo | Corrección |
|---|---|
| La fila de cabecera del CSV se enviaba a la API como si fuera un Place ID, con una llamada facturada inútil | Se salta por defecto (`-NoHeader` para CSVs sin cabecera) |
| Operador ternario `? :`, que no existe en PowerShell 5.1 (el script no arrancaba en Windows "de serie") | Sintaxis compatible con 5.1 y 7 |
| En 5.1 `ConvertFrom-Json` no enumera los arrays y las funciones desenrollan los arrays de un elemento | `@()` y enumeración explícita |
| Scripts UTF-8 sin BOM: PowerShell 5.1 los lee como ANSI y rompe los acentos | Codificación UTF-8 con BOM |

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester -Path tests -Output Detailed
```

Los tests cubren la transformación de Places, incluidos los lugares incompletos, y el flujo completo sobre un CSV temporal con la API simulada (IDs múltiples, un error, comillas y comas). También cubren el escapado CSV, el índice de traducciones y los textos sin traducir, y la validación de hosts.

## Licencia

[MIT](LICENSE)
