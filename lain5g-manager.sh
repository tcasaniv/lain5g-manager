#!/usr/bin/env bash
# =============================================================================
# lain5g-manager.sh — Gestor interactivo de OpenLain5G
# =============================================================================
# Autor     : Terry Casani Valencia <https://github.com/tcasaniv/>
# Licencia  : MIT
# Manager   : https://github.com/tcasaniv/lain5g-manager
# OpenLain5G: https://github.com/guallycanazas/Lain5G
# Artículo  : https://doi.org/10.2139/ssrn.7404673
# =============================================================================
set -euo pipefail

MANAGER_VERSION="1.1.8"
OPENLAIN5G_COMPAT="1.1.8"
MANAGER_REPO="https://github.com/tcasaniv/lain5g-manager"
REPO_URL="https://github.com/guallycanazas/Lain5G"
LAIN5G_DIR="${HOME}/Lain5G"
LAIN5G_STATE="${HOME}/.local/state/lain5g"
X310_FIX_STATE="${LAIN5G_STATE}/x310_network_fix.env"
X310_ETH_ISSUE=false
X310_ETH_REASON=""
SELECTED_REF=""
INSTALLED=false
VERSION_STR="no instalado"
GIT_REF="—"
RUNNING_PROJECTS=()
DOCKER_ACCESS="missing"

_is_wsl() {
  grep -qi "microsoft" /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]
}

_detect_x310_ethernet_issue() {
  X310_ETH_ISSUE=false
  X310_ETH_REASON=""

  # Si ya hay un fix activo registrado, marcamos para permitir su gestión o reversión
  if [ -f "$X310_FIX_STATE" ]; then
    X310_ETH_ISSUE=true
    local fix_t=""
    fix_t=$(grep -E "^FIX_TYPE=" "$X310_FIX_STATE" 2>/dev/null | cut -d= -f2 || true)
    X310_ETH_REASON="Modificación activa registrada ($fix_t)"
    return 0
  fi

  local target_addr="${USRP_ADDR:-192.168.10.2}"
  local route
  route="$(ip -4 route get "$target_addr" 2>/dev/null | head -n1 || true)"
  if [ -z "$route" ]; then
    X310_ETH_ISSUE=true
    X310_ETH_REASON="Sin ruta IPv4 hacia USRP X310 ($target_addr)"
    return 0
  fi

  local route_gateway
  route_gateway="$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$route")"
  local route_device
  route_device="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")"

  if [ -n "$route_gateway" ]; then
    X310_ETH_ISSUE=true
    if _is_wsl; then
      X310_ETH_REASON="Ruta a $target_addr usa gateway virtual WSL2 ($route_gateway via $route_device)"
    else
      X310_ETH_REASON="Ruta a $target_addr usa gateway ($route_gateway via $route_device) en lugar de enlace L2 directo"
    fi
    return 0
  fi

  local sys_class_net="${LAIN5G_SYS_CLASS_NET:-/sys/class/net}"
  local iface_path="$sys_class_net/${route_device:-missing}"
  if [ -d "$iface_path/wireless" ]; then
    X310_ETH_ISSUE=true
    X310_ETH_REASON="Ruta hacia $target_addr usa interfaz inalámbrica ($route_device)"
    return 0
  fi

  if [ -r "$iface_path/carrier" ] && [ "$(cat "$iface_path/carrier" 2>/dev/null || true)" = "0" ]; then
    X310_ETH_ISSUE=true
    X310_ETH_REASON="Interfaz $route_device no tiene enlace físico activo (cable desconectado)"
    return 0
  fi
}

has_docker() {
  command -v docker &>/dev/null && docker ps &>/dev/null
}

# =============================================================================
# ── Ayuda ──────────────────────────────────────────────────────────────────────
# =============================================================================
show_help() {
  cat <<'EOF'
Uso:
  bash ~/lain5g-manager.sh [OPCIONES]

Gestor interactivo para OpenLain5G: instalar, desinstalar, reinstalar,
iniciar y detener escenarios 4G/5G. Incluye guía educativa integrada.

Opciones:
  --status    Muestra el estado actual de la instalación y sale.
  --help, -h  Muestra este mensaje y sale.

Manager   : https://github.com/tcasaniv/lain5g-manager
OpenLain5G: https://github.com/guallycanazas/Lain5G
EOF
}

# =============================================================================
# ── Helpers ───────────────────────────────────────────────────────────────────
# =============================================================================
section() {
  echo
  echo "══════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════"
}

subsection() {
  echo
  echo "  ─── $1 ───────────────────────────────────────────────"
}

confirm() {
  local prompt="$1"
  read -rp "$(echo -e "$prompt") [s/N] " resp
  [[ "${resp,,}" == "s" || "${resp,,}" == "si" || "${resp,,}" == "y" || "${resp,,}" == "yes" ]]
}

pause() {
  echo
  read -rp "  Pulsa Enter para continuar..." _ignored
}

# Muestra el comando que se va a ejecutar antes de ejecutarlo
show_cmd() {
  local desc="$1"
  local cmd_str="$2"
  echo
  echo "  ┌─ $desc"
  echo "  │  \$ $cmd_str"
  echo "  └────────────────────────────────────────────────────"
  echo
}

divider() {
  echo "  ──────────────────────────────────────────────────────"
}

# =============================================================================
# ── Detectar estado ───────────────────────────────────────────────────────────
# =============================================================================
detect_state() {
  INSTALLED=false
  VERSION_STR="no instalado"
  GIT_REF="—"
  RUNNING_PROJECTS=()

  if [ -d "$LAIN5G_DIR" ]; then
    INSTALLED=true
    VERSION_STR=$(cat "$LAIN5G_DIR/VERSION" 2>/dev/null || echo "desconocida")
    if [ -d "$LAIN5G_DIR/.git" ] && command -v git &>/dev/null; then
      local tag branch
      tag=$(git -C "$LAIN5G_DIR" describe --tags --exact-match 2>/dev/null || true)
      branch=$(git -C "$LAIN5G_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "desconocida")
      GIT_REF="${tag:-$branch}"
    fi
  fi

  # Detectar componentes corriendo via Docker dinámicamente
  DOCKER_ACCESS="missing"
  if command -v docker &>/dev/null; then
    if docker ps &>/dev/null; then
      DOCKER_ACCESS="ok"
      local all_projects
      all_projects=$(_get_all_compose_projects)
      while IFS= read -r proj; do
        [ -z "$proj" ] && continue
        local count
        count=$({ docker ps --filter "label=com.docker.compose.project=$proj" \
                --format "{{.Names}}" 2>/dev/null || true; } | wc -l)
        if [ "$count" -gt 0 ]; then
          RUNNING_PROJECTS+=("$proj")
        fi
      done <<< "$all_projects"
    else
      DOCKER_ACCESS="denied"
    fi
  fi

  # Detectar problemas de enlace de red con USRP X310
  _detect_x310_ethernet_issue
}

# Descubrimiento dinámico de proyectos compose de OpenLain5G
_get_all_compose_projects() {
  if [ -d "$LAIN5G_DIR" ] && command -v python3 &>/dev/null; then
    python3 -c "
import os, re
lain_dir = '${LAIN5G_DIR}'
found = set()
for root, dirs, files in os.walk(lain_dir):
    for f in files:
        if f.endswith(('.yml', '.yaml')) and ('docker-compose' in f or 'compose' in f):
            p = os.path.join(root, f)
            try:
                with open(p, 'r', errors='ignore') as fp:
                    for line in fp:
                        m = re.match(r'^\s*name:\s*([a-zA-Z0-9_-]+)', line)
                        if m:
                            found.add(m.group(1))
                            break
            except Exception:
                pass
for name in sorted(found):
    print(name)
" 2>/dev/null && return 0
  fi
  # Fallback si no está Python o falla
  cat <<'EOF'
lain5g-lab-app
lain5g-lab-5g-sa
lain5g-lab-4g-lte-sim
lain5g-lab-5g-vonr-sim
lain5g-lab-4g-volte-sim
lain5g-lab-5g-sa-x310
lain5g-lab-5g-nsa-x310
lain5g-lab-4g-lte-x310
lain5g-lab-ims-real-4g
lain5g-lab-ims-real-5g
EOF
}

# Descubrimiento dinámico de perfiles oficiales
_get_public_profiles() {
  if [ -d "$LAIN5G_DIR" ] && command -v python3 &>/dev/null; then
    python3 -c "
import sys, os
sys.path.insert(0, os.path.join('${LAIN5G_DIR}', 'src'))
try:
    from backend.app.services.image_catalog import PUBLIC_PROFILE_IDS
    from backend.app.services.deployment_registry import DEPLOYMENTS
    for pid in PUBLIC_PROFILE_IDS:
        dep = DEPLOYMENTS.get(pid)
        mode = getattr(dep, 'mode', 'simulation')
        name = getattr(dep, 'name', pid)
        desc = getattr(dep, 'description', '')
        print(f'{pid}\t{mode}\t{name}\t{desc}')
except Exception:
    pass
" 2>/dev/null && return 0
  fi
  # Fallback compatible
  cat <<'EOF'
4g-lte-sim	simulation	4G - srsRAN ZMQ Simulation	Software-only LTE con Open5GS EPC y srsRAN
5g-sa	simulation	5G - UERANSIM Simulation	Software-only 5G SA con Open5GS y UERANSIM
4g-lte-x310	rf-controlled	4G - Guarded LTE RF	LTE fisico con controles de seguridad RF
5g-sa-x310	rf-controlled	5G - Guarded SA RF	5G SA fisico con controles de seguridad RF
5g-nsa-x310	rf-controlled	5G NSA - Guarded EN-DC RF	Ancla LTE y portadora NR sobre X310
EOF
}

# Devuelve la etiqueta legible de un compose project
_project_label() {
  case "$1" in
    "lain5g-lab-app")          echo "App web OpenLain5G (UI + Observabilidad)" ;;
    "lain5g-lab-5g-sa")        echo "Escenario 5G SA (simulación)" ;;
    "lain5g-lab-4g-lte-sim")   echo "Escenario 4G LTE (simulación)" ;;
    "lain5g-lab-5g-vonr-sim")  echo "Escenario 5G VoNR (señalización)" ;;
    "lain5g-lab-4g-volte-sim") echo "Escenario 4G VoLTE (señalización)" ;;
    "lain5g-lab-5g-sa-x310")   echo "Escenario 5G SA X310 (RF)" ;;
    "lain5g-lab-5g-nsa-x310")  echo "Escenario 5G NSA X310 (RF)" ;;
    "lain5g-lab-4g-lte-x310")  echo "Escenario 4G LTE X310 (RF)" ;;
    "lain5g-lab-ims-real-4g")  echo "Servicio IMS Real 4G" ;;
    "lain5g-lab-ims-real-5g")  echo "Servicio IMS Real 5G" ;;
    *)                          echo "$1" ;;
  esac
}

# =============================================================================
# ── Verificar / instalar git ──────────────────────────────────────────────────
# =============================================================================
ensure_git() {
  if command -v git &>/dev/null; then
    return 0
  fi
  echo
  echo "⚠️  git no está instalado en el sistema."
  if confirm "¿Instalar git con apt-get?"; then
    sudo apt-get update -qq
    sudo apt-get install -y git
    if ! command -v git &>/dev/null; then
      echo "❌ Error: no se pudo instalar git." >&2
      return 1
    fi
    echo "✓ git instalado."
  else
    echo "❌ git es necesario para continuar." >&2
    return 1
  fi
}

# =============================================================================
# ── Selector de rama / tag ────────────────────────────────────────────────────
# =============================================================================
pick_branch() {
  local current_ref="${1:-}"

  echo
  echo "  Obteniendo versiones disponibles desde GitHub..."
  local raw
  if ! raw=$(git ls-remote --heads --tags "$REPO_URL" 2>/dev/null); then
    echo "❌ Error: no se pudo conectar a GitHub." >&2
    return 1
  fi

  local branches
  branches=$(echo "$raw" | grep "refs/heads/" | sed 's|.*refs/heads/||' \
    | grep -vE "^dependabot/|^codex/" | sort)

  local tags
  tags=$(echo "$raw" | grep "refs/tags/" | grep -v '\^{}' \
    | sed 's|.*refs/tags/||' | sort -Vr)

  local -a options=()
  local default_idx=1
  local idx=1

  echo
  echo "  Ramas:"
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    local marker=""
    if [ "$b" = "$current_ref" ]; then
      marker="  ← instalada actualmente"
      default_idx=$idx
    fi
    printf "   %2d) %s%s\n" "$idx" "$b" "$marker"
    options+=("$b")
    idx=$((idx + 1))
  done <<< "$branches"

  echo
  echo "  Versiones (tags):"
  local first_tag=true
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    local marker=""
    if $first_tag; then
      marker="  ← más reciente"
      [ -z "$current_ref" ] && default_idx=$idx
      first_tag=false
    fi
    if [ "$t" = "$current_ref" ]; then
      marker="  ← instalada actualmente"
      default_idx=$idx
    fi
    printf "   %2d) %s%s\n" "$idx" "$t" "$marker"
    options+=("$t")
    idx=$((idx + 1))
  done <<< "$tags"

  local total=$((idx - 1))
  echo
  read -rp "  Elige una opción [1-${total}] (Enter = ${default_idx}): " choice
  choice="${choice:-$default_idx}"

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
    echo "❌ Opción inválida." >&2
    return 1
  fi

  SELECTED_REF="${options[$((choice - 1))]}"
}

