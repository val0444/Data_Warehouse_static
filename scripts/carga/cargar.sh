#!/usr/bin/env bash
# ============================================================================
# cargar.sh  --  Carga el almacen de consumo de agua de la CDMX.
#
# Un solo comando (desde la raiz del repositorio):
#     bash scripts/carga/cargar.sh
#
# Variables de entorno (NO hay credenciales en este archivo):
#     PGUSER, PGPASSWORD, PGDATABASE   obligatorias
#     PGHOST, PGPORT                   opcionales (si psql esta en tu equipo)
#     PSQL                             opcional: comando para llamar a psql.
#                                      Por defecto "psql". Para usar el
#                                      contenedor de Docker, ver LEEME_carga.md
#     CONSUMO_CSV, CLIMA_CSV           opcionales: rutas de los dos CSV
# ============================================================================
set -euo pipefail

: "${PGUSER:?Falta la variable de entorno PGUSER}"
: "${PGPASSWORD:?Falta la variable de entorno PGPASSWORD}"
: "${PGDATABASE:?Falta la variable de entorno PGDATABASE}"

export PGCLIENTENCODING=UTF8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$DIR/../.." && pwd)"
PSQL="${PSQL:-psql}"
CONSUMO_CSV="${CONSUMO_CSV:-$RAIZ/warehouse/data/consumo_agua_historico_2019.csv}"
CLIMA_CSV="${CLIMA_CSV:-$RAIZ/warehouse/data/open-meteo-19.44N99.11W2233m.csv}"

for f in "$CONSUMO_CSV" "$CLIMA_CSV" "$DIR/01_preparar.sql" "$DIR/02_cargar.sql"; do
  [ -f "$f" ] || { echo "ERROR: no existe el archivo $f" >&2; exit 1; }
done

# Entrega el CSV con saltos de linea LF y con salto final, para que COPY lo lea
# igual en Windows que en Linux.
csv_limpio() { tr -d '\r' < "$1" | sed -e '$a\'; }

echo "== Carga del almacen de consumo de agua CDMX =="
echo "Base: $PGDATABASE   Usuario: $PGUSER   $(date '+%Y-%m-%d %H:%M:%S')"
inicio=$SECONDS

# Todo viaja por un solo flujo hacia UNA sesion de psql, dentro de una
# transaccion (BEGIN en 01_preparar.sql, COMMIT al final de 02_cargar.sql).
# Con ON_ERROR_STOP, el primer error detiene todo y la transaccion se revierte.
if ! {
  cat "$DIR/01_preparar.sql"

  echo "COPY carga.stg_clima (fecha_hora, temperatura, humedad_relativa, lluvia) FROM STDIN WITH (FORMAT csv, HEADER true, NULL 'NA');"
  csv_limpio "$CLIMA_CSV"
  printf '%s\n' '\.'

  echo "COPY carga.stg_consumo (fecha_referencia, anio, bimestre, consumo_total_mixto, consumo_prom_dom, consumo_total_dom, consumo_prom_mixto, consumo_total, consumo_prom, consumo_prom_no_dom, consumo_total_no_dom, indice_des, colonia, alcaldia, latitud, longitud) FROM STDIN WITH (FORMAT csv, HEADER true, NULL 'NA');"
  csv_limpio "$CONSUMO_CSV"
  printf '%s\n' '\.'

  cat "$DIR/02_cargar.sql"
} | $PSQL -q -v ON_ERROR_STOP=1 -f -; then
  echo "" >&2
  echo "FALLO LA CARGA. Se revirtio la transaccion: no quedo ningun renglon a medias." >&2
  echo "El paso que fallo es el ultimo '[PASO n/6]' impreso arriba; el motivo es el mensaje ERROR de PostgreSQL." >&2
  exit 1
fi

echo "Duracion total del script: $((SECONDS - inicio)) s"
