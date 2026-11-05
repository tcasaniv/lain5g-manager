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

MANAGER_VERSION="1.1.7"
OPENLAIN5G_COMPAT="1.1.7"
MANAGER_REPO="https://github.com/tcasaniv/lain5g-manager"
REPO_URL="https://github.com/guallycanazas/Lain5G"
LAIN5G_DIR="${HOME}/Lain5G"
LAIN5G_STATE="${HOME}/.local/state/lain5g"
SELECTED_REF=""
INSTALLED=false
VERSION_STR="no instalado"
GIT_REF="—"
RUNNING_PROJECTS=()

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

  # Detectar componentes corriendo via Docker
  if command -v docker &>/dev/null; then
    local projects=(
      "lain5g-lab-app"
      "lain5g-lab-5g-sa"
      "lain5g-lab-4g-lte-sim"
      "lain5g-lab-5g-vonr-sim"
      "lain5g-lab-5g-sa-x310"
      "lain5g-lab-5g-nsa-x310"
    )
    for proj in "${projects[@]}"; do
      local count
      count=$(docker ps --filter "label=com.docker.compose.project=$proj" \
              --format "{{.Names}}" 2>/dev/null | wc -l)
      if [ "$count" -gt 0 ]; then
        RUNNING_PROJECTS+=("$proj")
      fi
    done
  fi
}

# Devuelve la etiqueta legible de un compose project
_project_label() {
  case "$1" in
    "lain5g-lab-app")          echo "App web OpenLain5G" ;;
    "lain5g-lab-5g-sa")        echo "Escenario 5G SA" ;;
    "lain5g-lab-4g-lte-sim")   echo "Escenario 4G LTE Sim" ;;
    "lain5g-lab-5g-vonr-sim")  echo "Escenario 5G VoNR Sim" ;;
    "lain5g-lab-5g-sa-x310")   echo "Escenario 5G SA X310 (RF)" ;;
    "lain5g-lab-5g-nsa-x310")  echo "Escenario 5G NSA X310 (RF)" ;;
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
    declare -A _COMPOSE_ENVS=(
      ["docker-compose.app.yml"]=".env.app"
      ["deployments/5g-sa/docker-compose.yml"]="deployments/5g-sa/.env"
      ["deployments/5g-sa-x310/docker-compose.yml"]="deployments/5g-sa-x310/.env"
      ["deployments/5g-nsa-x310/docker-compose.yml"]="deployments/5g-nsa-x310/.env"
      ["deployments/4g-lte-sim/docker-compose.yml"]="deployments/4g-lte-sim/.env"
      ["deployments/5g-vonr/docker-compose.yml"]="deployments/5g-vonr/.env"
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
  if command -v docker &>/dev/null; then
    local rc ri rv rn
    rc=$(docker ps -aq --filter "name=lain5g" 2>/dev/null | wc -l)
    ri=$(docker images --format "{{.Repository}}" 2>/dev/null | { grep -c "^lain5g" || true; })
    rv=$(docker volume ls --format "{{.Name}}" 2>/dev/null | { grep -c "^lain5g" || true; })
    rn=$(docker network ls --format "{{.Name}}" 2>/dev/null | { grep -c "^lain5g" || true; })
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

  ─── Más información ────────────────────────────────

  → $REPO_URL/blob/main/docs/rf_safety.md
  → $REPO_URL/blob/main/docs/

EOF
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
  ────────────────────────────────────────────────────

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
  if command -v docker &>/dev/null; then
    local known_projects=(
      "lain5g-lab-app"
      "lain5g-lab-5g-sa"
      "lain5g-lab-4g-lte-sim"
      "lain5g-lab-5g-vonr-sim"
      "lain5g-lab-5g-sa-x310"
      "lain5g-lab-5g-nsa-x310"
    )
    local any_running=false
    for proj in "${known_projects[@]}"; do
      local count
      count=$(docker ps --filter "label=com.docker.compose.project=$proj" \
              --format "{{.Names}}" 2>/dev/null | wc -l)
      local label
      label=$(_project_label "$proj")
      if [ "$count" -gt 0 ]; then
        printf "    🟢 %-30s (%d contenedores)\n" "$label" "$count"
        any_running=true
      else
        printf "    ⬛ %-30s (detenido)\n" "$label"
      fi
    done
  else
    echo "    Docker no instalado"
  fi

  if command -v docker &>/dev/null; then
    echo
    echo "  Imágenes Docker lain5g:"
    local images
    images=$(docker images --format "    {{.Repository}}:{{.Tag}}   {{.Size}}" 2>/dev/null \
      | grep "lain5g" || true)
    if [ -n "$images" ]; then
      echo "$images" | while IFS= read -r line; do
        echo "    ✅$line"
      done
    else
      echo "    ❌ Ninguna imagen lain5g encontrada"
    fi
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
    echo "  ❌ Docker no está disponible. ¿Está instalado OpenLain5G?"
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

  cat <<'EOF'

  ── Simulaciones (solo software, sin hardware) ────────
     1) ▶️  5G SA     — 5G Stand-Alone con UERANSIM
     2) ▶️  4G LTE    — 4G LTE con srsRAN (ZMQ)
     3) ▶️  5G VoNR   — 5G con llamadas Voice over NR
     4) 🌐 App web   — Interfaz web OpenLain5G

  ── Con hardware RF (requiere USRP X310) ──────────────
     5) 🔒 4G LTE X310  — Requiere hardware USRP + antenas
     6) 🔒 5G SA  X310  — Requiere hardware USRP + antenas
     7) 🔒 5G NSA X310  — Requiere hardware USRP + antenas

     0) ↩  Cancelar

