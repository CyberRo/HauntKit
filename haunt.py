#!/usr/bin/env python3
"""
HauntKit — Cyber Haunt & Spectre Arsenal
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Entry point unificado para todas las herramientas del arsenal.

Uso:
    python haunt.py --list
    python haunt.py run <herramienta>
    python haunt.py --all
"""

import sys
import subprocess
from pathlib import Path

HAUNTKIT_HOME = Path(__file__).parent
TOOLS_DIR = HAUNTKIT_HOME / "tools"

BANNER = """
╔══════════════════════════════════════════╗
║           H A U N T K I T               ║
║  Cyber Haunt & Spectre Arsenal v0.1     ║
╚══════════════════════════════════════════╝
"""


def list_tools():
    """Lista todas las herramientas disponibles."""
    print(f"{BANNER}\n")
    print("Herramientas disponibles:\n")
    for category in sorted(TOOLS_DIR.iterdir()):
        if not category.is_dir():
            continue
        tools = list(category.glob("*.py")) + list(category.glob("*.sh"))
        if not tools:
            continue
        print(f"  [{category.name}]")
        for tool in tools:
            print(f"    └── {tool.name}")
        print()


def run_tool(tool_path: str):
    """Ejecuta una herramienta por su ruta relativa."""
    full_path = TOOLS_DIR / tool_path
    if not full_path.exists():
        # Buscar en todas las categorías
        matches = list(TOOLS_DIR.rglob(tool_path))
        if not matches:
            print(f"[-] Herramienta no encontrada: {tool_path}")
            sys.exit(1)
        full_path = matches[0]

    print(f"[+] Ejecutando: {full_path.name}\n")

    if full_path.suffix == ".py":
        subprocess.run([sys.executable, str(full_path)] + sys.argv[3:])
    elif full_path.suffix == ".sh":
        subprocess.run(["bash", str(full_path)] + sys.argv[3:])
    else:
        print(f"[-] Tipo de archivo no soportado: {full_path.suffix}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(BANNER)
        print("Uso:")
        print("  python haunt.py --list        Listar herramientas")
        print("  python haunt.py run <tool>    Ejecutar herramienta")
        print("  python haunt.py --all         Ejecutar arsenal completo")
        print("  python haunt.py --install     Instalar dependencias")
        return

    if sys.argv[1] == "--list":
        list_tools()
    elif sys.argv[1] == "run" and len(sys.argv) >= 3:
        run_tool(sys.argv[2])
    elif sys.argv[1] == "--all":
        list_tools()
        print("[*] Modo arsenal completo próximamente...")
    elif sys.argv[1] == "--install":
        subprocess.run(["bash", str(HAUNTKIT_HOME / "scripts" / "install.sh")])
    else:
        print(f"[-] Opción desconocida: {sys.argv[1]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
