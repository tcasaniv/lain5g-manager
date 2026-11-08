# lain5g-manager

Script interactivo para gestionar [OpenLain5G](https://github.com/guallycanazas/Lain5G)
en GNU/Linux: instalar, desinstalar, reinstalar, iniciar y detener escenarios 4G/5G.

Diseñado para ser accesible a cualquier usuario, desde principiantes hasta expertos.
Incluye una **guía educativa integrada** sobre redes 4G/5G, Docker, SDR y seguridad RF,
pensada para quienes se acercan por primera vez a las telecomunicaciones móviles.

## Instalación (un solo comando)

```bash
curl -fsSL https://raw.githubusercontent.com/tcasaniv/lain5g-manager/main/lain5g-manager.sh \
  -o ~/lain5g-manager.sh && chmod +x ~/lain5g-manager.sh && bash ~/lain5g-manager.sh
```

Esto descarga el script a `~/lain5g-manager.sh` y lo inicia inmediatamente.
Para ejecutarlo de nuevo en el futuro:

```bash
bash ~/lain5g-manager.sh
```

## Uso

```bash
bash ~/lain5g-manager.sh           # abre el menú interactivo
bash ~/lain5g-manager.sh --status  # muestra estado y sale (no interactivo)
bash ~/lain5g-manager.sh --help    # muestra ayuda
```

## Funciones

| Opción | Descripción |
|--------|-------------|
| ℹ️  Acerca de | Guía educativa: 5G, 4G, Docker, SDR, bandas de frecuencia, seguridad RF, getting started |
| 📊 Estado detallado | Versión instalada, ref git, imágenes Docker, contenedores activos por escenario |
| ▶️  Iniciar | Lanzar escenarios de simulación (5G SA, 4G LTE, VoNR) o la App web de OpenLain5G |
| ⏹️  Detener | Detectar y detener componentes en ejecución (selectivo o todo a la vez) |
| 📦 Instalar | Clonar el repositorio, elegir rama/versión y ejecutar el instalador |
| 🗑️  Desinstalar | Eliminar contenedores, imágenes, volúmenes, redes y directorio del proyecto |
| 🔄 Reinstalar | Desinstalar y volver a instalar eligiendo versión/rama |

Los **perfiles RF (USRP X310)** aparecen en el menú de inicio con información educativa
sobre bandas de frecuencia, compatibilidad de antenas y seguridad. No ejecutan comandos RF
directamente: el usuario recibe los comandos exactos para ejecutarlos cuando esté preparado.

## Requisitos

- GNU/Linux x86_64 (Ubuntu 22.04 / 24.04 recomendado)
- Bash 4.0+
- `curl` (para la instalación one-liner)
- Conexión a Internet (para descargar OpenLain5G)

## Compatibilidad

| lain5g-manager | OpenLain5G |
|----------------|-----------|
| 1.1.8          | 1.1.8     |
| 1.1.7          | 1.1.7     |

## Proyecto OpenLain5G

- Repositorio: https://github.com/guallycanazas/Lain5G

**Publicación académica:**
> Canazas-Rosas, W. R., Prieto-Tito, M. I., Hilario-Tacuri, A., & Tamo-Calla, A. (2025).
> *OpenLain5G: Ready-to-Use 4G/5G Core Software with Orchestration and Validation for Testbeds.*
> SSRN. https://doi.org/10.2139/ssrn.7404673

## Autor

**Terry Casani Valencia** — [@tcasaniv](https://github.com/tcasaniv/)

## Licencia

MIT — ver [LICENSE](LICENSE)