EOF
  read -rp "  Elige una opción [0-7]: " sopt

  case "$sopt" in
    1) _start_scenario "5G SA" "lain5g-lab-5g-sa" \
         "make -C ~/Lain5G start-5g-sa" "make -C ~/Lain5G stop-5g-sa" \
         "start-5g-sa" ;;
    2) _start_scenario "4G LTE Sim" "lain5g-lab-4g-lte-sim" \
         "make -C ~/Lain5G start-4g-lte-sim" "make -C ~/Lain5G stop-4g-lte-sim" \
         "start-4g-lte-sim" ;;
    3) _start_scenario "5G VoNR Sim" "lain5g-lab-5g-vonr-sim" \
         "make -C ~/Lain5G start-5g-vonr-sim" "make -C ~/Lain5G stop-5g-vonr-sim" \
         "start-5g-vonr-sim" ;;
    4) _start_app ;;
    5) _show_rf_profile_panel "4G LTE X310" \
         "LTE Band 7 — DL ~2660 MHz / UL ~2520 MHz" \
         "make preflight-4g-lte-x310 && make start-4g-lte-x310-epc" \
         "make stop-4g-lte-x310"
       pause ;;
    6) _show_rf_profile_panel "5G SA X310" \
         "NR Band n3  — DL ~1842 MHz / UL ~1757 MHz" \
         "make preflight-5g-x310 && make start-5g-x310-core && make start-5g-x310-rf" \
         "make stop-5g-x310"
       pause ;;
    7) _show_rf_profile_panel "5G NSA X310" \
         "NR Band n3 + LTE Band 7 — DL ~1842 MHz NR + 2660 MHz LTE" \
         "make start-5g-x310-core" \
         "make stop-5g-x310"
       pause ;;
    0) return 0 ;;
    *) echo "  Opción inválida." ;;
  esac
}

