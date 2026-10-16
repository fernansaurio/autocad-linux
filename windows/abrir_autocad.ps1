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
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  // AutoCAD maximizado no se agranda solo cuando cambia la resolucion (ventana de Linux
  // redimensionada o a pantalla completa): restaurar y maximizar de nuevo.
  public static void Llenar(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    if (IsIconic(h) || r.r - r.l < GetSystemMetrics(0) || r.b - r.t < GetSystemMetrics(1)) { ShowWindow(h, 9); ShowWindow(h, 3); } }
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

# Mientras AutoCAD siga abierto: barra de tareas oculta (Windows la vuelve a mostrar al
# cambiar la resolucion o reconectar) y AutoCAD siempre llenando la pantalla.
$i = 0
while (Get-Process acad -EA 0) {
  if ($i++ % 4 -eq 0) { [Win]::Taskbar($false); $nh = Ventana; if ($nh -ne [IntPtr]::Zero) { $h = $nh } }
  if ($h -ne [IntPtr]::Zero) { [Win]::Llenar($h) }
  Start-Sleep -m 500
}
Remove-Item $listo -EA 0
[Win]::AutoHide($false); [Win]::Taskbar($true)
