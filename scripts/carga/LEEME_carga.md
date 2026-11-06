## Carga del almacen (ejercicio 1.4)

Carga los dos CSV del proyecto (consumo de agua y clima) en el esquema `carga`
de la base `data_warehouse`. No toca las tablas de `public`.

### Requisitos
- Docker con el contenedor `data_warehouse_cdmx` en ejecucion (ver `warehouse/`).
- Git Bash (o cualquier shell con `bash`, `tr` y `sed`).
- Los archivos de `scripts/carga/` con saltos de linea LF, no CRLF.

### Un solo comando

Desde la raiz del repositorio (`Data_Warehouse_static`):

```bash
export PGUSER=postgres
export PGPASSWORD=postgres        # el valor de POSTGRES_PASSWORD en warehouse/compose.yml
export PGDATABASE=data_warehouse
export PSQL="docker exec -i -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGCLIENTENCODING data_warehouse_cdmx psql"

bash scripts/carga/cargar.sh
```

Si tienes `psql` instalado en tu equipo, en lugar de `PSQL` define:

```bash
export PGHOST=127.0.0.1
export PGPORT=5433
```

La contrasena se define en la terminal, nunca dentro de los archivos del repo.

### Que hace, en orden

1. Crea el esquema `carga` y sus tablas con restricciones, y las vacia (por eso se puede repetir).
2. Lee los dos CSV con `COPY` (carga masiva).
3. Informa renglones leidos y segundos de COPY.
4. Mide una referencia con INSERT renglon por renglon y la compara con COPY.
5. Valida cada restriccion, registra los rechazos en `carga.rechazos` y carga: dimensiones primero, hechos despues.
6. Imprime insertados y rechazados por tabla, y rechazos por restriccion.

Todo corre en una transaccion: si algo falla, se revierte y el mensaje indica el paso y el error.

### Ver los renglones rechazados

```sql
SELECT * FROM carga.rechazos ORDER BY archivo, renglon_csv LIMIT 20;
```

`renglon_csv` es el numero de renglon en el archivo original (el 1 es el encabezado).