_start_scenario() {
  local label="$1"
  local compose_proj="$2"
  local cmd_display="$3"
  local _cmd_stop="$4"
  local make_target="$5"

  # Verificar si ya está corriendo
  local already_running=false
  for proj in "${RUNNING_PROJECTS[@]}"; do
    [ "$proj" = "$compose_proj" ] && already_running=true
  done

  if $already_running; then
    echo
    echo "  ⚠️  '$label' ya está corriendo."
    if ! confirm "  ¿Continuar de todas formas?"; then
      return 0
    fi
  fi

  echo
  show_cmd "Iniciando escenario $label" "cd ~/Lain5G && make $make_target"
  (cd "$LAIN5G_DIR" && make "$make_target")
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

# =============================================================================
# ── Opción 4: Detener OpenLain5G ──────────────────────────────────────────────
# =============================================================================
cmd_stop() {
  detect_state
  section "Detener OpenLain5G"

  if ! command -v docker &>/dev/null; then
    echo
    echo "  ❌ Docker no está disponible."
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
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-5g-sa"
        (cd "$LAIN5G_DIR" && make stop-5g-sa) || true
        ;;
      "lain5g-lab-4g-lte-sim")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-4g-lte-sim"
        (cd "$LAIN5G_DIR" && make stop-4g-lte-sim) || true
        ;;
      "lain5g-lab-5g-vonr-sim")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-5g-vonr-sim"
        (cd "$LAIN5G_DIR" && make stop-5g-vonr-sim) || true
        ;;
      "lain5g-lab-5g-sa-x310")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-5g-x310"
        (cd "$LAIN5G_DIR" && make stop-5g-x310) || true
        ;;
      "lain5g-lab-5g-nsa-x310")
        show_cmd "Deteniendo $label" "cd ~/Lain5G && make stop-5g-x310"
        (cd "$LAIN5G_DIR" && make stop-5g-x310) || true
        ;;
      *)
        echo "  ⚠️  No sé cómo detener: $proj"
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
    else
      echo "   Corriendo: ⬛ Nada"
    fi

    echo
    echo "   1) ℹ️  Acerca de OpenLain5G"
    echo "   2) 📊 Ver estado detallado"
    echo "   3) ▶️  Iniciar OpenLain5G"
    echo "   4) ⏹️  Detener OpenLain5G"
    echo "   5) 📦 Instalar"
    echo "   6) 🗑️  Desinstalar"
    echo "   7) 🔄 Reinstalar"
    echo "   8) ❌ Salir"
    echo
    read -rp "Elige una opción [1-8]: " opt

    case "$opt" in
      1) cmd_about     ;;
      2) cmd_status    ;;
      3) cmd_start     ;;
      4) cmd_stop      ;;
      5) cmd_install   ;;
      6) cmd_uninstall ;;
      7) cmd_reinstall ;;
      8) echo; echo "Hasta luego."; exit 0 ;;
      *) echo "  Opción inválida. Elige entre 1 y 8." ;;
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
    if command -v docker &>/dev/null; then
      known_projects=(
        "lain5g-lab-app"
        "lain5g-lab-5g-sa"
        "lain5g-lab-4g-lte-sim"
        "lain5g-lab-5g-vonr-sim"
        "lain5g-lab-5g-sa-x310"
        "lain5g-lab-5g-nsa-x310"
      )
      for proj in "${known_projects[@]}"; do
        count=$(docker ps --filter "label=com.docker.compose.project=$proj" \
                --format "{{.Names}}" 2>/dev/null | wc -l)
        label=$(_project_label "$proj")
        if [ "$count" -gt 0 ]; then
          printf "    🟢 %-30s (%d contenedores)\n" "$label" "$count"
        else
          printf "    ⬛ %-30s (detenido)\n" "$label"
        fi
      done
    else
      echo "    Docker no instalado"
    fi
    if command -v docker &>/dev/null; then
      echo
      echo "  Imágenes Docker:"
      images=$(docker images --format "    {{.Repository}}:{{.Tag}}   {{.Size}}" 2>/dev/null | grep "lain5g" || true)
      if [ -n "$images" ]; then
        echo "$images" | while IFS= read -r line; do echo "    ✅$line"; done
      else
        echo "    ❌ Ninguna imagen lain5g encontrada"
      fi
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