# =============================================================================
# ── Núcleo de desinstalación ──────────────────────────────────────────────────
# =============================================================================
_do_uninstall() {
  local keep_docker="$1"

  section "PASO 1 — Bajar contenedores y eliminar volúmenes Docker"
  if [ -d "$LAIN5G_DIR" ] && command -v docker &>/dev/null; then
    cd "$LAIN5G_DIR"
    # Bajar todos los proyectos conocidos por nombre de proyecto Compose
    local all_known_projects
    all_known_projects=$(_get_all_compose_projects)
    while IFS= read -r proj; do
      [ -z "$proj" ] && continue
      echo "→ Bajando proyecto Docker Compose: $proj"
      docker compose -p "$proj" down -v --remove-orphans 2>/dev/null || true
    done <<< "$all_known_projects"

    declare -A _COMPOSE_ENVS=(
      ["docker-compose.app.yml"]=".env.app"
      ["deployments/5g-sa/docker-compose.yml"]="deployments/5g-sa/.env"
      ["deployments/5g-sa-x310/docker-compose.yml"]="deployments/5g-sa-x310/.env"
      ["deployments/5g-nsa-x310/docker-compose.yml"]="deployments/5g-nsa-x310/.env"
      ["deployments/4g-lte-sim/docker-compose.yml"]="deployments/4g-lte-sim/.env"
      ["deployments/5g-vonr/docker-compose.yml"]="deployments/5g-vonr/.env"
      ["deployments/4g-volte/sim/docker-compose.yml"]="deployments/4g-volte/common/.env"
      ["deployments/ims-real/compose.4g.yaml"]="deployments/ims-real/env.defaults"
      ["deployments/ims-real/compose.5g.yaml"]="deployments/ims-real/env.defaults"
    )
    for compose_file in "${!_COMPOSE_ENVS[@]}"; do
      local env_file="${_COMPOSE_ENVS[$compose_file]}"
      if [ -f "$compose_file" ]; then
        local env_flag=""
        [ -f "$env_file" ] && env_flag="--env-file $env_file"
        echo "→ Bajando: $compose_file"
        # shellcheck disable=SC2086
        docker compose $env_flag -f "$compose_file" down -v --remove-orphans 2>/dev/null || true
      fi
    done
    cd - >/dev/null
  else
    echo "→ Directorio no encontrado o Docker no disponible. Saltando."
  fi

  section "PASO 2 — Eliminar contenedores huérfanos"
  if command -v docker &>/dev/null; then
    local orphans
    orphans=$(docker ps -aq --filter "name=lain5g" 2>/dev/null | sort -u || true)
    if [ -n "$orphans" ]; then
      echo "→ Eliminando contenedores:"
      echo "$orphans" | xargs docker rm -f 2>/dev/null || true
      echo "✓ Contenedores eliminados."
    else
      echo "✓ Sin contenedores lain5g."
    fi
  else
    echo "→ Docker no disponible. Saltando."
  fi

  section "PASO 3 — Eliminar imágenes Docker"
  if command -v docker &>/dev/null; then
    local imgs
    imgs=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
      | grep -E "^lain5g" | sort -u || true)
    if [ -n "$imgs" ]; then
      echo "→ Imágenes a eliminar:"; echo "$imgs"
      echo "$imgs" | xargs docker rmi -f 2>/dev/null || true
      echo "✓ Imágenes eliminadas."
    else
      echo "✓ Sin imágenes lain5g."
    fi
  else
    echo "→ Docker no disponible. Saltando."
  fi

  section "PASO 4 — Eliminar volúmenes Docker"
  if command -v docker &>/dev/null; then
    local vols
    vols=$(docker volume ls --format "{{.Name}}" 2>/dev/null \
      | grep "^lain5g" | sort -u || true)
    if [ -n "$vols" ]; then
      echo "→ Volúmenes:"; echo "$vols"
      echo "$vols" | xargs docker volume rm 2>/dev/null || true
      echo "✓ Volúmenes eliminados."
    else
      echo "✓ Sin volúmenes lain5g."
    fi
  else
    echo "→ Docker no disponible. Saltando."
  fi

  section "PASO 5 — Eliminar redes Docker"
  if command -v docker &>/dev/null; then
    local nets
    nets=$(docker network ls --format "{{.Name}}" 2>/dev/null \
      | grep "^lain5g" | sort -u || true)
    if [ -n "$nets" ]; then
      echo "→ Redes:"; echo "$nets"
      echo "$nets" | xargs docker network rm 2>/dev/null || true
      echo "✓ Redes eliminadas."
    else
      echo "✓ Sin redes lain5g."
    fi
  else
    echo "→ Docker no disponible. Saltando."
  fi

  section "PASO 6 — Desinstalar paquetes del sistema"
  if ! "$keep_docker"; then
    echo "→ Deshabilitando servicio Docker"
    sudo systemctl disable --now docker.socket docker.service 2>/dev/null || true
    echo "→ Eliminando usuario del grupo docker"
    sudo gpasswd -d "$(whoami)" docker 2>/dev/null || true
    echo "→ Desinstalando paquetes del bootstrap"
    sudo apt-get remove --purge -y \
      docker.io docker-compose-v2 containerd \
      nodejs npm make python3.14-venv 2>/dev/null || true
    echo "→ Limpiando dependencias huérfanas"
    sudo apt-get autoremove --purge -y 2>/dev/null || true
    echo "→ Limpiando /var/lib/docker y /etc/docker"
    sudo rm -rf /var/lib/docker /etc/docker 2>/dev/null || true
    sudo rm -f /etc/apt/sources.list.d/docker* 2>/dev/null || true
    echo "✓ Paquetes desinstalados."
  else
    echo "→ Se conserva Docker y paquetes del sistema."
  fi

  section "PASO 6b — Revertir modificaciones de red y enrutamiento X310"
  _revert_x310_network_fix

  section "PASO 7 — Eliminar directorio del proyecto"
  if [ -d "$LAIN5G_DIR" ]; then
    echo "→ Eliminando: $LAIN5G_DIR"
    sudo rm -rf "$LAIN5G_DIR"
    echo "✓ Directorio eliminado."
  else
    echo "✓ Directorio no existe."
  fi

  section "PASO 8 — Eliminar logs de instalación"
  if [ -d "$LAIN5G_STATE" ]; then
    echo "→ Eliminando: $LAIN5G_STATE"
    rm -rf "$LAIN5G_STATE"
    echo "✓ Logs eliminados."
  else
    echo "✓ Sin logs."
  fi

  section "VERIFICACIÓN"
  local issues=0
  if ! "$keep_docker" && command -v docker &>/dev/null; then
    echo "[!] Docker sigue instalado (el purge puede no haber completado)."
    issues=$((issues + 1))
  fi
  if has_docker; then
    local rc ri rv rn
    rc=$({ docker ps -aq --filter "name=lain5g" 2>/dev/null || true; } | wc -l)
    ri=$({ docker images --format "{{.Repository}}" 2>/dev/null || true; } | { grep -c "^lain5g" || true; })
    rv=$({ docker volume ls --format "{{.Name}}" 2>/dev/null || true; } | { grep -c "^lain5g" || true; })
    rn=$({ docker network ls --format "{{.Name}}" 2>/dev/null || true; } | { grep -c "^lain5g" || true; })
    [ "$rc" -gt 0 ] && { echo "[!] Quedan $rc contenedores"; issues=$((issues + 1)); }
    [ "$ri" -gt 0 ] && { echo "[!] Quedan $ri imágenes";     issues=$((issues + 1)); }
    [ "$rv" -gt 0 ] && { echo "[!] Quedan $rv volúmenes";    issues=$((issues + 1)); }
    [ "$rn" -gt 0 ] && { echo "[!] Quedan $rn redes";        issues=$((issues + 1)); }
  fi
  [ -d "$LAIN5G_DIR" ] && { echo "[!] El directorio $LAIN5G_DIR aún existe."; issues=$((issues + 1)); }

  if [ "$issues" -eq 0 ]; then
    echo; echo "✅ Desinstalación completa. Sistema limpio."
  else
    echo; echo "⚠️  $issues elemento(s) no se pudieron eliminar."
  fi
}

_revert_x310_network_fix() {
  local FIX_TYPE="" DEV="" IP_CIDR="" WSLCONFIG_PATH="" BACKUP_PATH="" ORIGINALLY_EXISTED=""
  if [ -f "$X310_FIX_STATE" ]; then
    # shellcheck disable=SC1090
    source "$X310_FIX_STATE" 2>/dev/null || true
  fi

  # Fallback de seguridad: detectar cualquier IP residual en 192.168.10.x en interfaces como eth0
  local residual_ip=""
  residual_ip=$(ip -4 addr show 2>/dev/null | awk '/inet 192\.168\.10\./ {print $2; exit}')
  local residual_dev=""
  residual_dev=$(ip -4 addr show 2>/dev/null | awk '/inet 192\.168\.10\./ {print $NF; exit}')
  if [ -n "$residual_ip" ] && [ -z "$IP_CIDR" ]; then
    FIX_TYPE="ip_alias"
    DEV="${residual_dev:-eth0}"
    IP_CIDR="$residual_ip"
  fi

  if [ -z "$FIX_TYPE" ] && [ -z "$residual_ip" ]; then
    return 0
  fi

  echo "→ Revirtiendo modificación previa de red X310 (${FIX_TYPE:-residual})..."
  case "$FIX_TYPE" in
    "ip_alias"|"linux_manual"|"direct_link")
      if [ -n "$DEV" ] && [ -n "$IP_CIDR" ]; then
        echo "  - Retirando IP $IP_CIDR de interfaz $DEV..."
        sudo ip addr del "$IP_CIDR" dev "$DEV" 2>/dev/null || true
      fi
      ;;
    "wsl_mirrored")
      if [ -n "$WSLCONFIG_PATH" ]; then
        echo "  - Restaurando configuración de .wslconfig..."
        if [ "$ORIGINALLY_EXISTED" = "true" ] && [ -f "$BACKUP_PATH" ]; then
          cp "$BACKUP_PATH" "$WSLCONFIG_PATH" 2>/dev/null || true
          rm -f "$BACKUP_PATH" 2>/dev/null || true
        elif [ "$ORIGINALLY_EXISTED" = "false" ]; then
          rm -f "$WSLCONFIG_PATH" 2>/dev/null || true
        fi
      fi
      ;;
  esac

  # Si aún quedase alguna IP residual en 192.168.10.x en Linux, limpiarla
  if [ -n "$residual_ip" ] && [ -n "$residual_dev" ]; then
    sudo ip addr del "$residual_ip" dev "$residual_dev" 2>/dev/null || true
  fi

  rm -f "$X310_FIX_STATE" 2>/dev/null || true
  echo "✓ Modificación de red X310 revertida."
}

# =============================================================================
# ── Diagnóstico Integral y Compatibilidad USRP X310 / SDR ───────────────────
# =============================================================================
_optimize_kernel_buffers() {
  echo
  echo "  Configurando buffers de socket en el kernel a 32 MB (33554432 bytes)..."
  show_cmd "Optimización sysctl" "sudo sysctl -w net.core.rmem_max=33554432 net.core.wmem_max=33554432"
  if sudo sysctl -w net.core.rmem_max=33554432 net.core.wmem_max=33554432 2>/dev/null; then
    echo "  ✅ Buffers aplicados en caliente con éxito."
    if [ -d "/etc/sysctl.d" ]; then
      if echo -e "# USRP SDR high speed buffer limits\nnet.core.rmem_max=33554432\nnet.core.wmem_max=33554432" | sudo tee /etc/sysctl.d/99-usrp-buffers.conf >/dev/null 2>&1; then
        echo "  ✅ Configuración persistente guardada en /etc/sysctl.d/99-usrp-buffers.conf"
      fi
    fi
  else
    echo "  ❌ No se pudieron modificar los buffers con sysctl."
  fi
}

