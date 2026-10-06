# Historial de versiones

## 2.0.0 · 2026-10-06: versión pública
- Compatibles con Windows PowerShell 5.1 y PowerShell 7. Funciones puras con tests de Pester 5 y `-WhatIf`.
- Corregido: la cabecera del CSV se enviaba a Google Places como si fuera un Place ID.
- Sin IPs, claves ni rutas en el código: servidores en un JSON y la API key por variable de entorno.

## Versiones originales
| Fecha | Script |
|---|---|
| 2025-07-24 | Reinicio de servicios Docker en el servidor web y el worker (bash y PowerShell) |
| 2025-09-05 | Exportación de audioguías y locuciones TTS por parada, ruta y monumento |
| 2025-10-01 | Datos de Google Places para los puntos de encuentro de Things To Do (CSV) |
