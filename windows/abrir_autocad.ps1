# Lo lanza la app "AutoCAD 2027" de Linux (tarea programada AbrirAutoCAD, en la sesion de Fer).
# Abre AutoCAD maximizado (o lo trae al frente), oculta la barra de tareas mientras
# AutoCAD esta abierto y la devuelve al cerrarlo. C:\Users\Public\autocad_listo.txt
# avisa a Linux de que ya se puede mostrar la ventana.
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class Win {
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
  [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint msg; public uint edge; public int l, t, r, b; public IntPtr lParam; }
  [DllImport("shell32.dll")] static extern IntPtr SHAppBarMessage(uint m, ref APPBARDATA d);
  public static void AutoHide(bool on) {
    APPBARDATA d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = FindWindow("Shell_TrayWnd", null);
    d.lParam = (IntPtr)(on ? 1 : 2); SHAppBarMessage(10, ref d); }   // ABM_SETSTATE: 1 autohide, 2 siempre visible
  public static void Taskbar(bool show) {
    int c = show ? 5 : 0;
    ShowWindow(FindWindow("Shell_TrayWnd", null), c);
    IntPtr s = IntPtr.Zero; while ((s = FindWindowEx(IntPtr.Zero, s, "Shell_SecondaryTrayWnd", null)) != IntPtr.Zero) ShowWindow(s, c); }
  static IntPtr found; static uint pid;
  static bool Cb(IntPtr h, IntPtr l) {
    uint p; GetWindowThreadProcessId(h, out p);
    if (p != pid || !IsWindowVisible(h)) return true;
    StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256);
    if (s.ToString().StartsWith("Autodesk AutoCAD")) { found = h; return false; }
    return true; }
  public static IntPtr Principal(uint processId) { pid = processId; found = IntPtr.Zero; EnumWindows(new CB(Cb), IntPtr.Zero); return found; }
}
"@
$listo = 'C:\Users\Public\autocad_listo.txt'
function Ventana {
  foreach ($p in @(Get-Process acad -EA 0)) { $h = [Win]::Principal([uint32]$p.Id); if ($h -ne [IntPtr]::Zero) { return $h } }
  return [IntPtr]::Zero
}

# Fijar la carpeta compartida con Linux (Z:) en Acceso rapido, una sola vez
$marca = "$env:APPDATA\zpinned.txt"
if (-not (Test-Path $marca) -and (Test-Path 'Z:\')) {
  (New-Object -ComObject Shell.Application).Namespace('Z:\').Self.InvokeVerb('pintohome'); New-Item $marca | Out-Null
}

# Si ya hay otra copia de este script vigilando, solo traer AutoCAD al frente.
$mutex = New-Object Threading.Mutex($false, 'Local\AbrirAutoCAD')
if (-not $mutex.WaitOne(0)) {
  $h = Ventana; if ($h -ne [IntPtr]::Zero) { if ([Win]::IsIconic($h)) { [Win]::ShowWindow($h, 9) | Out-Null }; [Win]::SetForegroundWindow($h) | Out-Null }
  Set-Content $listo (Get-Date -Format o)
  exit 0
}

[Win]::AutoHide($true); [Win]::Taskbar($false)
$h = Ventana
if ($h -eq [IntPtr]::Zero) {
  Remove-Item $listo -EA 0
  if (-not (Get-Process acad -EA 0)) { Start-Process 'C:\Program Files\Autodesk\AutoCAD 2027\acad.exe' -WorkingDirectory 'Z:\' }
  $fin = (Get-Date).AddMinutes(3)
  while ((($h = Ventana) -eq [IntPtr]::Zero) -and (Get-Date) -lt $fin) { Start-Sleep -m 500 }
  # La pantalla de carga tambien se llama "Autodesk AutoCAD": esperar a que AutoCAD
  # tenga el dibujo abierto y este en reposo.
  $desde = Get-Date
  do {
    Start-Sleep 1; $ok = $false
    try {
      $a = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
      $ok = $a.GetAcadState().IsQuiescent -and ($a.Documents.Count -gt 0 -or ((Get-Date) - $desde).TotalSeconds -gt 15)
      [Runtime.InteropServices.Marshal]::ReleaseComObject($a) | Out-Null
    } catch { }
  } until ($ok -or (Get-Date) -gt $fin)
  $h = Ventana
}
if ($h -ne [IntPtr]::Zero) { [Win]::ShowWindow($h, 3) | Out-Null; [Win]::SetForegroundWindow($h) | Out-Null }
Set-Content $listo (Get-Date -Format o)

# Los botones de AutoCAD manejan la ventana de Linux: el lanzador de Linux se conecta a
# este puerto y recibe "min" (minimizar) o "toggle" (pantalla completa <-> ventana).
# AutoCAD vuelve enseguida a maximizado para llenar siempre la pantalla remota.
$linux = [Net.IPAddress]::Parse('192.168.122.1')
$srv = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, 47811)
try { $srv.Start() } catch { $srv = $null }
$cli = $null; $out = $null
function Avisar($m) {
  Add-Content C:\Users\Public\autocad_botones.log "$(Get-Date -Format HH:mm:ss.fff) $m"
  if (-not $script:out) { return }
  try { $script:out.WriteLine($m); $script:out.Flush() } catch { $script:cli.Close(); $script:cli = $null; $script:out = $null }
}
$i = 0
while (Get-Process acad -EA 0) {
  if ($i % 8 -eq 0) { [Win]::Taskbar($false); $nh = Ventana; if ($nh -ne [IntPtr]::Zero) { $h = $nh } }
  if ($srv -and $srv.Pending()) {
    $c = $srv.AcceptTcpClient()
    if ($c.Client.RemoteEndPoint.Address.Equals($linux)) {
      if ($cli) { $cli.Close() }
      $cli = $c; $out = New-Object IO.StreamWriter($c.GetStream())
    } else { $c.Close() }
  }
  if ($h -ne [IntPtr]::Zero) {
    if ([Win]::IsIconic($h)) { Avisar 'min'; [Win]::ShowWindow($h, 3) | Out-Null }
    elseif (-not [Win]::IsZoomed($h) -and [Win]::IsWindowVisible($h)) { Avisar 'toggle'; [Win]::ShowWindow($h, 3) | Out-Null }
  }
  $i++; Start-Sleep -m 250
}
if ($cli) { $cli.Close() }; if ($srv) { $srv.Stop() }
Remove-Item $listo -EA 0
[Win]::AutoHide($false); [Win]::Taskbar($true)