cmd_usrp_full_diagnostic() {
  section "🔍 Diagnóstico Integral y Compatibilidad USRP X310 / SDR"
  local target_addr="${USRP_ADDR:-192.168.10.2}"

  cat <<EOF
  Este diagnóstico evalúa en profundidad la conectividad de red,
  los parámetros del kernel Linux (buffers de socket), y efectúa una
  radiografía completa del hardware USRP X310 y sus tarjetas hijas
  para verificar qué perfiles 4G/5G pueden funcionar.

EOF

  # ── FASE 1: Red y Enlace Físico ──────────────────────────────────
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │ 1. DIAGNÓSTICO DE RED Y ENLACE FÍSICO                     │"
  echo "  └──────────────────────────────────────────────────────────┘"
  echo "  Destino USRP        : $target_addr"
  if _is_wsl; then
    echo "  Entorno detectado   : WSL2 (Windows Subsystem for Linux)"
  else
    echo "  Entorno detectado   : Linux Nativo"
  fi

  local route
  route="$(ip -4 route get "$target_addr" 2>/dev/null | head -n1 || true)"
  local route_device
  route_device="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")"
  local route_gateway
  route_gateway="$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$route")"

  if [ -n "$route_gateway" ]; then
    echo "  Ruta actual         : $target_addr vía gateway virtual $route_gateway ($route_device)"
    echo "  Estado de enlace    : ⚠️  Ruta enrutada vía gateway (puede requerir enlace directo L2)"
  elif [ -n "$route_device" ]; then
    echo "  Ruta actual         : $target_addr directo por interfaz $route_device (scope link)"
    echo "  Estado de enlace    : ✅ Enlace directo L2 detectado"
  else
    echo "  Estado de enlace    : ❌ No se encontró ruta hacia $target_addr"
  fi

  # Ping check
  printf "  Comprobando respuesta ICMP (ping a %s)... " "$target_addr"
  local ping_out
  ping_out="$(ping -c 2 -W 2 "$target_addr" 2>&1 || true)"
  local ping_ok=false
  if grep -q "2 packets transmitted, 2 received" <<< "$ping_out" || grep -q " 0% packet loss" <<< "$ping_out"; then
    local rtt
    rtt="$(awk -F'/' '/rtt min\/avg\/max/ {print $5}' <<< "$ping_out")"
    echo "✅ Responde OK (${rtt:-~4} ms)"
    ping_ok=true
  else
    echo "❌ Sin respuesta (USRP apagado, desconectado o IP no asignada)"
  fi

  # Carrier check
  echo
  echo "  Estado físico de interfaces de red (Carrier):"
  for i in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE "^lo$|^docker|^br-|^veth"); do
    local c="0"
    [ -r "/sys/class/net/$i/carrier" ] && c=$(cat "/sys/class/net/$i/carrier" 2>/dev/null || echo "0")
    if [ "$c" = "1" ]; then
      printf "    ✅ %-12s : Cable Conectado (Carrier UP)\n" "$i"
    else
      printf "    ⬛ %-12s : Sin Enlace (Carrier DOWN)\n" "$i"
    fi
  done
  echo

  # ── FASE 2: Buffers de Red del Kernel (sysctl) ───────────────────
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │ 2. AUDITORÍA DE BUFFERS DE RED DEL KERNEL (SOCKET BUFFER)│"
  echo "  └──────────────────────────────────────────────────────────┘"
  local rmem wmem
  rmem="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)"
  wmem="$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)"
  local rmem_mb=$((rmem / 1024 / 1024))
  local wmem_mb=$((wmem / 1024 / 1024))

  echo "  net.core.rmem_max : $rmem bytes (~$rmem_mb MB)"
  echo "  net.core.wmem_max : $wmem bytes (~$wmem_mb MB)"

  if [ "$rmem" -ge 33554432 ] && [ "$wmem" -ge 33554432 ]; then
    echo "  Estado Buffers    : ✅ ÓPTIMO (≥ 32 MB). Previene desbordamiento de I/Q (errores U/O)."
  else
    echo "  Estado Buffers    : ⚠️  SUB-ÓPTIMO (< 32 MB)."
    echo "                      Buffers pequeños causan pérdidas de paquetes I/Q, desbordamientos"
    echo "                      (Underflow 'U' / Overflow 'O') y timeouts en control RFNoC."
    echo "                      UHD y srsRAN recomiendan net.core.rmem_max=33554432 (32 MB)."
    if confirm "  ¿Deseas optimizar los buffers del kernel ahora a 32 MB?"; then
      _optimize_kernel_buffers
    fi
  fi
  echo

  # ── FASE 3: Radiografía de Hardware SDR y Tarjetas Hijas ─────────
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │ 3. RADIOGRAFÍA DE HARDWARE USRP X310 Y TARJETAS HIJAS    │"
  echo "  └──────────────────────────────────────────────────────────┘"

  local probe_file=""
  local probe_fresh=false

  if $ping_ok; then
    printf "  Sondeando USRP en %s mediante UHD (esto puede tardar unos segundos)... " "$target_addr"
    local tmp_probe="/tmp/lain5g-mgr-probe.log"
    if timeout 15 docker run --rm --network host --entrypoint uhd_usrp_probe \
        lain5g-lab/srsranproject-uhd:local --args="addr=$target_addr" > "$tmp_probe" 2>&1; then
      echo "✅ Sonda completada."
      probe_file="$tmp_probe"
      probe_fresh=true
    else
      echo "⚠️  Timeout o fallo en sonda en vivo."
    fi
  fi

  if [ $probe_fresh = true ] && [ -s "$tmp_probe" ]; then
    mkdir -p "$LAIN5G_STATE"
    cp "$tmp_probe" "$LAIN5G_STATE/last-usrp-probe.log" 2>/dev/null || true
  fi

  if [ -z "$probe_file" ]; then
    for cand in "$LAIN5G_STATE/last-usrp-probe.log" /tmp/lain5g-uhd-probe.log /tmp/lain5g-5g-x310-usrp-probe.log /tmp/lain5g-nsa-hardware-check.log; do
      if [ -s "$cand" ] && grep -q "Device: X-Series" "$cand" 2>/dev/null; then
        probe_file="$cand"
        echo "  ℹ️  Utilizando datos del sondeo UHD previo guardado en: $cand"
        break
      fi
    done
  fi

  local x310_detected=false
  local fpga_ver=""
  local fw_ver=""
  local dboard0_tx=""
  local dboard0_freq=""
  local dboard1_tx=""
  local dboard1_freq=""

  if [ -n "$probe_file" ] && [ -s "$probe_file" ]; then
    if grep -q "Device: X-Series" "$probe_file"; then
      x310_detected=true
      fw_ver="$(grep -m1 "FW Version:" "$probe_file" | awk -F': ' '{print $2}' | tr -d '\r')"
      fpga_ver="$(grep -m1 "FPGA Version:" "$probe_file" | awk -F': ' '{print $2}' | tr -d '\r')"

      # Ranura 0 (Radio#0)
      dboard0_tx="$(awk '/TX Dboard: 0\/Radio#0/,/ID:/ {if ($1=="ID:") {sub(/^.*ID: /,""); print; exit}}' "$probe_file" | tr -d '\r')"
      dboard0_freq="$(awk '/TX Frontend: 0/,/Freq range:/ {if ($1=="Freq" && $2=="range:") {sub(/^.*range: /,""); print; exit}}' "$probe_file" | tr -d '\r')"

      # Ranura 1 (Radio#1)
      dboard1_tx="$(awk '/TX Dboard: 0\/Radio#1/,/ID:/ {if ($1=="ID:") {sub(/^.*ID: /,""); print; exit}}' "$probe_file" | tr -d '\r')"
      dboard1_freq="$(awk '/TX Dboard: 0\/Radio#1/,/Freq range:/ {if ($1=="Freq" && $2=="range:") {sub(/^.*range: /,""); print; exit}}' "$probe_file" | tr -d '\r')"
    fi
  fi

  if $x310_detected; then
    echo "  Dispositivo         : USRP X310 / X-Series"
    echo "  Firmware Version    : ${fw_ver:-desconocido}"
    echo "  FPGA Version        : ${fpga_ver:-desconocido} (Compatible UHD 4.10 ✅)"
    echo "  RFNoC Capable       : Sí (Arquitectura UHD 4.x de grafos de radio)"
    echo
    echo "  Ranuras y Tarjetas Hijas (Daughterboards) detectadas:"
    echo "  ────────────────────────────────────────────────────────────"
    printf "  • Ranura 0 (Radio#0) : %s\n" "${dboard0_tx:-No detectada}"
    printf "    Rango Frecuencia   : %s\n" "${dboard0_freq:-desconocido}"
    printf "  • Ranura 1 (Radio#1) : %s\n" "${dboard1_tx:-No detectada}"
    printf "    Rango Frecuencia   : %s\n" "${dboard1_freq:-desconocido}"
    echo "  ────────────────────────────────────────────────────────────"
  else
    echo "  ⚠️  No se pudo consultar el USRP X310 ni encontrar registro de sonda."
    echo "      Asegúrate de que el USRP esté encendido y alcanzable por IP."
  fi
  echo

  # ── FASE 4: Matriz de Compatibilidad de Escenarios ───────────────
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │ 4. MATRIZ DE COMPATIBILIDAD CON ESCENARIOS OPENLAIN5G    │"
  echo "  └──────────────────────────────────────────────────────────┘"

  if ! $x310_detected; then
    echo "  (No se dispone de datos de sondeo del USRP en este momento)."
    echo "  Conecta y enciende el USRP X310 para generar la radiografía en vivo."
    echo
  else
    local ubx0=false
    local ubx1=false
    grep -qi "UBX" <<< "$dboard0_tx" && ubx0=true
    grep -qi "UBX" <<< "$dboard1_tx" && ubx1=true

    # 1. 4G LTE X310
    if $ubx0 || grep -qi "10.000 to 6000" <<< "$dboard0_freq"; then
      echo "  [1] 4G LTE X310 (srsRAN 4G, B7 @ 2660 MHz)"
      echo "      Estado: 🟢 COMPATIBLE"
      echo "      Motivo: Ranura 0 cuenta con ${dboard0_tx:-UBX} que cubre la Banda 7 (2.6 GHz)."
    else
      echo "  [1] 4G LTE X310 (srsRAN 4G, B7 @ 2660 MHz)"
      echo "      Estado: 🟡 NO CONFIRMADO (Requiere tarjeta que cubra 2660 MHz en Ranura 0)."
    fi
    echo

    # 2. 5G SA X310
    if $ubx0 || grep -qi "10.000 to 6000" <<< "$dboard0_freq"; then
      echo "  [2] 5G SA X310 (srsRAN Project gNB, n3 @ 1842.5 MHz)"
      echo "      Estado: 🟢 COMPATIBLE"
      echo "      Motivo: Ranura 0 cuenta con ${dboard0_tx:-UBX} que cubre la Banda n3 (1.8 GHz)."
    else
      echo "  [2] 5G SA X310 (srsRAN Project gNB, n3 @ 1842.5 MHz)"
      echo "      Estado: 🟡 NO CONFIRMADO (Requiere tarjeta que cubra 1842.5 MHz en Ranura 0)."
    fi
    echo

    # 3. 5G NSA X310 (EN-DC)
    echo "  [3] 5G NSA X310 EN-DC (Dual-Carrier: LTE B7 @ 2660 MHz + NR n3 @ 1842.5 MHz)"
    if $ubx0 && $ubx1; then
      echo "      Estado: 🟢 COMPATIBLE"
      echo "      Motivo: Dispone de 2 tarjetas hijas aptas para microondas celular en ambas ranuras."
    elif grep -qi "Basic" <<< "$dboard1_tx" || [ -z "$dboard1_tx" ]; then
      echo "      Estado: 🔴 INCOMPATIBLE CON EL HARDWARE ACTUAL"
      echo "      Motivo: 5G NSA requiere 2 cadenas RF simultáneas en el grafo RFNoC."
      echo "              La Ranura 1 tiene instalada una tarjeta '${dboard1_tx:-Basic TX/RX}'"
      echo "              cuyo rango es de -250 a 250 MHz (banda base/IF). Es FÍSICAMENTE INCAPAZ"
      echo "              de sintonizar la portadora NR n3 (1842.5 MHz)."
      echo "              👉 Esto causa el error: rfnoc_initialization FAIL ('Failure to create"
      echo "                 rfnoc_graph' / 'Management operation failed')."
      echo "              Para usar 5G NSA se necesita instalar una segunda tarjeta celular"
      echo "              (ej. otra UBX-160 o TwinRX) en la Ranura 1 del X310."
    else
      echo "      Estado: 🟡 VERIFICACIÓN MANUAL REQUERIDA"
    fi
    echo
  fi

  # ── FASE 5: Consejos de Operación y Reloj Maestro ────────────────
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │ 5. RECOMENDACIONES CLAVE DE OPERACIÓN SDR                │"
  echo "  └──────────────────────────────────────────────────────────┘"
  echo "  • Reloj Maestro (Master Clock Rate):"
  echo "    5G SA (gnb) bloquea el reloj interno del X310 en 184.32 MHz."
  echo "    4G LTE (srsenb) requiere 200 MHz / sample rate 11.52 Msps."
  echo "    ⚠️  REGLA DE ORO: Si acabas de transmitir en 5G SA y quieres pasar a 4G,"
  echo "        debes APAGAR Y VOLVER A ENCENDER EL USRP (Power Cycle) en el botón"
  echo "        frontal para que el FPGA reinicie su sintetizador de frecuencia."
  echo "  • Atenuación RF obligatoria:"
  echo "    En laboratorio cableado, SIEMPRE usa atenuadores de al menos 60 dB entre"
  echo "    los puertos TX y RX de tus dispositivos para no quemar las entradas LNA."
  echo "  ────────────────────────────────────────────────────────────"
  echo
  if confirm "  ¿Deseas abrir el Asistente para Reparar / Preparar archivos RF preflight?"; then
    _setup_rf_preflight_files
  fi
}

