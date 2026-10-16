# AutoCAD 2027 en Linux

AutoCAD corre en una máquina virtual de Windows (libvirt/KVM) y se ve en Linux como
una app más: una ventana donde solo aparece AutoCAD, sin escritorio ni barra de tareas
de Windows y sin la pantalla de «Bienvenido».

## Instalar

```bash
./instalar.sh              # app + ahorro de batería + optimizar VM + configurar Windows
./instalar.sh --sin-vm     # solo la parte de Linux
./instalar.sh --desinstalar
```

Necesita una VM libvirt (por defecto `win10`; otra con `VM=nombre ./instalar.sh`) con
Windows, AutoCAD, los drivers virtio-win y el agente invitado de QEMU instalados. Los
datos de conexión se guardan en `~/.config/winapps/winapps.conf` (el mismo archivo de WinApps).

## Cómo funciona

| Paso | Qué hace |
|---|---|
| Abrir la app | Enciende o reanuda la VM y corrige el reloj de Windows (si no, Autodesk da «Error del reloj»). |
| Sin sesión abierta | Inicia sesión con una conexión RDP **invisible** (Xvfb), así no se ve «Bienvenido». |
| Dentro de Windows | La tarea `AbrirAutoCAD` (`windows/abrir_autocad.ps1`) abre AutoCAD maximizado, oculta la barra de tareas y avisa cuando AutoCAD terminó de cargar. |
| Mostrar | Abre la ventana (redimensionable, la resolución de Windows se adapta) y la deja transparente hasta que termina de reconectar. |
| Cerrar | Al cerrar la ventana o AutoCAD, la VM se **pausa**: 0 % de CPU, y la próxima vez abre al instante. |
| Clic derecho → «Apagar Windows» | Apaga la VM y libera su RAM. |

Los archivos se abren y guardan con el explorador de Windows. Carpetas compartidas con Linux
(virtiofs, fijadas en Acceso rápido): `Z:` = ~/Documentos, `Y:` = ~/Descargas, `X:` = ~/Escritorio.
Cada una tiene su propio servicio en Windows (`VirtioFs-Documentos`, `-Descargas`, `-Escritorio`).

## Batería

- La VM se pausa en cuanto cierras AutoCAD (no gasta nada mientras no lo usas).
- Con batería la pantalla remota va a 30 fps en vez de 60 y el vigilante consulta menos seguido.
- `kvm-ahorro-bateria` (regla udev + servicio) pone `halt_poll_ns=0` en batería: KVM deja de
  girar la CPU cada vez que Windows queda en reposo. Enchufado vuelve a 200000.

## Si no abre

Los registros de la última apertura quedan en `~/.cache/autocad/` (`rdp.log`, `rdp-oculto.log`).
Si Windows está instalando actualizaciones, el primer arranque puede tardar varios minutos (sale un aviso).

## Conectar con Claude Code (MCP)

1. En Linux: `virsh -c qemu:///system` + agente invitado ejecuta `windows/instalar_mcp.ps1` como SYSTEM
   (instala [autocad-mcp](https://github.com/puran-water/autocad-mcp) en `C:\autocad-mcp`, servidor HTTP en `:8765`).
2. `claude mcp add --scope user --transport http autocad http://192.168.122.168:8765/mcp`
3. En AutoCAD, una sola vez: `APPLOAD` → `C:\ProgramData\Autodesk\ApplicationPlugins\AutoCADMCP.bundle\Contents\mcp_dispatch.lsp`
   → «Cargar siempre», y agrégalo al «Startup Suite». Debe salir `=== MCP Dispatch v3.1 loaded ===`.

Si Claude dice «mcp_dispatch.lsp not loaded», falta el paso 3. El aviso «Archivo ejecutable no firmado»
puede quedar oculto detrás de AutoCAD y bloquearlo: búscalo con Alt+Tab.

## Archivos

- `linux/autocad` — lanzador (`~/.local/bin/autocad`).
- `linux/kvm-ahorro-bateria*` — ahorro de batería de KVM.
- `windows/configurar_windows.ps1` — zona horaria, rendimiento, efectos visuales, tarea programada.
- `windows/instalar_mcp.ps1` — conecta AutoCAD con Claude Code (autocad-mcp, HTTP en `192.168.122.168:8765/mcp`); luego `claude mcp add --scope user --transport http autocad http://192.168.122.168:8765/mcp`.
- `windows/abrir_autocad.ps1` — abre AutoCAD dentro de la sesión de Windows.
- `vm/optimizar_vm.py` — RAM fija, vCPU, Hyper-V, agente invitado, disco virtio (`--simular` para ver el XML sin aplicarlo).
- `vm/win10.xml` — definición de la VM tal como quedó.

## Ajustes de AutoCAD recomendados

En la línea de comandos de AutoCAD (se guardan al cerrarlo normalmente):
`STARTMODE 0` (abre un dibujo en blanco), `VTENABLE 0` (sin animaciones de zoom),
`ROLLOVERTIPS 0`, `FILEDIA 1` (cuadro de diálogo de Windows para abrir/guardar).
