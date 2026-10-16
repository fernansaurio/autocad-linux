# Configura Windows (VM) para usar AutoCAD desde Linux. Lo ejecuta instalar.sh
# por el agente invitado de QEMU (como SYSTEM). Se puede repetir sin problema.
param([string]$Usuario = 'Fer', [string]$ZonaHoraria = 'Central America Standard Time')
$ProgressPreference = 'SilentlyContinue'

# Reloj: zona horaria correcta (con la del Pacífico Autodesk daba «Error del reloj») y sincronización
tzutil /s $ZonaHoraria
Set-Service w32time -StartupType Automatic; Start-Service w32time -EA 0
w32tm /config /manualpeerlist:"time.windows.com,0x9 pool.ntp.org,0x9" /syncfromflags:manual /update | Out-Null
"Zona horaria: $((Get-TimeZone).Id)"

# Rendimiento
powercfg /setactive SCHEME_MIN
foreach ($s in 'SysMain', 'WSearch') { Stop-Service $s -Force -EA 0; Set-Service $s -StartupType Disabled }
"Plan alto rendimiento; SysMain y WSearch deshabilitados"

# Efectos visuales al mínimo para el usuario
$sid = (New-Object Security.Principal.NTAccount($Usuario)).Translate([Security.Principal.SecurityIdentifier]).Value
$hive = "Registry::HKEY_USERS\$sid"
$cargado = Test-Path $hive
if (-not $cargado) { reg load "HKU\$sid" "C:\Users\$Usuario\NTUSER.DAT" | Out-Null }
$h = "$hive\Software\Microsoft\Windows\CurrentVersion"
New-Item "$h\Explorer\VisualEffects" -Force | Out-Null
Set-ItemProperty "$h\Explorer\VisualEffects" VisualFXSetting 2 -Type DWord
New-Item "$h\Themes\Personalize" -Force | Out-Null
Set-ItemProperty "$h\Themes\Personalize" EnableTransparency 0 -Type DWord
Set-ItemProperty "$hive\Control Panel\Desktop" UserPreferencesMask ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0, 0, 0)) -Type Binary
Set-ItemProperty "$hive\Control Panel\Desktop\WindowMetrics" MinAnimate '0'
if (-not $cargado) { [gc]::Collect(); reg unload "HKU\$sid" | Out-Null }
"Efectos visuales: mejor rendimiento"

# Escritorio remoto: 60 fps (el lanzador baja a 30 con batería) y sin animación de primer inicio
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' DWMFRAMEINTERVAL 15 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' EnableFirstLogonAnimation 0 -Type DWord

# Tarea que abre AutoCAD (maximizado, sin barra de tareas) dentro de la sesión del usuario
$a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Users\Public\abrir_autocad.ps1'
$st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -MultipleInstances Parallel
Register-ScheduledTask -TaskName AbrirAutoCAD -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $Usuario -LogonType Interactive) -Settings $st -Force | Out-Null
"Tarea AbrirAutoCAD registrada"

# Carpetas compartidas con Linux (virtiofs): un servicio por carpeta, cada uno con su etiqueta
# y su letra. El servicio original VirtioFsSvc (sin etiqueta) monta todas las carpetas como
# la primera, así que se deshabilita.
$exe = 'C:\Program Files\Virtio-Win\VioFS\virtiofs.exe'
$carpetas = @(@('ProyectosLinux', 'Z', 'Documentos'), @('Descargas', 'Y', 'Descargas'), @('Escritorio', 'X', 'Escritorio'))
if (Test-Path $exe) {
  Stop-Service VirtioFsSvc -Force -EA 0; Set-Service VirtioFsSvc -StartupType Disabled -EA 0
  foreach ($c in $carpetas) {
    $name = "VirtioFs-$($c[2])"
    if (Get-Service $name -EA 0) { Stop-Service $name -Force -EA 0; sc.exe delete $name | Out-Null; Start-Sleep 1 }
    New-Service -Name $name -BinaryPathName "`"$exe`" -t $($c[0]) -m $($c[1]):" -DisplayName "VirtIO-FS $($c[2]) ($($c[1]):)" `
      -Description "Carpeta de Linux ~/$($c[2]) como unidad $($c[1]):" -StartupType Automatic | Out-Null
    sc.exe failure $name reset= 60 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Start-Service $name -EA 0
  }
  "Carpetas compartidas: " + (($carpetas | % { "$($_[1]): ~/$($_[2])" }) -join ', ')
}