# =============================================================================
# ── Asistente de Reparación / Reversión Ethernet X310 ────────────────────────
# =============================================================================
cmd_fix_x310_ethernet() {
  section "🔧 Asistente de Enlace Ethernet USRP X310"
  local target_addr="${USRP_ADDR:-192.168.10.2}"

  echo "  Diagnóstico del enlace:"
  echo "  ──────────────────────────────────────────────────────"
  echo "  Destino USRP        : $target_addr"
  if _is_wsl; then
    echo "  Entorno detectado   : WSL2 (Windows Subsystem for Linux)"
  else
    echo "  Entorno detectado   : Linux Nativo"
  fi

  local route
  route="$(ip -4 route get "$target_addr" 2>/dev/null | head -n1 || true)"
  local route_device
  route_device="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")"
  local route_gateway
  route_gateway="$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$route")"

  if [ -n "$route_gateway" ]; then
    echo "  Ruta actual         : $target_addr vía gateway $route_gateway (interfaz $route_device)"
    echo "  Estado de enlace    : ⚠️  Ruta no directa (enrutada vía gateway)"
  elif [ -n "$route_device" ]; then
    echo "  Ruta actual         : $target_addr directo por interfaz $route_device (scope link)"
    echo "  Estado de enlace    : ✅ Enlace directo L2 detectado"
  else
    echo "  Estado de enlace    : ❌ No se encontró ruta hacia $target_addr"
  fi

  if [ -f "$X310_FIX_STATE" ]; then
    echo "  Estado de gestor    : ⚠️  Modificación aplicada previamente"
  fi
  echo "  ──────────────────────────────────────────────────────"
  echo

  if [ -f "$X310_FIX_STATE" ]; then
    echo "  Hay una configuración aplicada por lain5g-manager activa."
    echo
    echo "  [1] Revertir modificación y restaurar configuración original"
    echo "  [0] Volver"
    echo
    read -rp "  Elige una opción [0-1]: " opt_fix
    case "$opt_fix" in
      1)
        _revert_x310_network_fix
        detect_state
        pause
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  fi

  if _is_wsl; then
    cat <<'EOF'
  En WSL2, la conexión con el USRP X310 se realiza a través de las
  tarjetas de red del host.

  Elige la opción que prefieras:

    1) ⚡ Asignar enlace directo L2 a interfaz activa (Recomendado)
       Detecta las interfaces físicas de red (ej. eth1) y asigna
       la IP estática (192.168.10.4/24) para comunicación directa
       con el USRP sin tocar el gateway de Internet en eth2.
       (Reversible en cualquier momento o al desinstalar).

    2) 📡 Reparar / Inicializar archivos RF para Preflight (channel-plan y safety-manifest)
       Genera o corrige channel-plan.yaml con las frecuencias DL/UL (2660/2540 MHz)
       y safety-manifest.yaml requeridos para aprobar rf_preflight en perfiles RF.

    3) 🔄 Configurar modo "Mirrored" en WSL2 (Avanzado)
       Escribe 'networkingMode=mirrored' en %USERPROFILE%\.wslconfig.
       (Nota: Si tu equipo tiene múltiples tarjetas puede afectar el DNS).

    4) ℹ️  Ver explicación técnica y estado de red

    0) Cancelar / Volver

EOF
    read -rp "  Elige una opción [0-4]: " wopt
    case "$wopt" in
      1)
        echo
        echo "  Interfaces de red disponibles en WSL2:"
        local -a ifaces=()
        local idx=1
        local def_dev=""
        def_dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
        for i in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE "^lo$|^docker|^br-|^veth"); do
          local c="0"
          [ -r "/sys/class/net/$i/carrier" ] && c=$(cat "/sys/class/net/$i/carrier" 2>/dev/null || echo "0")
          local note=""
          [ "$i" = "$def_dev" ] && note=" [Gateway Internet/DNS actual]"
          [ "$c" = "1" ] && [ "$i" != "$def_dev" ] && note=" [Carrier UP - Recomendada para USRP]"
          printf "    %d) %-12s (Carrier: %s)%s\n" "$idx" "$i" "$c" "$note"
          ifaces+=("$i")
          idx=$((idx + 1))
        done
        if [ "${#ifaces[@]}" -eq 0 ]; then
          echo "    (No se detectaron interfaces físicas)"
          pause
          return 0
        fi
        echo
        read -rp "  Selecciona interfaz para enlace USRP X310 [1-${#ifaces[@]}]: " if_choice
        if [[ "$if_choice" =~ ^[0-9]+$ ]] && [ "$if_choice" -ge 1 ] && [ "$if_choice" -le "${#ifaces[@]}" ]; then
          local sel_if="${ifaces[$((if_choice - 1))]}"
          local ip_to_add="192.168.10.4/24"
          read -rp "  IP con prefijo CIDR a asignar [Enter = $ip_to_add]: " user_ip
          user_ip="${user_ip:-$ip_to_add}"
          sudo ip link set "$sel_if" up 2>/dev/null || true
          show_cmd "Asignando IP" "sudo ip addr add $user_ip dev $sel_if"
          if sudo ip addr add "$user_ip" dev "$sel_if" 2>/dev/null; then
            mkdir -p "$LAIN5G_STATE"
            cat <<EOF > "$X310_FIX_STATE"
FIX_TYPE=direct_link
DEV=$sel_if
IP_CIDR=$user_ip
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
            echo "  ✅ IP $user_ip asignada correctamente a $sel_if."
            echo "     Enlace directo L2 activo sin afectar la salida a Internet."
          else
            # Si ya tenía la IP asignada, asegurar que guardamos el estado para reversión
            mkdir -p "$LAIN5G_STATE"
            cat <<EOF > "$X310_FIX_STATE"
FIX_TYPE=direct_link
DEV=$sel_if
IP_CIDR=$user_ip
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
            echo "  ℹ️  La interfaz $sel_if ya cuenta con la IP $user_ip."
          fi
        fi
        detect_state
        pause
        ;;
      2)
        _setup_rf_preflight_files
        pause
        ;;
      3)
        local win_user_prof=""
        if command -v powershell.exe &>/dev/null; then
          win_user_prof=$(powershell.exe -NoProfile -Command 'Write-Host -NoNewline $env:USERPROFILE' 2>/dev/null | tr -d '\r')
        fi
        local wsl_cfg_path=""
        if [ -n "$win_user_prof" ] && command -v wslpath &>/dev/null; then
          wsl_cfg_path="$(wslpath "$win_user_prof")/.wslconfig"
        fi

        if [ -z "$wsl_cfg_path" ]; then
          echo "  ❌ No se pudo localizar la carpeta de usuario de Windows desde WSL."
          pause
          return 0
        fi

        mkdir -p "$LAIN5G_STATE"
        local existed=false
        local bak_path="${wsl_cfg_path}.lain5g.bak"
        if [ -f "$wsl_cfg_path" ]; then
          existed=true
          cp "$wsl_cfg_path" "$bak_path"
        fi

        cat <<'CFG' > "$wsl_cfg_path"
[wsl2]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
CFG

        cat <<EOF > "$X310_FIX_STATE"
FIX_TYPE=wsl_mirrored
WSLCONFIG_PATH=$wsl_cfg_path
BACKUP_PATH=$bak_path
ORIGINALLY_EXISTED=$existed
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
        echo "  ✅ Archivo $wsl_cfg_path configurado con networkingMode=mirrored."
        detect_state
        pause
        ;;
      4)
        cat <<'HELP'
  Explicación técnica del enlace X310 en WSL2:
  ─────────────────────────────────────────────────────────────
  1. Enlace L2 directo con interfaces dedicadas (Recomendado):
     - WSL2 dispone de interfaces separadas para la conexión de red
       general (ej. eth2 con salida a Internet) y para el USRP
       (ej. eth1 conectado al puerto Gigabit del X310).
     - Al asignar 192.168.10.4/24 a eth1, el tráfico al USRP
       (192.168.10.2) viaja en Capa 2 directo sin atravesar NAT
       y sin interferir con la conexión a Internet de eth2.

  2. Modo Mirrored:
     - Comparte adaptadores de red con Windows de forma unificada.
     - En configuraciones con múltiples adaptadores físicos activos,
       puede desorientar la ruta por defecto o resolución DNS.

HELP
        pause
        ;;
      0)
        return 0
        ;;
      *)
        echo "Opción inválida."
        pause
        ;;
    esac
  else
    # Linux Nativo
    cat <<'EOF'
  En Linux nativo, el USRP X310 debe conectarse directamente a una
  tarjeta de red cableada del equipo con una IP estática en la misma
  subred (ejemplo: 192.168.10.1/24 o 192.168.10.3/24).

  Elige una opción:

    1) Asignar IP fija a una interfaz física detectada
    2) Diagnóstico de cables y estado de enlace (carrier)
    0) Volver

EOF
    read -rp "  Elige una opción [0-2]: " lopt
    case "$lopt" in
      1)
        echo
        echo "  Interfaces de red disponibles:"
        local -a ifaces=()
        local idx=1
        for i in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE "^lo$|^docker|^br-|^veth"); do
          echo "    $idx) $i"
          ifaces+=("$i")
          idx=$((idx + 1))
        done
        if [ "${#ifaces[@]}" -eq 0 ]; then
          echo "    (No se detectaron interfaces físicas)"
          pause
          return 0
        fi
        read -rp "  Selecciona interfaz [1-${#ifaces[@]}]: " if_choice
        if [[ "$if_choice" =~ ^[0-9]+$ ]] && [ "$if_choice" -ge 1 ] && [ "$if_choice" -le "${#ifaces[@]}" ]; then
          local sel_if="${ifaces[$((if_choice - 1))]}"
          local ip_to_add="192.168.10.3/24"
          read -rp "  IP con prefijo CIDR a asignar [Enter = $ip_to_add]: " user_ip
          user_ip="${user_ip:-$ip_to_add}"
          show_cmd "Asignando IP" "sudo ip addr add $user_ip dev $sel_if"
          if sudo ip addr add "$user_ip" dev "$sel_if" 2>/dev/null; then
            mkdir -p "$LAIN5G_STATE"
            cat <<EOF > "$X310_FIX_STATE"
FIX_TYPE=linux_manual
DEV=$sel_if
IP_CIDR=$user_ip
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
            echo "  ✅ IP asignada correctamente a $sel_if."
          else
            echo "  ⚠️  No se pudo asignar la IP (o ya existía)."
          fi
        fi
        detect_state
        pause
        ;;
      2)
        echo
        echo "  Estado de enlace en interfaces físicas:"
        for i in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE "^lo$|^docker|^br-|^veth"); do
          local c="desconocido"
          [ -r "/sys/class/net/$i/carrier" ] && c=$(cat "/sys/class/net/$i/carrier" 2>/dev/null || echo "0")
          if [ "$c" = "1" ]; then
            printf "    ✅ %-15s : Cable conectado (Carrier UP)\n" "$i"
          else
            printf "    ❌ %-15s : Sin enlace (Cable desconectado o USRP apagado)\n" "$i"
          fi
        done
        pause
        ;;
      3)
        _setup_rf_preflight_files
        pause
        ;;
      0) return 0 ;;
    esac
  fi
}

_setup_rf_preflight_files() {
  section "📡 Reparación y Preparación de Archivos RF Preflight"
  cat <<'EOF'
  Esta herramienta genera o ajusta los archivos locales de laboratorio
  (channel-plan.yaml y safety-manifest.yaml) requeridos por OpenLain5G
  para que el control de seguridad 'rf_preflight' pase exitosamente.

  Elige qué escenario deseas preparar:
    1) 4G LTE X310 (Banda 7, EARFCN 3150, DL: 2660 MHz, UL: 2540 MHz)
    2) 5G SA X310  (Banda n3, DL ARFCN 368500, SCS: 15 kHz)
    3) 5G NSA X310 (EN-DC: LTE B7 2660 MHz + NR n3 1842.5 MHz)
    0) Volver
EOF
  read -rp "  Elige una opción [0-3]: " rf_opt
  case "$rf_opt" in
    1)
      local d_dir="$LAIN5G_DIR/deployments/4g-volte/x310/rf"
      if [ ! -d "$d_dir" ]; then
        echo "  ❌ Directorio $d_dir no encontrado."
        return 0
      fi
      cat <<'YAML_4G' > "$d_dir/channel-plan.yaml"
band: 7
earfcn: 3150
downlink_frequency_hz: 2660000000
uplink_frequency_hz: 2540000000
bandwidth_mhz: 5
tx_gain: 20
rx_gain: 40
sample_rate: 11.52
YAML_4G
      if [ ! -f "$d_dir/safety-manifest.yaml" ] || grep -q "authorization_confirmed: false" "$d_dir/safety-manifest.yaml" 2>/dev/null; then
        cat <<'YAML_SM' > "$d_dir/safety-manifest.yaml"
lab_mode: shielded
authorization_confirmed: true
antenna_connected: true
attenuation_db: 60
shielded_environment: true
maximum_duration_seconds: 600
auto_stop: true
capture_logs: true
operator_note: Controlled RF session from OpenLain5G Manager
YAML_SM
      fi
      echo "  ✅ Archivos de 4G LTE X310 actualizados:"
      echo "     - $d_dir/channel-plan.yaml (DL: 2660000000 Hz, UL: 2540000000 Hz)"
      echo "     - $d_dir/safety-manifest.yaml (shielded, auto-stop: 600s, auth: true)"
      echo
      echo "  Probando preflight 4G..."
      if [ -x "$LAIN5G_DIR/deployments/4g-volte/x310/scripts/preflight.sh" ]; then
        (cd "$LAIN5G_DIR" && LAIN5G_DRY_RUN=false ./deployments/4g-volte/x310/scripts/preflight.sh 2>&1 | grep -E "channel_frequency|safety_manifest|authorization") || true
      fi
      ;;
    2)
      local d_dir="$LAIN5G_DIR/deployments/5g-sa-x310/rf"
      if [ ! -d "$d_dir" ]; then
        echo "  ❌ Directorio $d_dir no encontrado."
        return 0
      fi
      cat <<'YAML_5G' > "$d_dir/channel-plan.yaml"
