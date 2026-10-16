#!/usr/bin/env bash
# Instalador de «AutoCAD 2027 en Linux» (Windows en VM libvirt + FreeRDP).
#
#   ./instalar.sh                 instala la app, optimiza la VM y configura Windows
#   ./instalar.sh --sin-vm        solo la parte de Linux (app, ícono, ahorro de batería)
#   ./instalar.sh --desinstalar   quita la app y el ahorro de batería (no toca la VM)
#
# Requisitos: una VM libvirt con Windows y AutoCAD instalados, con los drivers
# virtio-win y el agente invitado de QEMU (qemu-ga) dentro de Windows.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM="${VM:-win10}"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
CONF="$HOME/.config/winapps/winapps.conf"
V=(virsh -c qemu:///system)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

if [[ "${1:-}" == "--desinstalar" ]]; then
    rm -f "$BIN/autocad" "$APPS/autocad.desktop" "$ICONS/autocad.png"
    sudo rm -f /usr/local/sbin/kvm-ahorro-bateria /etc/udev/rules.d/90-kvm-ahorro-bateria.rules
    sudo systemctl disable --now kvm-ahorro-bateria.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/kvm-ahorro-bateria.service
    update-desktop-database "$APPS" 2>/dev/null || true
    info "Desinstalado (la VM y Windows no se tocaron)."
    exit 0
fi

# --- Dependencias -------------------------------------------------------------
faltan=()
for c in virsh xfreerdp3 Xvfb xprop xwininfo xrandr notify-send python3; do
    command -v "$c" >/dev/null || faltan+=("$c")
done
if ((${#faltan[@]})); then
    warn "Faltan programas: ${faltan[*]}"
    echo "    En Ubuntu/Zorin: sudo apt install libvirt-clients freerdp3-x11 xvfb x11-utils x11-xserver-utils libnotify-bin python3"
    exit 1
fi

# --- Credenciales RDP (mismo archivo que usa WinApps) -------------------------
if [[ ! -f "$CONF" ]]; then
    info "Datos para conectarse a Windows"
    read -rp "  IP de la VM (ej. 192.168.122.168): " ip
    read -rp "  Usuario de Windows: " usr
    read -rsp "  Contraseña de Windows: " pw; echo
    mkdir -p "$(dirname "$CONF")"
    printf 'WAFLAVOR="libvirt"\nVM_NAME="%s"\nRDP_USER="%s"\nRDP_PASS="%s"\nRDP_IP="%s"\n' "$VM" "$usr" "$pw" "$ip" > "$CONF"
    chmod 600 "$CONF"
fi
RDP_USER=$(grep -oP '^RDP_USER="?\K[^"]*' "$CONF")

# --- App de Linux -------------------------------------------------------------
info "Instalando la app «AutoCAD 2027»"
install -Dm755 linux/autocad "$BIN/autocad"
install -Dm644 linux/autocad.png "$ICONS/autocad.png"
mkdir -p "$APPS"
cat > "$APPS/autocad.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AutoCAD 2027
GenericName=CAD
Comment=AutoCAD en la máquina virtual de Windows
Exec=$BIN/autocad
Icon=autocad
StartupWMClass=AutoCAD
Categories=Graphics;Engineering;
Keywords=autocad;cad;dwg;windows;
Actions=apagar;

[Desktop Action apagar]
Name=Apagar Windows (liberar RAM)
Exec=$BIN/autocad --apagar
EOF
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
update-desktop-database "$APPS" 2>/dev/null || true

# --- Ahorro de batería (necesita sudo) ----------------------------------------
info "Ahorro de batería de KVM (pide tu contraseña de Linux)"
if sudo install -Dm755 linux/kvm-ahorro-bateria /usr/local/sbin/kvm-ahorro-bateria \
   && sudo install -Dm644 linux/90-kvm-ahorro-bateria.rules /etc/udev/rules.d/90-kvm-ahorro-bateria.rules \
   && sudo install -Dm644 linux/kvm-ahorro-bateria.service /etc/systemd/system/kvm-ahorro-bateria.service; then
    sudo udevadm control --reload
    sudo systemctl daemon-reload
    sudo systemctl enable --now kvm-ahorro-bateria.service >/dev/null
    echo "    halt_poll_ns ahora: $(cat /sys/module/kvm/parameters/halt_poll_ns)"
else
    warn "No se instaló el ahorro de batería (sin sudo). Lo demás funciona igual."
fi

[[ "${1:-}" == "--sin-vm" ]] && { info "Listo (sin tocar la VM)."; exit 0; }

# --- VM -------------------------------------------------------------------
if ! "${V[@]}" dominfo "$VM" &>/dev/null; then
    warn "No existe la VM «$VM». Si restauras el disco en /var/lib/libvirt/images/win10.qcow2,"
    echo "    puedes crearla con:  virsh -c qemu:///system define vm/win10.xml"
    exit 1
fi
if [[ "$("${V[@]}" domstate "$VM")" == "shut off" ]]; then
    info "Optimizando la VM «$VM» (RAM fija, vCPU, Hyper-V, agente invitado)"
    disco=()
    "${V[@]}" dumpxml --inactive "$VM" | grep -q "bus='virtio'" && disco=(--disco-virtio)
    python3 vm/optimizar_vm.py "$VM" "${disco[@]}"
    "${V[@]}" start "$VM" >/dev/null
else
    warn "La VM está encendida: no se cambió su hardware (apágala y vuelve a ejecutar para optimizarla)."
    [[ "$("${V[@]}" domstate "$VM")" == "paused" ]] && "${V[@]}" resume "$VM" >/dev/null
fi

# Carpetas compartidas (virtiofs): etiqueta → carpeta de Linux. En Windows: Z: Documentos, Y: Descargas, X: Escritorio.
for par in "ProyectosLinux:$HOME/Documentos" "Descargas:$HOME/Descargas" "Escritorio:$HOME/Escritorio"; do
    tag=${par%%:*}; dir=${par#*:}
    "${V[@]}" dumpxml --inactive "$VM" | grep -q "<target dir='$tag'/>" && continue
    f=$(mktemp); printf "<filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><binary path='/usr/libexec/virtiofsd'/><source dir='%s'/><target dir='%s'/></filesystem>" "$dir" "$tag" > "$f"
    "${V[@]}" attach-device "$VM" "$f" --config --live &>/dev/null || "${V[@]}" attach-device "$VM" "$f" --config >/dev/null
    rm -f "$f"; echo "    Compartida ~/${dir##*/} (etiqueta $tag)"
done
# virtiofs necesita memoria compartida
"${V[@]}" dumpxml --inactive "$VM" | grep -q "<access mode='shared'/>" || warn "La VM no tiene memoria compartida (memoryBacking shared): virtiofs no funcionará."

info "Esperando al agente invitado de Windows…"
for _ in $(seq 90); do
    "${V[@]}" qemu-agent-command "$VM" '{"execute":"guest-ping"}' --timeout 2 &>/dev/null && break
    sleep 2
done

# Copia un archivo a Windows y ejecuta PowerShell, por el agente invitado.
python3 - "$VM" "$RDP_USER" <<'PY'
import base64, json, subprocess, sys, time
vm, user = sys.argv[1], sys.argv[2]
def ga(c):
    r = subprocess.run(["virsh", "-c", "qemu:///system", "qemu-agent-command", vm, json.dumps(c), "--timeout", "30"],
                       capture_output=True, text=True)
    if r.returncode: sys.exit("Agente invitado: " + r.stderr.strip())
    return json.loads(r.stdout)["return"]
def put(local, remote):
    h = ga({"execute": "guest-file-open", "arguments": {"path": remote, "mode": "wb"}})
    ga({"execute": "guest-file-write", "arguments": {"handle": h, "buf-b64": base64.b64encode(open(local, "rb").read()).decode()}})
    ga({"execute": "guest-file-close", "arguments": {"handle": h}})
def ps(file, *args):
    pid = ga({"execute": "guest-exec", "arguments": {"path": "powershell.exe", "capture-output": True,
              "arg": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", file, *args]}})["pid"]
    while not (st := ga({"execute": "guest-exec-status", "arguments": {"pid": pid}})).get("exited"):
        time.sleep(1)
    for k in ("out-data", "err-data"):
        if k in st:
            print("    " + base64.b64decode(st[k]).decode("utf-8", "replace").strip().replace("\n", "\n    "))
put("windows/abrir_autocad.ps1", r"C:\Users\Public\abrir_autocad.ps1")
put("windows/configurar_windows.ps1", r"C:\Users\Public\configurar_windows.ps1")
print("==> Configurando Windows")
ps(r"C:\Users\Public\configurar_windows.ps1", "-Usuario", user)
PY

info "Listo. Abre «AutoCAD 2027» desde el menú de aplicaciones."
echo "    La primera vez, en AutoCAD escribe STARTMODE → 0 y VTENABLE → 0 (abre un dibujo en blanco y sin animaciones)."
