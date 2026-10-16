# Instala autocad-mcp (github.com/puran-water/autocad-mcp) para que Claude Code en Linux
# controle AutoCAD. Se corre como SYSTEM por el agente invitado. El servidor corre en la
# sesión del usuario (tiene que ver la ventana de AutoCAD) y escucha HTTP en el puerto 8765,
# solo accesible desde el host Linux (192.168.122.1).
param([string]$Usuario = "Fer", [int]$Puerto = 8765)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$d = "C:\autocad-mcp"
New-Item -ItemType Directory -Force $d, "$d\uv", "C:\temp" | Out-Null

if (-not (Test-Path "$d\uv\uv.exe")) {
    Invoke-WebRequest https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip -OutFile "$d\uv.zip"
    Expand-Archive "$d\uv.zip" "$d\uv" -Force; Remove-Item "$d\uv.zip"
}
Invoke-WebRequest https://github.com/puran-water/autocad-mcp/archive/refs/heads/main.zip -OutFile "$d\repo.zip"
Expand-Archive "$d\repo.zip" "$d\tmp" -Force; Remove-Item "$d\repo.zip"
if (Test-Path "$d\repo") { Remove-Item "$d\repo" -Recurse -Force }
Move-Item "$d\tmp\autocad-mcp-main" "$d\repo"
Remove-Item "$d\tmp" -Recurse -Force

# Python y caché dentro de C:\autocad-mcp para que el usuario (no SYSTEM) los pueda usar
$env:UV_PYTHON_INSTALL_DIR = "$d\python"; $env:UV_CACHE_DIR = "$d\cache"
# uv escribe su progreso en stderr; con "Stop" PowerShell lo tomaría como error
$ErrorActionPreference = "Continue"
Push-Location "$d\repo"; & "$d\uv\uv.exe" sync --python 3.12 2>&1 | Out-Host; $r = $LASTEXITCODE; Pop-Location
$ErrorActionPreference = "Stop"
if ($r -ne 0) { throw "uv sync falló ($r)" }

# El servidor trae solo stdio; FastMCP ya sabe hablar HTTP, así que basta con otro arranque.
@"
import sys
log = open(r'$d\servidor.log', 'a', buffering=1, encoding='utf-8')
sys.stdout = sys.stderr = log  # pythonw no tiene consola
from autocad_mcp.server import mcp
mcp.settings.host = '0.0.0.0'
mcp.settings.port = $Puerto
from mcp.server.transport_security import TransportSecuritySettings
mcp.settings.transport_security = TransportSecuritySettings(allowed_hosts=['192.168.122.168:$Puerto'])
mcp.run(transport='streamable-http')
"@ | Set-Content "$d\servidor_http.py" -Encoding UTF8

# Plugin en ApplicationPlugins: AutoCAD lo carga solo en cada dibujo (carpeta de confianza, sin APPLOAD)
$b = "C:\ProgramData\Autodesk\ApplicationPlugins\AutoCADMCP.bundle"
New-Item -ItemType Directory -Force "$b\Contents" | Out-Null
Copy-Item "$d\repo\lisp-code\*.lsp" "$b\Contents" -Force
@"
<?xml version="1.0" encoding="utf-8"?>
<ApplicationPackage SchemaVersion="1.0" AppVersion="3.1.0" Name="AutoCAD MCP" ProductCode="{6E1C2B7A-4F0D-4C3E-9B1A-0A1C2D3E4F50}" UpgradeCode="{6E1C2B7A-4F0D-4C3E-9B1A-0A1C2D3E4F51}">
  <CompanyDetails Name="puran-water" />
  <Components>
    <RuntimeRequirements OS="Win64" Platform="AutoCAD*" />
    <ComponentEntry AppName="MCPDispatch" ModuleName="./Contents/mcp_dispatch.lsp" PerDocument="True" LoadOnAutoCADStartup="True" />
    <ComponentEntry AppName="MCPAttributeTools" ModuleName="./Contents/attribute_tools.lsp" PerDocument="True" LoadOnAutoCADStartup="True" />
  </Components>
</ApplicationPackage>
"@ | Set-Content "$b\PackageContents.xml" -Encoding UTF8

icacls $d /grant "${Usuario}:(OI)(CI)M" /T /Q | Out-Null
icacls C:\temp /grant "${Usuario}:(OI)(CI)M" /Q | Out-Null

New-NetFirewallRule -DisplayName "AutoCAD MCP" -Direction Inbound -Protocol TCP -LocalPort $Puerto `
    -RemoteAddress 192.168.122.1 -Action Allow -ErrorAction SilentlyContinue | Out-Null

$a = New-ScheduledTaskAction -Execute "$d\repo\.venv\Scripts\pythonw.exe" -Argument "$d\servidor_http.py" -WorkingDirectory "$d\repo"
$st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName AutoCAD-MCP -Action $a -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $Usuario) `
    -Principal (New-ScheduledTaskPrincipal -UserId $Usuario -LogonType Interactive) -Settings $st -Force | Out-Null
Start-ScheduledTask -TaskName AutoCAD-MCP
"listo"