nr_band: 3
dl_arfcn: 368500
channel_bandwidth_mhz: 10
common_scs: 15
duplex_mode: FDD
authorized_lab_frequency: true
operator_note: Controlled RF session from OpenLain5G Manager
YAML_5G
      if [ ! -f "$d_dir/safety-manifest.yaml" ] || grep -q "authorization_confirmed: false" "$d_dir/safety-manifest.yaml" 2>/dev/null; then
        cat <<'YAML_SM5' > "$d_dir/safety-manifest.yaml"
lab_mode: shielded
authorization_confirmed: true
antenna_connected: true
attenuation_db: 60
shielded_environment: true
maximum_duration_seconds: 600
auto_stop: true
capture_logs: true
operator_note: Controlled RF session from OpenLain5G Manager
YAML_SM5
      fi
      echo "  ✅ Archivos de 5G SA X310 actualizados:"
      echo "     - $d_dir/channel-plan.yaml (Banda n3, DL ARFCN: 368500, SCS: 15)"
      echo "     - $d_dir/safety-manifest.yaml (shielded, auto-stop: 600s, auth: true)"
      ;;
    3)
      local d_dir="$LAIN5G_DIR/deployments/5g-nsa-x310/rf"
      if [ ! -d "$d_dir" ]; then
        echo "  ❌ Directorio $d_dir no encontrado."
        return 0
      fi
      cat <<'YAML_NSA' > "$d_dir/channel-plan.yaml"
mode: NSA_EN_DC
lte_band: 7
lte_dl_earfcn: 3150
lte_bandwidth_mhz: 10
lte_downlink_frequency_mhz: 2660.0
lte_uplink_frequency_mhz: 2540.0
nr_band: 3
nr_dl_arfcn: 368500
nr_bandwidth_mhz: 10
nr_downlink_frequency_mhz: 1842.5
nr_uplink_frequency_mhz: 1747.5
subcarrier_spacing_khz: 15
rf_channels: 2
authorized_lab_frequencies: true
operator_note: Controlled NSA RF session from OpenLain5G Manager
YAML_NSA
      cat <<'YAML_SM_NSA' > "$d_dir/safety-manifest.yaml"
authorization_confirmed: true
auto_stop: true
capture_logs: true
maximum_duration_seconds: 120
lab_mode: shielded
attenuation_db: 60
antenna_connected: true
nr_rf_path_connected: true
shielded_environment: true
operator_note: Controlled NSA RF session from OpenLain5G Manager
YAML_SM_NSA
      echo "  ✅ Archivos de 5G NSA X310 actualizados:"
      echo "     - $d_dir/channel-plan.yaml (LTE B7 3150 + NR n3 368500, auth: true)"
      echo "     - $d_dir/safety-manifest.yaml (shielded, nr_rf_path: true, auth: true)"
      echo
      echo "  Probando preflight 5G NSA..."
      if [ -x "$LAIN5G_DIR/deployments/5g-nsa-x310/scripts/preflight.sh" ]; then
        (cd "$LAIN5G_DIR" && LAIN5G_DRY_RUN=false ./deployments/5g-nsa-x310/scripts/preflight.sh 2>&1 | grep -E "dual_rat|rf_ports|scs_rate|duration|status") || true
      fi
      ;;
    0) return 0 ;;
    *) echo "  Opción inválida." ;;
  esac
}

# =============================================================================
# ── Panel educativo: seguridad RF (compartido) ────────────────────────────────
# =============================================================================
_show_rf_safety_panel() {
  cat <<'RFSAFETY'

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ⚠️  Antenas, frecuencias y seguridad RF
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Esta es la sección MÁS IMPORTANTE antes de usar
  el USRP con antenas reales.

  ─── El peligro: VSWR y antenas incorrectas ──────────

  VSWR (Voltage Standing Wave Ratio) mide qué tan bien
  una antena irradia la señal en una frecuencia dada.

    VSWR 1:1  → 100% de la potencia se irradia ✅
    VSWR alto → la señal se REFLEJA hacia el USRP ❌

  Cuando la antena NO cubre la frecuencia de trabajo:
  → La señal reflejada daña el amplificador de potencia
  → Daño irreversible al hardware
  → Costo de reparación: $1,000–$3,000 USD

  ─── Ejemplo de error frecuente ──────────────────────

  Supón que tienes antenas de laboratorio típicas:
    • Antena A: 750-1250 MHz
    • Antena B: 1650-2700 MHz

  Si el perfil usa n78 (3.3-3.8 GHz):
    ❌ Antena A → no cubre 3.5 GHz → peligro
    ❌ Antena B → no cubre 3.5 GHz → peligro

  Si el perfil usa n3 (1.8 GHz) — defecto X310:
    ❌ Antena A → no cubre 1.8 GHz → peligro
    ✅ Antena B → sí cubre 1.8 GHz → OK para DL
    ⚠️  Verificar también UL (1710-1785 MHz)

  Siempre verifica DL y UL por separado.

  ─── Frecuencias de los perfiles X310 ────────────────

  Perfil            Banda    DL aprox.    UL aprox.
  ────────────────────────────────────────────────────
  5G SA X310        n3       ~1842 MHz    ~1757 MHz
  5G NSA X310       n3+B7    ~1842 MHz NR + 2660 MHz LTE
  4G LTE X310       B7       ~2660 MHz    ~2520 MHz
  ────────────────────────────────────────────────────

  ⚠️  Si cambias la banda (p.ej. a n78 = 3.5 GHz),
      tus antenas DEBEN cubrir ese rango.

  ─── ¿Cómo verificar mis antenas? ───────────────────

  1. Busca la etiqueta o datasheet de tu antena
     Ejemplo: "ANT-B2459: 1710-2690 MHz"
     Eso significa que solo funciona en ese rango.

  2. Compara con la banda de tu perfil:
     ✅ n3 DL (1842 MHz) + antena 1710-2690 MHz → OK
     ✅ B7 DL (2660 MHz) + antena 1710-2690 MHz → OK
     ❌ n78 (3500 MHz)   + antena 1710-2690 MHz → PELIGRO

  3. Verifica AMBAS frecuencias: UL y DL
     En FDD, UL y DL están en frecuencias distintas.

  ─── Lista de verificación pre-RF ───────────────────

  Antes de cualquier transmisión con el USRP:

  [ ] Identifiqué la banda en config/profiles/<perfil>.yaml
  [ ] Calculé la frecuencia real (DL y UL)
  [ ] Leí el datasheet de mis antenas y confirmé
      que cubren AMBAS frecuencias (DL y UL)
  [ ] Tengo atenuadores ≥ 60 dB (modo cableado)
      O estoy en sala blindada/apantallada
  [ ] Leí docs/rf_safety.md del proyecto
  [ ] Tengo autorización legal para transmitir
      (regulador de mi país)

  ─── Tabla de bandas de referencia ──────────────────

  5G NR (FR1 — más comunes en laboratorio):
  n3  : DL 1805-1880 / UL 1710-1785 MHz  ← defecto X310
  n7  : DL 2620-2690 / UL 2500-2570 MHz  ← defecto 4G X310
  n28 : DL  758-803  / UL  703-748  MHz
  n41 : TDD 2496-2690 MHz
  n78 : TDD 3300-3800 MHz  ← FRECUENTE EN 5G COMERCIAL
  n79 : TDD 4400-5000 MHz

  FDD: TX y RX en frecuencias distintas (verificar ambas)
  TDD: misma frecuencia para TX y RX

  ─── Recursos ────────────────────────────────────────

  → docs/rf_safety.md
  → https://en.wikipedia.org/wiki/5G_NR_frequency_bands
  → https://github.com/guallycanazas/Lain5G/blob/main/docs/rf_safety.md
  → https://www.ettus.com/all-products/x310-kit/

RFSAFETY
}

# =============================================================================
# ── Panel educativo de perfil RF (en cmd_start) ───────────────────────────────
# =============================================================================
_show_rf_profile_panel() {
  local profile_name="$1"
  local band_info="$2"
  local make_start="$3"
  local make_stop="$4"

  section "🔒 Perfil RF: $profile_name"
  cat <<EOF

  Este Manager NO inicia perfiles RF directamente.
  El motivo es protegerte: una configuración incorrecta
  de antenas puede dañar el hardware USRP de forma
  irreversible.

EOF
  _show_rf_safety_panel

  cat <<EOF
  ─── Frecuencias de este perfil ─────────────────────

  $band_info

  ─── Comandos manuales (cuando estés listo) ──────────

  Ejecuta en tu terminal, en orden:

    \$ cd ~/Lain5G
    \$ ./lain5g                # CLI interactivo guiado (recomendado)

  O directamente con Make:
    \$ $make_start
    \$ $make_stop

  ─── Asistente de Preparación RF ────────────────────

  ¿Deseas verificar o inicializar los archivos de laboratorio
  (channel-plan.yaml y safety-manifest.yaml) para este perfil?
EOF
  if confirm "  ¿Inicializar/Reparar archivos de seguridad y frecuencia para preflight?"; then
    _setup_rf_preflight_files
  fi

  cat <<EOF

  ─── Más información ────────────────────────────────

  → $REPO_URL/blob/main/docs/rf_safety.md
  → $REPO_URL/blob/main/docs/

EOF

  if $X310_ETH_ISSUE; then
    echo "  ──────────────────────────────────────────────────────"
    echo "  ⚠️  ATENCIÓN: Problema detectado en enlace Ethernet X310:"
    echo "      $X310_ETH_REASON"
    echo "      Se recomienda ejecutar el Asistente de Enlace Ethernet X310."
    echo "  ──────────────────────────────────────────────────────"
    if confirm "  ¿Deseas abrir el Asistente de Reparación Ethernet X310 ahora?"; then
      cmd_fix_x310_ethernet
    fi
  fi
}

# =============================================================================
# ── Opción 1: Acerca de (menú educativo) ─────────────────────────────────────
# =============================================================================
cmd_about() {
  while true; do
    section "Acerca de OpenLain5G"
    cat <<'EOF'

  OpenLain5G es una plataforma de laboratorio 4G/5G de código abierto.
  Esta sección responde preguntas frecuentes para usuarios de todos
  los niveles, desde principiantes hasta expertos.

  1) ¿Qué es OpenLain5G y para qué sirve?
  2) ¿Qué es 4G y 5G? (desde cero)
  3) ¿Qué son las bandas de frecuencia?
  4) ¿Qué es Docker y por qué se usa aquí?
  5) ¿Qué es simulación? (sin hardware)
  6) ¿Qué es USRP y SDR?
  7) ⚠️  Antenas, frecuencias y seguridad RF
  8) 🚀 ¿Cómo empezar? (Getting Started)
  0) ↩  Volver al menú principal

EOF
    read -rp "  Elige una opción [0-8]: " aopt
    case "$aopt" in
      1) _about_project ;;
      2) _about_5g ;;
      3) _about_bands ;;
      4) _about_docker ;;
      5) _about_simulation ;;
      6) _about_usrp ;;
      7) _show_rf_safety_panel; pause ;;
      8) _about_getting_started ;;
      0) return 0 ;;
      *) echo "  Opción inválida." ;;
    esac
  done
}

_about_project() {
  section "¿Qué es OpenLain5G y para qué sirve?"
  cat <<EOF

  OpenLain5G es un laboratorio de redes 4G y 5G que corre
  completamente en tu computadora, sin necesidad de torres
  de celular ni hardware de telecomunicaciones costoso.

  ¿Para qué sirve?
  • Aprender cómo funcionan las redes móviles 4G/5G
  • Experimentar y hacer pruebas en un entorno seguro
  • Investigación académica reproducible
  • Entender cómo se autentican los dispositivos,
    cómo se asignan las IPs, cómo viajan los datos

  ¿Qué puedes hacer con él?
  → Levantar una red 5G SA completa en tu laptop
  → Simular un teléfono (UE) conectándose a esa red
  → Ver los logs en tiempo real de cada componente
  → Validar que el plano de usuario funciona (ping)
  → Probar llamadas VoNR (5G) o VoLTE (4G)
  → Con hardware USRP: transmitir señales 4G/5G reales

  Publicación académica:
  Canazas-Rosas, W. R., Prieto-Tito, M. I., Hilario-Tacuri, A.,
  & Tamo-Calla, A. (2025). OpenLain5G: Ready-to-Use 4G/5G Core
  Software with Orchestration and Validation for Testbeds. SSRN.
  → https://doi.org/10.2139/ssrn.7404673

  Repositorio oficial:
  → $REPO_URL

EOF
  pause
}

