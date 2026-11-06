-- ============================================================================
-- 01_preparar.sql  --  Paso 1 de la carga (lo ejecuta cargar.sh)
-- Crea el esquema "carga" con sus restricciones y lo deja vacio.
-- Todo el flujo (este archivo + COPY + 02_cargar.sql) corre en UNA transaccion:
-- si algo falla, nada queda a medias.
-- ============================================================================
BEGIN;

\echo '[PASO 1/6] Preparar el esquema "carga" y vaciarlo (asi la carga es repetible)'

CREATE SCHEMA IF NOT EXISTS carga;

-- Orden de creacion: primero las tablas de las que dependen las demas.

CREATE TABLE IF NOT EXISTS carga.dim_indice_des (
    id_indice_des SERIAL PRIMARY KEY,
    indice_des    VARCHAR(50) NOT NULL UNIQUE,
    CONSTRAINT ck_indice_valido
        CHECK (indice_des IN ('ALTO', 'MEDIO', 'BAJO', 'POPULAR'))
);

CREATE TABLE IF NOT EXISTS carga.dim_ubicacion (
    id_ubicacion SERIAL PRIMARY KEY,
    alcaldia     VARCHAR(255) NOT NULL,
    colonia      VARCHAR(255) NOT NULL,
    latitud      NUMERIC(9,6),
    longitud     NUMERIC(9,6),
    CONSTRAINT uq_alcaldia_colonia UNIQUE (alcaldia, colonia),
    CONSTRAINT ck_etiqueta_territorial CHECK (alcaldia <> 'NA' AND colonia <> 'NA'),
    CONSTRAINT ck_coord_cdmx CHECK (
        (latitud  IS NULL OR latitud  BETWEEN  19.04 AND  19.60) AND
        (longitud IS NULL OR longitud BETWEEN -99.36 AND -98.94))
);

CREATE TABLE IF NOT EXISTS carga.dim_tiempo (
    id_tiempo SERIAL PRIMARY KEY,
    fecha     DATE NOT NULL UNIQUE,
    anio      INT  NOT NULL,
    mes       INT  NOT NULL,
    dia       INT  NOT NULL,
    bimestre  INT  NOT NULL,
    CONSTRAINT ck_mes      CHECK (mes BETWEEN 1 AND 12),
    CONSTRAINT ck_bimestre CHECK (bimestre BETWEEN 1 AND 6)
);

CREATE TABLE IF NOT EXISTS carga.fact_consumo_agua (
    id_fact       SERIAL PRIMARY KEY,
    id_tiempo     INT NOT NULL REFERENCES carga.dim_tiempo (id_tiempo),
    id_ubicacion  INT NOT NULL REFERENCES carga.dim_ubicacion (id_ubicacion),
    id_indice_des INT NOT NULL REFERENCES carga.dim_indice_des (id_indice_des),
    consumo_total_mixto  NUMERIC,
    consumo_prom_dom     NUMERIC,
    consumo_total_dom    NUMERIC,
    consumo_prom_mixto   NUMERIC,
    consumo_total        NUMERIC,
    consumo_prom         NUMERIC,
    consumo_prom_no_dom  NUMERIC,
    consumo_total_no_dom NUMERIC,
    CONSTRAINT ck_consumo_no_negativo CHECK (
        consumo_total >= 0 AND consumo_total_dom >= 0 AND
        consumo_total_no_dom >= 0 AND consumo_total_mixto >= 0)
);

CREATE TABLE IF NOT EXISTS carga.fact_clima (
    id_fact_clima SERIAL PRIMARY KEY,
    id_tiempo     INT NOT NULL REFERENCES carga.dim_tiempo (id_tiempo),
    temp_maxima      NUMERIC,
    temp_minima      NUMERIC,
    temp_promedio    NUMERIC,
    humedad_promedio NUMERIC,
    lluvia_total     NUMERIC,
    CONSTRAINT ck_humedad          CHECK (humedad_promedio BETWEEN 0 AND 100),
    CONSTRAINT ck_lluvia_no_negativa CHECK (lluvia_total >= 0),
    CONSTRAINT ck_temp_orden       CHECK (temp_minima <= temp_maxima)
);

-- Tablas de paso (staging): reciben el CSV tal cual. "fila" numera los
-- renglones de datos; el renglon del CSV es fila + 1 (el 1 es el encabezado).
CREATE TABLE IF NOT EXISTS carga.stg_clima (
    fila             BIGSERIAL,
    fecha_hora       TIMESTAMP,
    temperatura      NUMERIC,
    humedad_relativa INT,
    lluvia           NUMERIC
);

CREATE TABLE IF NOT EXISTS carga.stg_consumo (
    fila                 BIGSERIAL,
    fecha_referencia     DATE,
    anio                 INT,
    bimestre             INT,
    consumo_total_mixto  NUMERIC,
    consumo_prom_dom     NUMERIC,
    consumo_total_dom    NUMERIC,
    consumo_prom_mixto   NUMERIC,
    consumo_total        NUMERIC,
    consumo_prom         NUMERIC,
    consumo_prom_no_dom  NUMERIC,
    consumo_total_no_dom NUMERIC,
    indice_des           VARCHAR(50),
    colonia              VARCHAR(255),
    alcaldia             VARCHAR(255),
    latitud              NUMERIC,
    longitud             NUMERIC
);

-- Bitacora de rechazos: que renglon, de que archivo, que restriccion y por que.
CREATE TABLE IF NOT EXISTS carga.rechazos (
    id          BIGSERIAL PRIMARY KEY,
    archivo     TEXT   NOT NULL,
    renglon_csv BIGINT NOT NULL,
    tabla       TEXT   NOT NULL,
    restriccion TEXT   NOT NULL,
    motivo      TEXT
);

-- Repetible: se vacia todo y se vuelve a cargar, asi dos ejecuciones dejan
-- exactamente el mismo resultado (sin duplicados).
TRUNCATE carga.rechazos, carga.fact_clima, carga.fact_consumo_agua,
         carga.dim_tiempo, carga.dim_ubicacion, carga.dim_indice_des,
         carga.stg_clima, carga.stg_consumo
         RESTART IDENTITY;

\echo '[PASO 2/6] Lectura masiva de los dos CSV con COPY'
SELECT clock_timestamp() AS t0 \gset
