#!/usr/bin/env python3
"""Aplica a la VM libvirt los ajustes de rendimiento para AutoCAD.

Uso: optimizar_vm.py <vm> [--ram-gib N] [--vcpus N] [--disco-virtio]

- RAM fija (sin balloon), vCPU en un solo socket, CPU host-passthrough.
- Enlightenments Hyper-V completos (menos CPU en reposo = menos batería).
- Canal del agente invitado de QEMU (lo usa el lanzador `autocad`).
- --disco-virtio: pasa el disco del sistema de SATA a virtio. Solo si Windows ya
  tiene el driver viostor como driver de arranque (si no, no arranca: se puede
  volver con `virsh define` del respaldo que deja este script).
La VM debe estar apagada para que los cambios apliquen al siguiente arranque.
"""
import argparse, subprocess, sys, time, xml.etree.ElementTree as ET

ap = argparse.ArgumentParser()
ap.add_argument("vm")
ap.add_argument("--ram-gib", type=int, default=7)
ap.add_argument("--vcpus", type=int, default=6)
ap.add_argument("--disco-virtio", action="store_true")
ap.add_argument("--simular", action="store_true", help="solo mostrar el XML resultante")
a = ap.parse_args()

V = ["virsh", "-c", "qemu:///system"]
ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
xml = subprocess.run(V + ["dumpxml", "--inactive", a.vm], capture_output=True, text=True, check=True).stdout
backup = f"/tmp/{a.vm}-respaldo-{int(time.time())}.xml"
open(backup, "w").write(xml)
d = ET.fromstring(xml)
E = ET.SubElement


def child(parent, tag):
    n = parent.find(tag)
    return n if n is not None else E(parent, tag)


for tag in ("memory", "currentMemory"):
    n = child(d, tag)
    n.text = str(a.ram_gib * 1024 * 1024)
    n.set("unit", "KiB")

child(d, "vcpu").text = str(a.vcpus)
cpu = child(d, "cpu")
cpu.attrib.update(mode="host-passthrough", check="none", migratable="on")
for t in cpu.findall("topology"):
    cpu.remove(t)
E(cpu, "topology", sockets="1", dies="1", cores=str(a.vcpus), threads="1")

feat = child(d, "features")
hv = feat.find("hyperv")
if hv is not None:
    feat.remove(hv)
hv = E(feat, "hyperv", mode="custom")
for name in ("relaxed", "vapic", "vpindex", "runtime", "synic", "reset", "frequencies", "reenlightenment", "tlbflush", "ipi"):
    E(hv, name, state="on")
E(hv, "spinlocks", state="on", retries="8191")
E(E(hv, "stimer", state="on"), "direct", state="on")

dev = d.find("devices")
mb = dev.find("memballoon")
if mb is None:
    mb = E(dev, "memballoon")
mb.attrib.clear()
mb.set("model", "none")
for c in list(mb):
    mb.remove(c)

if not any(ch.find("target") is not None and ch.find("target").get("name") == "org.qemu.guest_agent.0"
           for ch in dev.findall("channel")):
    ch = E(dev, "channel", type="unix")
    E(ch, "source", mode="bind")
    E(ch, "target", type="virtio", name="org.qemu.guest_agent.0")

for disk in dev.findall("disk"):
    if disk.get("device") != "disk":
        continue
    drv = child(disk, "driver")
    drv.attrib.update(cache="none", io="native", discard="unmap")
    if a.disco_virtio and disk.find("target").get("bus") != "virtio":
        tg = disk.find("target")
        tg.attrib.update(dev="vda", bus="virtio")
        ad = disk.find("address")
        if ad is not None:
            disk.remove(ad)

new = "/tmp/" + a.vm + "-optimizada.xml"
ET.ElementTree(d).write(new)
if a.simular:
    sys.exit(print(open(new).read()))
r = subprocess.run(V + ["define", new], capture_output=True, text=True)
if r.returncode:
    sys.exit(f"Error al definir la VM: {r.stderr.strip()}\nRespaldo: {backup}")
print(f"VM «{a.vm}» optimizada: {a.ram_gib} GiB, {a.vcpus} vCPU"
      f"{', disco virtio' if a.disco_virtio else ''}. Respaldo de la anterior: {backup}")