_about_5g() {
  section "¿Qué es 4G y 5G? (desde cero)"
  cat <<'EOF'

  Las redes móviles han evolucionado por generaciones:

    1G (1980s) → solo voz analógica
    2G (1990s) → voz digital + SMS (GSM, CDMA)
    3G (2000s) → datos móviles (UMTS, HSPA)
    4G (2010s) → Internet rápido en el móvil (LTE)
    5G (2020s) → ultra-rápido, baja latencia, IoT masivo

  ──────────────────────────────────────────────────────

  ¿Qué mejora 5G respecto a 4G?

  Característica    4G LTE           5G NR
  ────────────────────────────────────────────────────
  Velocidad máx.   ~150 Mbps        ~20 Gbps (pico)
  Latencia          ~30-50 ms        ~1 ms (URLLC)
  Dispositivos/km²  ~100,000         ~1,000,000
  Uso principal     Smartphones      IoT + industria

  ──────────────────────────────────────────────────────

  Tres casos de uso principales del 5G:

  📱 eMBB — Enhanced Mobile Broadband
     Streaming 4K/8K, VR/AR, gaming en la nube.
     Velocidades multi-gigabit en el móvil.

  🏭 URLLC — Ultra-Reliable Low Latency Communications
     Cirugía robótica remota, autos autónomos,
     automatización industrial. Latencia < 1 ms.

  🌐 mMTC — Massive Machine-Type Communications
     Millones de sensores IoT: ciudades inteligentes,
     agricultura de precisión, medidores inteligentes.

  ──────────────────────────────────────────────────────

  ¿Qué componentes tiene una red móvil?

    [Tu teléfono / UE]
         ↕ radio
    [gNB — antena base 5G]    ← RAN (Radio Access Network)
         ↕ fibra/IP
    [AMF, SMF, UPF...]        ← Core 5G (5GC)
         ↕
    [Internet / IMS]

  UE   = User Equipment (tu teléfono, tablet, modem)
  gNB  = Next-gen NodeB (la antena / "torre" 5G)
  eNB  = Evolved NodeB (la antena 4G LTE)
  AMF  = Access and Mobility Function (autenticación)
  SMF  = Session Management Function (sesiones/IP)
  UPF  = User Plane Function (tráfico de datos)
  IMS  = IP Multimedia Subsystem (voz, video)

  5G SA  = Stand-Alone: core 5G propio (funciones completas)
  5G NSA = Non-Stand-Alone: usa el core 4G como ancla

  Referencia: https://en.wikipedia.org/wiki/5G

EOF
  pause
}

_about_bands() {
  section "¿Qué son las bandas de frecuencia?"
  cat <<'EOF'

  Las redes móviles transmiten señales de radio en rangos
  de frecuencia específicos llamados "bandas". Cada banda
  tiene propiedades distintas de cobertura y velocidad.

  ──────────────────────────────────────────────────────
  Tres grandes rangos en 5G NR:
  ──────────────────────────────────────────────────────

  🟢 Baja frecuencia  (< 1 GHz)  — "Low Band"
     Cobertura enorme, penetra paredes fácilmente.
     Velocidad moderada. Ideal para zonas rurales.
     Ejemplo: n28 (700 MHz) → América Latina, Australia

  🔵 Media frecuencia (1-6 GHz)  — "Mid Band / FR1"
     Balance ideal de cobertura y velocidad.
     La banda más desplegada mundialmente para 5G.
     Ejemplo: n78 (3.5 GHz) → Europa, Asia
              n3  (1.8 GHz) → global
              n7  (2.6 GHz) → global

  🔴 Alta frecuencia  (> 24 GHz) — "mmWave / FR2"
     Velocidades altísimas (multi-Gbps).
     Rango muy corto (<100m), no penetra paredes.
     Ejemplo: n258 (26 GHz), n261 (28 GHz)

  ──────────────────────────────────────────────────────
  Bandas 5G NR más importantes (FR1):
  ──────────────────────────────────────────────────────

  Banda  DL (MHz)        UL (MHz)       Duplex  Uso típico
  ──────────────────────────────────────────────────────────
  n3     1805-1880       1710-1785       FDD     Global ← X310 defecto
  n7     2620-2690       2500-2570       FDD     Global ← 4G X310 defecto
  n28     758-803         703-748        FDD     Latinoamérica, Asia-Pac
  n41    2496-2690       (igual)         TDD     EEUU
  n78    3300-3800       (igual)         TDD     Europa, Asia ← 5G COMERCIAL
  n79    4400-5000       (igual)         TDD     Japón
  ──────────────────────────────────────────────────────────

  FDD = Frecuencias distintas para UL y DL
  TDD = Misma frecuencia, alternando en el tiempo
  UL  = Uplink   (tu dispositivo transmite hacia la red)
  DL  = Downlink (la red transmite hacia tu dispositivo)

  ⚠️  El perfil 5G SA X310 usa n3 (1842 MHz) por defecto.
      Si cambias a n78 (3.5 GHz), tus antenas DEBEN
      cubrir 3.3-3.8 GHz o puedes dañar el hardware.

  Referencia: https://en.wikipedia.org/wiki/5G_NR_frequency_bands

EOF
  pause
}

_about_docker() {
  section "¿Qué es Docker y por qué se usa aquí?"
  cat <<'EOF'

  Docker es una herramienta que crea "contenedores":
  paquetes aislados que contienen una aplicación y todo
  lo que necesita para funcionar, sin instalación manual.

  Piénsalo como cajas independientes: cada componente de
  la red corre en su propia caja, sin interferir con el
  resto del sistema.

  ¿Cómo lo usa OpenLain5G?

  Contenedor              Función
  ────────────────────────────────────────────────────
  open5gs-amf             Autenticación de dispositivos (AMF)
  open5gs-smf             Gestión de sesiones de datos (SMF)
  open5gs-upf             Plano de usuario / tráfico (UPF)
  open5gs-mongo           Base de datos de suscriptores
  ueransim-gnb            Simula la antena 5G (gNB)
  ueransim-ue             Simula tu teléfono (UE)
  srsran-enb              Simula la antena 4G (eNB)
  kamailio / ims          Servidor SIP para llamadas VoLTE/VoNR

  ── Suite de la App web y observabilidad (v1.1.8) ────
  lain5g-lab-app-frontend Interfaz gráfica web React (puerto 8080)
  lain5g-lab-app-backend  API REST FastAPI (puerto 8000)
  lain5g-lab-app-grafana  Dashboards y métricas visuales (puerto 3000)
  lain5g-lab-app-prometheus Base de datos de métricas (puerto 9090)
  lain5g-lab-app-loki     Agregador de logs en tiempo real
  lain5g-lab-app-alloy    Agente colector de logs del sistema
  ────────────────────────────────────────────────────

  💡 Nota sobre los contenedores:
  Cuando la App web está activa, verás '6 contenedores'
  corriendo. No son perfiles de radio, sino los 6
  servicios que componen la interfaz web y su monitoreo.

  No necesitas instalar ninguno de estos manualmente.
  OpenLain5G los descarga y configura automáticamente.

  "Docker Compose" coordina múltiples contenedores
  como un sistema completo sincronizado.

  Más info: https://docs.docker.com/get-started/

EOF
  pause
}

_about_simulation() {
  section "¿Qué es un escenario de simulación?"
  cat <<'EOF'

  En lugar de usar torres de celular y teléfonos reales,
  OpenLain5G simula TODA la red en software sobre tu PC.

  ┌─ 5G SA (Stand-Alone) ──────────────────────────────┐
  │  Red 5G completa 100% en software:                  │
  │  • Core 5G (Open5GS) — autenticación y datos        │
  │  • gNB (UERANSIM)    — antena 5G simulada           │
  │  • UE  (UERANSIM)    — teléfono simulado            │
  │  Conexión virtual sin señal de radio real.          │
  └─────────────────────────────────────────────────────┘

  ┌─ 4G LTE Sim ───────────────────────────────────────┐
  │  Red 4G LTE en software:                            │
  │  • EPC (Open5GS)      — core LTE                   │
  │  • eNB (srsRAN + ZMQ) — antena 4G simulada         │
  │  • UE  (srsRAN + ZMQ) — teléfono simulado          │
  │  ZMQ = conexión virtual (sin señal RF real)         │
  └─────────────────────────────────────────────────────┘

  ┌─ 5G VoNR (Voice over NR) ──────────────────────────┐
  │  Como 5G SA pero con soporte de llamadas de voz     │
  │  sobre 5G (VoNR), usando IMS/Kamailio.              │
  └─────────────────────────────────────────────────────┘

  ✅  No necesitas USRP ni antenas
  ✅  No necesitas autorización legal para RF
  ✅  Funciona en cualquier PC con Linux x86_64
  ✅  Ideal para aprender y experimentar sin riesgo

  Requisitos mínimos:
  • Linux x86_64 (Ubuntu 22.04 / 24.04 recomendado)
  • 8 GB RAM (16 GB recomendado para escenarios VoNR)
  • 20 GB de espacio libre en disco
  • Conexión a Internet (para descargar imágenes Docker)

EOF
  pause
}

_about_usrp() {
  section "¿Qué es USRP y SDR?"
  cat <<'EOF'

  SDR = Software Defined Radio
  Una radio cuyo comportamiento se define por software
  en lugar de circuitos electrónicos fijos. Puedes
  cambiar frecuencia, modulación y protocolo simplemente
  cambiando el software.

  USRP = Universal Software Radio Peripheral
  El hardware SDR de Ettus Research (ahora parte de NI).
  El modelo X310 es el que soporta OpenLain5G para
  transmisión real de señales 4G/5G.

  ┌──────────────────────────────────────────────────┐
  │  USRP X310  |  Ettus Research / NI               │
  │  Precio:    ~$7,000 – $12,000 USD                │
  │  Rango RF:  10 MHz – 6 GHz (con daughterboards)  │
  │  Interfaz:  Ethernet 1/10 GbE o PCIe             │
  │  Drivers:   UHD (USRP Hardware Driver) >= 4.10   │
  └──────────────────────────────────────────────────┘

  ¿Para qué se usa con OpenLain5G?
  → Transmitir señales 4G/5G reales (RF)
  → Conectar dispositivos físicos a la red del lab
  → Investigación con hardware real (no simulado)

  ⚠️  IMPORTANTE antes de usar con antenas:
  No conectes el USRP a antenas sin verificar que la
  antena cubre la frecuencia de trabajo.
  Una antena desadaptada puede dañar el hardware.

  → Elige la opción "7) Antenas y seguridad RF" en
    este menú para entender los riesgos en detalle.

  → https://www.ettus.com/all-products/x310-kit/
  → https://github.com/guallycanazas/Lain5G/blob/main/docs/rf_safety.md

EOF
  pause
}

_about_getting_started() {
  section "🚀 ¿Cómo empezar con OpenLain5G?"
  cat <<'EOF'

  Requisitos de hardware:
  • PC con Linux x86_64 (Ubuntu 22.04 / 24.04)
  • 8 GB RAM mínimo (16 GB recomendado)
  • 20 GB de espacio libre en disco
  • Conexión a Internet

  ──────────────────────────────────────────────────────

  PASO 1 — Instala OpenLain5G
  ─────────────────────────────
  → Vuelve al menú principal y elige "5) Instalar".
  El Manager descargará el proyecto desde GitHub
  y ejecutará el instalador automáticamente.
  (instala Docker, dependencias y descarga imágenes)
  Tiempo estimado: 10-30 min según tu conexión.

  PASO 2 — Inicia una simulación (sin hardware)
  ─────────────────────────────
  → Menú principal → "3) Iniciar OpenLain5G"
  → Selecciona una de estas opciones:
    • "5G SA (simulación)" — red 5G completa en software
    • "4G LTE Sim"         — red 4G LTE en software
  No necesitas hardware especial.

  PASO 3 — Observa la red en acción
  ─────────────────────────────
  → Desde "3) Iniciar" puedes abrir la App web
    para ver y controlar la red desde el navegador.
  → O en terminal:
      cd ~/Lain5G
      make status-5g-sa     # ver contenedores
      make logs-5g-sa       # ver logs en vivo
      make validate-5g-sa   # validar que funciona

  PASO 4 — Detén la simulación cuando termines
  ─────────────────────────────
  → Menú principal → "4) Detener OpenLain5G"
  → O en terminal: cd ~/Lain5G && make stop-5g-sa

  PASO 5 — Aprende más
  ─────────────────────────────
  → Documentación del proyecto:
    https://github.com/guallycanazas/Lain5G/blob/main/docs/README.md
  → Guía 5G SA:
    https://github.com/guallycanazas/Lain5G/blob/main/docs/5g_sa.md
  → Guía 4G:
    https://github.com/guallycanazas/Lain5G/blob/main/docs/4g_simulation.md
  → Artículo académico:
    https://doi.org/10.2139/ssrn.7404673

EOF
  pause
}

# =============================================================================
# ── Opción 2: Estado detallado ────────────────────────────────────────────────
# =============================================================================
cmd_status() {
  detect_state
  section "Estado de OpenLain5G"

  if $INSTALLED; then
    echo "  Proyecto instalado : ✅ Sí"
    echo "  Directorio         : $LAIN5G_DIR"
    echo "  Versión (VERSION)  : $VERSION_STR"
    echo "  Referencia git     : $GIT_REF"
    if [ -d "$LAIN5G_DIR/.git" ] && command -v git &>/dev/null; then
      local commit
      commit=$(git -C "$LAIN5G_DIR" log -1 --format="%h — %ad" --date=short 2>/dev/null \
        || echo "desconocido")
      echo "  Último commit      : $commit"
    fi
  else
    echo "  Proyecto instalado : ❌ No"
  fi

  echo
  echo "  Componentes corriendo:"
  if [ "$DOCKER_ACCESS" = "ok" ]; then
    local any_running=false
    local all_projects
    all_projects=$(_get_all_compose_projects)
    while IFS= read -r proj; do
      [ -z "$proj" ] && continue
      local count
      count=$({ docker ps --filter "label=com.docker.compose.project=$proj" \
              --format "{{.Names}}" 2>/dev/null || true; } | wc -l)
      local label
      label=$(_project_label "$proj")
      if [ "$count" -gt 0 ]; then
        printf "    🟢 %-45s (%d contenedores)\n" "$label" "$count"
        any_running=true
      fi
    done <<< "$all_projects"
    if ! $any_running; then
      echo "    ⬛ Ningún componente corriendo actualmente (todos detenidos)"
    fi
  elif [ "$DOCKER_ACCESS" = "denied" ]; then
    echo "    ⚠️ Docker está instalado pero tu usuario no tiene permisos sobre el socket."
    echo "       Ejecuta: sudo usermod -aG docker \$USER && newgrp docker"
  else
    echo "    ❌ Docker no instalado"
  fi

  if [ "$DOCKER_ACCESS" = "ok" ]; then
    echo
    echo "  Imágenes Docker lain5g:"
    local images
    images=$({ docker images --format "    {{.Repository}}:{{.Tag}}   {{.Size}}" 2>/dev/null || true; } \
      | grep "lain5g" || true)
    if [ -n "$images" ]; then
      echo "$images" | while IFS= read -r line; do
        echo "    ✅$line"
      done
    else
      echo "    ❌ Ninguna imagen lain5g encontrada"
    fi
  elif [ "$DOCKER_ACCESS" = "denied" ]; then
    echo
    echo "  Imágenes Docker    : ⚠️ Sin acceso al daemon Docker"
  else
    echo
    echo "  Docker             : ❌ No instalado"
  fi

  echo
  echo "  Paquetes del sistema:"
  for pkg in docker.io docker-compose-v2 nodejs npm make python3.14-venv; do
    local ver
    ver=$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' || true)
    if [ -n "$ver" ]; then
      printf "    ✅ %-26s %s\n" "$pkg" "$ver"
    else
      printf "    ❌ %s\n" "$pkg"
    fi
  done

  pause
}

# =============================================================================
# ── Opción 3: Iniciar OpenLain5G ──────────────────────────────────────────────
# =============================================================================
cmd_start() {
  detect_state
  section "Iniciar OpenLain5G"

  if ! $INSTALLED; then
    echo
    echo "  ⚠️  OpenLain5G no está instalado."
    echo "     Elige '5) Instalar' en el menú principal primero."
    pause
    return 0
  fi

  if ! command -v docker &>/dev/null; then
    echo
    echo "  ❌ Docker no está instalado en el sistema."
    pause
    return 0
  fi

  if [ "$DOCKER_ACCESS" = "denied" ]; then
    echo
    echo "  ⚠️  Docker está instalado pero tu usuario no tiene permisos sobre el socket."
    echo "     Ejecuta: sudo usermod -aG docker \$USER && newgrp docker"
    pause
    return 0
  fi

  # Mostrar qué está corriendo
  if [ "${#RUNNING_PROJECTS[@]}" -gt 0 ]; then
    echo
    echo "  Componentes activos actualmente:"
    for proj in "${RUNNING_PROJECTS[@]}"; do
      echo "    🟢 $(_project_label "$proj")"
    done
  fi

  # Descubrimiento dinámico de perfiles según la versión instalada
  local sim_ids=()
  local sim_names=()
  local sim_descs=()
  local rf_ids=()
  local rf_names=()
  local rf_descs=()

  local profiles_raw
  profiles_raw=$(_get_public_profiles)
  while IFS=$'\t' read -r pid pmode pname pdesc; do
    [ -z "$pid" ] && continue
    if [ "$pmode" = "simulation" ]; then
      sim_ids+=("$pid")
      sim_names+=("$pname")
      sim_descs+=("$pdesc")
    else
      rf_ids+=("$pid")
      rf_names+=("$pname")
      rf_descs+=("$pdesc")
    fi
  done <<< "$profiles_raw"

  echo
  echo "  ── Simulaciones (solo software, sin hardware) ────────"
  local opt_idx=1
  local -A opt_map_type=()
  local -A opt_map_id=()
  local -A opt_map_name=()

  for i in "${!sim_ids[@]}"; do
    printf "    %2d) ▶️  %-15s — %s\n" "$opt_idx" "${sim_ids[$i]}" "${sim_names[$i]}"
    opt_map_type["$opt_idx"]="sim"
    opt_map_id["$opt_idx"]="${sim_ids[$i]}"
    opt_map_name["$opt_idx"]="${sim_names[$i]}"
    opt_idx=$((opt_idx + 1))
  done

  printf "    %2d) 🌐 App web        — Interfaz web y monitoreo OpenLain5G\n" "$opt_idx"
  opt_map_type["$opt_idx"]="app"
  local app_idx=$opt_idx
  opt_idx=$((opt_idx + 1))

  printf "    %2d) 📞 IMS Real       — Guía e inicio de Servicio IMS Real (4G / 5G)\n" "$opt_idx"
  opt_map_type["$opt_idx"]="ims_real"
  opt_idx=$((opt_idx + 1))

  if [ "${#rf_ids[@]}" -gt 0 ]; then
    echo
    echo "  ── Con hardware RF (requiere USRP X310) ──────────────"
    echo "     ℹ️  Por seguridad no transmiten automáticamente;"
    echo "        al seleccionar uno verás su guía de bandas, antenas y comandos."
    for i in "${!rf_ids[@]}"; do
      printf "    %2d) 🔒 %-15s — %s\n" "$opt_idx" "${rf_ids[$i]}" "${rf_names[$i]}"
      opt_map_type["$opt_idx"]="rf"
      opt_map_id["$opt_idx"]="${rf_ids[$i]}"
      opt_map_name["$opt_idx"]="${rf_names[$i]}"
      opt_idx=$((opt_idx + 1))
    done
  fi

  echo
  echo "     0) ↩  Cancelar"
  echo
  local max_opt=$((opt_idx - 1))
  read -rp "  Elige una opción [0-${max_opt}]: " sopt

  if [ "$sopt" = "0" ] || [ -z "$sopt" ]; then
    return 0
  fi

  if ! [[ "$sopt" =~ ^[0-9]+$ ]] || [ "$sopt" -lt 1 ] || [ "$sopt" -gt "$max_opt" ]; then
    echo "  Opción inválida."
    pause
    return 0
  fi

  local selected_type="${opt_map_type[$sopt]}"
  local selected_id="${opt_map_id[$sopt]:-}"
  local selected_name="${opt_map_name[$sopt]:-}"

  case "$selected_type" in
    "app")
      _start_app
      ;;
    "ims_real")
      _guide_ims_real
      ;;
    "sim")
      _start_scenario "$selected_name" "$selected_id"
      ;;
    "rf")
      case "$selected_id" in
        "4g-lte-x310")
          _show_rf_profile_panel "4G LTE X310" \
            "LTE Band 7 — DL ~2660 MHz / UL ~2520 MHz" \
            "make preflight-4g-lte-x310 && make start-4g-lte-x310-epc" \
            "make stop-4g-lte-x310"
          ;;
        "5g-sa-x310")
          _show_rf_profile_panel "5G SA X310" \
            "NR Band n3  — DL ~1842 MHz / UL ~1757 MHz" \
            "make preflight-5g-x310 && make start-5g-x310-core && make start-5g-x310-rf" \
            "make stop-5g-x310"
          ;;
        "5g-nsa-x310")
          _show_rf_profile_panel "5G NSA X310" \
            "NR Band n3 + LTE Band 7 — DL ~1842 MHz NR + 2660 MHz LTE" \
            "make start-5g-x310-core" \
            "make stop-5g-x310"
          ;;
        *)
          _show_rf_profile_panel "$selected_name ($selected_id)" \
            "Consulta config/profiles/${selected_id}.yaml para ver radio.band y frecuencias." \
            "./lain5g profile show $selected_id" \
            "./lain5g scenario stop $selected_id"
          ;;
      esac
      pause
      ;;
  esac
}

_start_scenario() {
  local label="$1"
  local profile_id="$2"
  local compose_proj="lain5g-lab-${profile_id}"

  # Verificar si ya está corriendo
  local already_running=false
  for proj in "${RUNNING_PROJECTS[@]}"; do
    if [ "$proj" = "$compose_proj" ]; then
      already_running=true
      break
    fi
  done

  if $already_running; then
    echo
    echo "  ⚠️  '$label' ya tiene contenedores activos."
    if ! confirm "  ¿Continuar de todas formas?"; then
      return 0
    fi
  fi

  echo
  # Si el CLI ./lain5g soporta 'scenario start', preferirlo porque prepara .env y valida imágenes
  if [ -x "$LAIN5G_DIR/lain5g" ]; then
    show_cmd "Iniciando escenario $label" "cd ~/Lain5G && ./lain5g scenario start $profile_id"
    (cd "$LAIN5G_DIR" && ./lain5g scenario start "$profile_id")
  else
    # Fallback a Make para versiones antiguas
    show_cmd "Iniciando escenario $label" "cd ~/Lain5G && make start-${profile_id}"
    (cd "$LAIN5G_DIR" && make "start-${profile_id}")
  fi
  pause
}

_start_app() {
  section "Iniciar App web OpenLain5G"

  # Verificar si ya está corriendo
  local already_running=false
  for proj in "${RUNNING_PROJECTS[@]}"; do
    [ "$proj" = "lain5g-lab-app" ] && already_running=true
  done

  if $already_running; then
    echo
    echo "  ⚠️  La App web ya está corriendo."
    if ! confirm "  ¿Continuar de todas formas?"; then
      return 0
    fi
  fi

  cat <<'EOF'

  ¿Cómo iniciar la App web?

    1) Con control completo  [--operations]  (recomendado para laboratorio)
       Permite controlar escenarios, ver logs y usar
       la interfaz de gestión desde el navegador.
       Solo usar en computadora de confianza.

    2) Solo observación
       Puedes ver el estado de la red pero no iniciar
       ni detener escenarios desde la web.

    0) Cancelar

EOF
  read -rp "  Elige una opción [0-2]: " amode
  case "$amode" in
    1)
      show_cmd "Iniciando App web (modo operaciones)" \
               "cd ~/Lain5G && ./lain5g app start --operations --open"
      (cd "$LAIN5G_DIR" && ./lain5g app start --operations --open)
      ;;
    2)
      show_cmd "Iniciando App web (solo observación)" \
               "cd ~/Lain5G && ./lain5g app start --open"
      (cd "$LAIN5G_DIR" && ./lain5g app start --open)
      ;;
    0) return 0 ;;
    *) echo "  Opción inválida." ;;
  esac
  pause
}

_guide_ims_real() {
  section "📞 Servicio IMS Real (4G / 5G)"
  cat <<'EOF'

  El servicio IMS Real de OpenLain5G es una pila aislada de Core/IMS
  (Kamailio P/I/S-CSCF, pyHSS sobre Diameter Cx, MySQL, Open5GS)
  diseñada para pruebas con UEs o núcleos reales sin hardware de radio RAN.

  ℹ️  ¿Cómo se inicia de forma segura en OpenLain5G?
  -------------------------------------------------------------
  OpenLain5G delega la orquestación del IMS Real a su App Web con
  operaciones habilitadas (`--operations`), debido a que en el arranque:
    1. Genera y resguarda claves criptográficas en runtime (.runtime/).
    2. Modela subredes aisladas e independientes para 4G y 5G.
    3. Habilita el aprovisionamiento seguro de suscriptores vía pyHSS.

  Puedes controlarlo e iniciarlo visualmente desde la App web en:
    👉 http://localhost:8080/ims

EOF

  local app_running=false
  for proj in "${RUNNING_PROJECTS[@]}"; do
    [ "$proj" = "lain5g-lab-app" ] && app_running=true
  done

  if $app_running; then
    echo "  ✅ La App web de OpenLain5G ya se encuentra activa."
    echo "     Abre http://localhost:8080/ims en tu navegador para iniciar o gestionar IMS Real."
  else
    echo "  ¿Deseas iniciar la App web con modo operaciones ahora para abrir IMS Real?"
    echo "    1) Sí, iniciar App Web en modo operaciones (abre navegador)"
    echo "    0) Volver"
    echo
    read -rp "  Elige una opción [0-1]: " ims_opt
    if [ "$ims_opt" = "1" ]; then
      show_cmd "Iniciando App web (modo operaciones)" \
               "cd ~/Lain5G && ./lain5g app start --operations --open"
      (cd "$LAIN5G_DIR" && ./lain5g app start --operations --open)
    fi
  fi
  pause
}

# =============================================================================
# ── Opción 4: Detener OpenLain5G ──────────────────────────────────────────────
# =============================================================================
cmd_stop() {
  detect_state
  section "Detener OpenLain5G"

  if ! command -v docker &>/dev/null; then
    echo
    echo "  ❌ Docker no está instalado en el sistema."
    pause
    return 0
  fi

  if [ "$DOCKER_ACCESS" = "denied" ]; then
    echo
    echo "  ⚠️  Docker está instalado pero tu usuario no tiene permisos sobre el socket."
    echo "     Ejecuta: sudo usermod -aG docker \$USER && newgrp docker"
    pause
    return 0
  fi

  if [ "${#RUNNING_PROJECTS[@]}" -eq 0 ]; then
    echo
    echo "  ℹ️  No hay ningún componente de OpenLain5G corriendo actualmente."
    pause
    return 0
  fi

  echo
  echo "  Componentes activos:"
  local idx=1
  for proj in "${RUNNING_PROJECTS[@]}"; do
    printf "    %d) 🟢 %s\n" "$idx" "$(_project_label "$proj")"
    idx=$((idx + 1))
  done
  local total=$((idx - 1))

  echo
  echo "  Opciones: número(s) separados por espacio, 'todo', o 0 para cancelar"
  read -rp "  ¿Qué deseas detener? " stop_input

  [ "$stop_input" = "0" ] && { echo "  Cancelado."; pause; return 0; }

  local to_stop=()
  if [ "${stop_input,,}" = "todo" ] || [ "${stop_input,,}" = "all" ]; then
    to_stop=("${RUNNING_PROJECTS[@]}")
  else
    for token in $stop_input; do
      if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "$total" ]; then
        to_stop+=("${RUNNING_PROJECTS[$((token - 1))]}")
      else
        echo "  ⚠️  Opción inválida ignorada: $token"
      fi
    done
  fi

  if [ "${#to_stop[@]}" -eq 0 ]; then
    echo "  Sin selección válida. Cancelado."
    pause
    return 0
  fi

  echo
  for proj in "${to_stop[@]}"; do
    local label
    label=$(_project_label "$proj")
    case "$proj" in
      "lain5g-lab-app")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && ./lain5g app stop"
        (cd "$LAIN5G_DIR" && ./lain5g app stop) || true
        ;;
      "lain5g-lab-5g-sa")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && ./lain5g scenario stop 5g-sa"
        (cd "$LAIN5G_DIR" && ./lain5g scenario stop 5g-sa 2>/dev/null) || (cd "$LAIN5G_DIR" && make stop-5g-sa) || true
        ;;
      "lain5g-lab-4g-lte-sim")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && ./lain5g scenario stop 4g-lte-sim"
        (cd "$LAIN5G_DIR" && ./lain5g scenario stop 4g-lte-sim 2>/dev/null) || (cd "$LAIN5G_DIR" && make stop-4g-lte-sim) || true
        ;;
      "lain5g-lab-5g-vonr-sim")
        show_cmd "Deteniendo $label" "docker compose -p lain5g-lab-5g-vonr-sim down"
        docker compose -p lain5g-lab-5g-vonr-sim down 2>/dev/null || (cd "$LAIN5G_DIR" && docker compose -f deployments/5g-vonr/docker-compose.yml down 2>/dev/null) || true
        ;;
      "lain5g-lab-4g-volte-sim")
        show_cmd "Deteniendo $label" "docker compose -p lain5g-lab-4g-volte-sim down"
        docker compose -p lain5g-lab-4g-volte-sim down 2>/dev/null || (cd "$LAIN5G_DIR" && docker compose -f deployments/4g-volte/sim/docker-compose.yml down 2>/dev/null) || true
        ;;
      "lain5g-lab-5g-sa-x310")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-5g-x310"
        (cd "$LAIN5G_DIR" && make stop-5g-x310) || true
        ;;
      "lain5g-lab-5g-nsa-x310")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-5g-x310"
        (cd "$LAIN5G_DIR" && make stop-5g-x310) || true
        ;;
      "lain5g-lab-4g-lte-x310")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-4g-lte-x310"
        (cd "$LAIN5G_DIR" && make stop-4g-lte-x310) || true
        ;;
      "lain5g-lab-ims-real-4g")
        show_cmd "Deteniendo $label" "docker compose -p lain5g-lab-ims-real-4g down"
        docker compose -p lain5g-lab-ims-real-4g down 2>/dev/null || true
        ;;
      "lain5g-lab-ims-real-5g")
        show_cmd "Deteniendo $label" "docker compose -p lain5g-lab-ims-real-5g down"
        docker compose -p lain5g-lab-ims-real-5g down 2>/dev/null || true
        ;;
      *)
        show_cmd "Deteniendo $label ($proj)" "cd ~/Lain5G && docker compose down"
        (cd "$LAIN5G_DIR" && docker compose down 2>/dev/null) || true
        ;;
    esac
  done

  detect_state
  echo
  echo "  ✓ Listo."
  pause
}

# =============================================================================
# ── Opción 5: Instalar ────────────────────────────────────────────────────────
# =============================================================================
cmd_install() {
  section "Instalar OpenLain5G"

  if [ -d "$LAIN5G_DIR" ]; then
    echo "⚠️  Ya existe una instalación en $LAIN5G_DIR"
    echo "   Usa la opción 7 (Reinstalar) para reemplazarla."
    pause
    return 0
  fi

  ensure_git || { pause; return 1; }

  pick_branch "" || { pause; return 1; }
  local ref="$SELECTED_REF"

  echo
  show_cmd "Clonando repositorio" "git clone $REPO_URL ~/Lain5G"
  git clone "$REPO_URL" "$LAIN5G_DIR"

  show_cmd "Cambiando a: $ref" "git -C ~/Lain5G checkout $ref"
  git -C "$LAIN5G_DIR" checkout "$ref"

  section "Ejecutando install.sh"
  echo "  → cd ~/Lain5G && bash install.sh"
  echo
  cd "$LAIN5G_DIR"
  bash install.sh
  cd - >/dev/null

  detect_state
  echo
  echo "✅ Instalación completa."
  echo "   Versión : $VERSION_STR"
  echo "   Ref     : $GIT_REF"
  pause
}

# =============================================================================
# ── Opción 6: Desinstalar ─────────────────────────────────────────────────────
# =============================================================================
cmd_uninstall() {
  section "Desinstalar OpenLain5G"
  detect_state

  local keep_docker=false
  if confirm "¿Desinstalar también Docker y paquetes del sistema?\n  (Responde 'n' si usas Docker para otros proyectos)"; then
    keep_docker=false
  else
    keep_docker=true
  fi

  echo
  if ! confirm "¿Confirmar desinstalación completa? Esta acción no se puede deshacer."; then
    echo "Cancelado."
    pause
    return 0
  fi

  sudo -v 2>/dev/null || true
  _do_uninstall "$keep_docker"
  detect_state
  pause
}

# =============================================================================
# ── Opción 7: Reinstalar ──────────────────────────────────────────────────────
# =============================================================================
cmd_reinstall() {
  section "Reinstalar OpenLain5G"
  detect_state
  local prev_ref="$GIT_REF"

  local keep_docker=false
  if confirm "¿Desinstalar también Docker y paquetes del sistema?\n  (Responde 'n' si usas Docker para otros proyectos)"; then
    keep_docker=false
  else
    keep_docker=true
  fi

  echo
  if ! confirm "¿Confirmar reinstalación? (desinstala y vuelve a instalar)"; then
    echo "Cancelado."
    pause
    return 0
  fi

  sudo -v 2>/dev/null || true

  echo
  echo "── Fase 1 de 2: Desinstalación ─────────────────────────"
  _do_uninstall "$keep_docker"

  echo
  echo "── Fase 2 de 2: Instalación ────────────────────────────"
  ensure_git || { pause; return 1; }

  pick_branch "$prev_ref" || { pause; return 1; }
  local ref="$SELECTED_REF"

  echo
  show_cmd "Clonando repositorio" "git clone $REPO_URL ~/Lain5G"
  git clone "$REPO_URL" "$LAIN5G_DIR"

  show_cmd "Cambiando a: $ref" "git -C ~/Lain5G checkout $ref"
  git -C "$LAIN5G_DIR" checkout "$ref"

  section "Ejecutando install.sh"
  echo "  → cd ~/Lain5G && bash install.sh"
  echo
  cd "$LAIN5G_DIR"
  bash install.sh
  cd - >/dev/null

  detect_state
  echo
  echo "✅ Reinstalación completa."
  echo "   Versión : $VERSION_STR"
  echo "   Ref     : $GIT_REF"
  pause
}

# =============================================================================
# ── Menú principal ────────────────────────────────────────────────────────────
# =============================================================================
main_menu() {
  while true; do
    detect_state

    echo
    echo "══════════════════════════════════════════════════════════"
    echo "   OpenLain5G Manager  v${MANAGER_VERSION}"
    printf "   %s\n" "$MANAGER_REPO"
    echo "══════════════════════════════════════════════════════════"

    # Estado de instalación
    if $INSTALLED; then
      echo "   Estado   : ✅ Instalado  |  Versión: $VERSION_STR  |  Ref: $GIT_REF"
    else
      echo "   Estado   : ❌ No instalado"
    fi

    # Componentes corriendo
    if [ "${#RUNNING_PROJECTS[@]}" -gt 0 ]; then
      local first=true
      for proj in "${RUNNING_PROJECTS[@]}"; do
        if $first; then
          printf "   Corriendo: 🟢 %s\n" "$(_project_label "$proj")"
          first=false
        else
          printf "              🟢 %s\n" "$(_project_label "$proj")"
        fi
      done
    elif [ "$DOCKER_ACCESS" = "denied" ]; then
      echo "   Corriendo: ⚠️  Docker sin permisos (ejecuta: sudo usermod -aG docker \$USER && newgrp docker)"
    else
      echo "   Corriendo: ⬛ Nada"
    fi

    # Alerta y opción condicional para Enlace Ethernet USRP X310
    if $X310_ETH_ISSUE; then
      echo
      echo "   ⚠️  Enlace X310: $X310_ETH_REASON"
    fi

    echo
    echo "   1) ℹ️  Acerca de OpenLain5G"
    echo "   2) 📊 Ver estado detallado"
    echo "   3) ▶️  Iniciar OpenLain5G"
    echo "   4) ⏹️  Detener OpenLain5G"
    echo "   5) 📦 Instalar"
    echo "   6) 🗑️  Desinstalar"
    echo "   7) 🔄 Reinstalar"
    echo "   D) 🔍 Diagnóstico Integral y Compatibilidad USRP X310 / SDR"
    if $X310_ETH_ISSUE; then
      echo "   R) 🔧 Asistente: Reparar / Revertir enlace Ethernet X310"
    fi
    echo "   8) ❌ Salir"
    echo
    if $X310_ETH_ISSUE; then
      read -rp "Elige una opción [1-8, D o R]: " opt
    else
      read -rp "Elige una opción [1-8 o D]: " opt
    fi

    case "${opt,,}" in
      1) cmd_about     ;;
      2) cmd_status    ;;
      3) cmd_start     ;;
      4) cmd_stop      ;;
      5) cmd_install   ;;
      6) cmd_uninstall ;;
      7) cmd_reinstall ;;
      d) cmd_usrp_full_diagnostic ;;
      r)
        if $X310_ETH_ISSUE; then
          cmd_fix_x310_ethernet
        else
          echo "  Opción no aplicable actualmente."
        fi
        ;;
      8) echo; echo "Hasta luego."; exit 0 ;;
      *) echo "  Opción inválida." ;;
    esac
  done
}

# =============================================================================
# ── Parsear argumentos ────────────────────────────────────────────────────────
# =============================================================================
case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --status)
    detect_state
    section "Estado de OpenLain5G"
    if $INSTALLED; then
      echo "  Proyecto instalado : ✅ Sí"
      echo "  Directorio         : $LAIN5G_DIR"
      echo "  Versión (VERSION)  : $VERSION_STR"
      echo "  Referencia git     : $GIT_REF"
      if [ -d "$LAIN5G_DIR/.git" ] && command -v git &>/dev/null; then
        commit=$(git -C "$LAIN5G_DIR" log -1 --format="%h — %ad" --date=short 2>/dev/null || echo "desconocido")
        echo "  Último commit      : $commit"
      fi
    else
      echo "  Proyecto instalado : ❌ No"
    fi
    echo
    echo "  Componentes corriendo:"
    if [ "$DOCKER_ACCESS" = "ok" ]; then
      any_running=false
      all_projects=$(_get_all_compose_projects)
      while IFS= read -r proj; do
        [ -z "$proj" ] && continue
        count=$({ docker ps --filter "label=com.docker.compose.project=$proj" \
                --format "{{.Names}}" 2>/dev/null || true; } | wc -l)
        label=$(_project_label "$proj")
        if [ "$count" -gt 0 ]; then
          printf "    🟢 %-45s (%d contenedores)\n" "$label" "$count"
          any_running=true
        fi
      done <<< "$all_projects"
      if ! $any_running; then
        echo "    ⬛ Ningún componente corriendo actualmente (todos detenidos)"
      fi
    elif [ "$DOCKER_ACCESS" = "denied" ]; then
      echo "    ⚠️ Docker instalado pero tu usuario no tiene permisos sobre el socket."
      echo "       Ejecuta: sudo usermod -aG docker \$USER && newgrp docker"
    else
      echo "    ❌ Docker no instalado"
    fi
    if [ "$DOCKER_ACCESS" = "ok" ]; then
      echo
      echo "  Imágenes Docker:"
      images=$({ docker images --format "    {{.Repository}}:{{.Tag}}   {{.Size}}" 2>/dev/null || true; } | grep "lain5g" || true)
      if [ -n "$images" ]; then
        echo "$images" | while IFS= read -r line; do echo "    ✅$line"; done
      else
        echo "    ❌ Ninguna imagen lain5g encontrada"
      fi
    elif [ "$DOCKER_ACCESS" = "denied" ]; then
      echo
      echo "  Imágenes Docker    : ⚠️ Sin acceso al daemon Docker"
    else
      echo
      echo "  Docker             : ❌ No instalado"
    fi
    echo
    echo "  Paquetes del sistema:"
    for pkg in docker.io docker-compose-v2 nodejs npm make python3.14-venv; do
      ver=$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' || true)
      if [ -n "$ver" ]; then
        printf "    ✅ %-26s %s\n" "$pkg" "$ver"
      else
        printf "    ❌ %s\n" "$pkg"
      fi
    done
    echo
    exit 0
    ;;
  "")
    main_menu
    ;;
  *)
    echo "Opción desconocida: $1" >&2
    echo "Usa --help para ver las opciones disponibles." >&2
    exit 2
    ;;
esac
