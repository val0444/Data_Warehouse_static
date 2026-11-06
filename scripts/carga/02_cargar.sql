-- ============================================================================
-- 02_cargar.sql  --  Pasos 3 a 6 de la carga (lo ejecuta cargar.sh)
-- Corre despues de que cargar.sh hizo los COPY, dentro de la misma transaccion.
-- ============================================================================

\echo '[PASO 3/6] COPY terminado: renglones leidos y tiempo'
SELECT extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) AS seg_copy \gset
SELECT (SELECT COUNT(*) FROM carga.stg_clima)   AS renglones_clima,
       (SELECT COUNT(*) FROM carga.stg_consumo) AS renglones_consumo,
       round(:seg_copy::numeric, 3)             AS segundos_copy;

-- ----------------------------------------------------------------------------
-- Referencia de eficiencia: INSERT renglon por renglon (una instruccion por
-- renglon) sobre una muestra de 2000, y estimacion para todo el archivo.
-- ----------------------------------------------------------------------------
\echo '[PASO 4/6] Referencia: INSERT renglon por renglon vs COPY'
CREATE TEMP TABLE base_fila (
    fila BIGINT, alcaldia TEXT, colonia TEXT, consumo_total NUMERIC
) ON COMMIT DROP;

SELECT clock_timestamp() AS t1 \gset
SELECT format('INSERT INTO base_fila VALUES (%s, %L, %L, %L)',
              fila, alcaldia, colonia, consumo_total)
FROM carga.stg_consumo ORDER BY fila LIMIT 2000 \gexec
SELECT extract(epoch FROM clock_timestamp() - :'t1'::timestamptz) AS seg_fila \gset

SELECT round(:seg_fila::numeric, 3) AS seg_2000_inserts_sueltos,
       round((:seg_fila * (SELECT COUNT(*) FROM carga.stg_consumo) / 2000.0)::numeric, 1)
           AS seg_estimados_todo_el_archivo,
       round((:seg_fila * (SELECT COUNT(*) FROM carga.stg_consumo) / 2000.0 / :seg_copy)::numeric, 1)
           AS veces_mas_lento_que_copy;

-- ----------------------------------------------------------------------------
-- Validacion y carga. Primero las dimensiones, despues los hechos.
-- Cada restriccion que un renglon incumple se registra en carga.rechazos y el
-- renglon se deja fuera de la carga.
-- ----------------------------------------------------------------------------
\echo '[PASO 5/6] Validar restricciones, registrar rechazos y cargar (dimensiones antes que hechos)'

-- 5.1 dim_tiempo: un renglon por dia del archivo de clima
INSERT INTO carga.dim_tiempo (fecha, anio, mes, dia, bimestre)
SELECT d,
       EXTRACT(YEAR  FROM d)::int,
       EXTRACT(MONTH FROM d)::int,
       EXTRACT(DAY   FROM d)::int,
       CEIL(EXTRACT(MONTH FROM d) / 2.0)::int
FROM (SELECT DISTINCT fecha_hora::date AS d FROM carga.stg_clima) x
ORDER BY d;

-- 5.2 Rechazos del archivo de consumo, una fila por restriccion incumplida
INSERT INTO carga.rechazos (archivo, renglon_csv, tabla, restriccion, motivo)
SELECT 'consumo', fila + 1, 'fact_consumo_agua', 'ck_etiqueta_territorial',
       format('alcaldia=%L colonia=%L', alcaldia, colonia)
FROM carga.stg_consumo
WHERE alcaldia IS NULL OR colonia IS NULL OR alcaldia = 'NA' OR colonia = 'NA';

INSERT INTO carga.rechazos (archivo, renglon_csv, tabla, restriccion, motivo)
SELECT 'consumo', fila + 1, 'fact_consumo_agua', 'ck_indice_valido',
       format('indice_des=%L', indice_des)
FROM carga.stg_consumo
WHERE indice_des IS NULL OR indice_des NOT IN ('ALTO', 'MEDIO', 'BAJO', 'POPULAR');

INSERT INTO carga.rechazos (archivo, renglon_csv, tabla, restriccion, motivo)
SELECT 'consumo', fila + 1, 'fact_consumo_agua', 'ck_consumo_no_negativo',
       format('consumo_total=%s dom=%s no_dom=%s mixto=%s',
              consumo_total, consumo_total_dom, consumo_total_no_dom, consumo_total_mixto)
FROM carga.stg_consumo
WHERE consumo_total < 0 OR consumo_total_dom < 0
   OR consumo_total_no_dom < 0 OR consumo_total_mixto < 0;

INSERT INTO carga.rechazos (archivo, renglon_csv, tabla, restriccion, motivo)
SELECT 'consumo', s.fila + 1, 'fact_consumo_agua', 'fk_fact_tiempo',
       format('fecha_referencia=%L no existe en dim_tiempo', s.fecha_referencia)
FROM carga.stg_consumo s
WHERE s.fecha_referencia IS NULL
   OR NOT EXISTS (SELECT 1 FROM carga.dim_tiempo t WHERE t.fecha = s.fecha_referencia);

-- 5.3 Rechazos del archivo de clima
INSERT INTO carga.rechazos (archivo, renglon_csv, tabla, restriccion, motivo)
SELECT 'clima', fila + 1, 'fact_clima', 'ck_humedad',
       format('humedad_relativa=%s', humedad_relativa)
FROM carga.stg_clima
WHERE humedad_relativa < 0 OR humedad_relativa > 100;

INSERT INTO carga.rechazos (archivo, renglon_csv, tabla, restriccion, motivo)
SELECT 'clima', fila + 1, 'fact_clima', 'ck_lluvia_no_negativa',
       format('lluvia=%s', lluvia)
FROM carga.stg_clima
WHERE lluvia < 0;

-- 5.4 Renglones que si pasan todas las restricciones
CREATE TEMP TABLE ok_consumo ON COMMIT DROP AS
SELECT s.fila
FROM carga.stg_consumo s
LEFT JOIN (SELECT DISTINCT renglon_csv FROM carga.rechazos WHERE archivo = 'consumo') r
       ON r.renglon_csv = s.fila + 1
WHERE r.renglon_csv IS NULL;

CREATE TEMP TABLE ok_clima ON COMMIT DROP AS
SELECT c.fila
FROM carga.stg_clima c
LEFT JOIN (SELECT DISTINCT renglon_csv FROM carga.rechazos WHERE archivo = 'clima') r
       ON r.renglon_csv = c.fila + 1
WHERE r.renglon_csv IS NULL;

-- 5.5 Dimensiones restantes (solo con renglones validos)
INSERT INTO carga.dim_indice_des (indice_des)
SELECT DISTINCT s.indice_des
FROM carga.stg_consumo s
JOIN ok_consumo o ON o.fila = s.fila
ORDER BY s.indice_des;

-- Centroide de la colonia: promedio de las lecturas que caen dentro de la CDMX
INSERT INTO carga.dim_ubicacion (alcaldia, colonia, latitud, longitud)
SELECT s.alcaldia, s.colonia,
       ROUND((AVG(s.latitud)  FILTER (WHERE s.latitud  BETWEEN 19.04 AND 19.60
                                        AND s.longitud BETWEEN -99.36 AND -98.94))::numeric, 6),
       ROUND((AVG(s.longitud) FILTER (WHERE s.latitud  BETWEEN 19.04 AND 19.60
                                        AND s.longitud BETWEEN -99.36 AND -98.94))::numeric, 6)
FROM carga.stg_consumo s
JOIN ok_consumo o ON o.fila = s.fila
GROUP BY s.alcaldia, s.colonia
ORDER BY s.alcaldia, s.colonia;

-- 5.6 Hechos
INSERT INTO carga.fact_consumo_agua
       (id_tiempo, id_ubicacion, id_indice_des,
        consumo_total_mixto, consumo_prom_dom, consumo_total_dom, consumo_prom_mixto,
        consumo_total, consumo_prom, consumo_prom_no_dom, consumo_total_no_dom)
SELECT t.id_tiempo, u.id_ubicacion, i.id_indice_des,
       s.consumo_total_mixto, s.consumo_prom_dom, s.consumo_total_dom, s.consumo_prom_mixto,
       s.consumo_total, s.consumo_prom, s.consumo_prom_no_dom, s.consumo_total_no_dom
FROM carga.stg_consumo s
JOIN ok_consumo o              ON o.fila = s.fila
JOIN carga.dim_tiempo t        ON t.fecha = s.fecha_referencia
JOIN carga.dim_ubicacion u     ON u.alcaldia = s.alcaldia AND u.colonia = s.colonia
JOIN carga.dim_indice_des i    ON i.indice_des = s.indice_des
ORDER BY s.fila;

INSERT INTO carga.fact_clima
       (id_tiempo, temp_maxima, temp_minima, temp_promedio, humedad_promedio, lluvia_total)
SELECT t.id_tiempo,
       MAX(c.temperatura), MIN(c.temperatura), AVG(c.temperatura),
       AVG(c.humedad_relativa), SUM(c.lluvia)
FROM carga.stg_clima c
JOIN ok_clima o         ON o.fila = c.fila
JOIN carga.dim_tiempo t ON t.fecha = c.fecha_hora::date
GROUP BY t.id_tiempo
ORDER BY t.id_tiempo;

-- ----------------------------------------------------------------------------
-- Resumen: cuantos renglones se insertaron y cuantos se rechazaron por tabla
-- ----------------------------------------------------------------------------
\echo '[PASO 6/6] Resumen por tabla (insertados y rechazados)'
SELECT t.tabla, t.insertados, COALESCE(r.n, 0) AS rechazados
FROM (VALUES
        (1, 'dim_indice_des',     (SELECT COUNT(*) FROM carga.dim_indice_des)),
        (2, 'dim_tiempo',         (SELECT COUNT(*) FROM carga.dim_tiempo)),
        (3, 'dim_ubicacion',      (SELECT COUNT(*) FROM carga.dim_ubicacion)),
        (4, 'fact_consumo_agua',  (SELECT COUNT(*) FROM carga.fact_consumo_agua)),
        (5, 'fact_clima',         (SELECT COUNT(*) FROM carga.fact_clima))
     ) AS t(orden, tabla, insertados)
LEFT JOIN (SELECT tabla, COUNT(DISTINCT renglon_csv) AS n
           FROM carga.rechazos GROUP BY tabla) r USING (tabla)
ORDER BY t.orden;

\echo 'Rechazos por restriccion (detalle en la tabla carga.rechazos):'
SELECT tabla, restriccion, COUNT(*) AS renglones
FROM carga.rechazos
GROUP BY tabla, restriccion
ORDER BY tabla, restriccion;

COMMIT;
\echo 'CARGA COMPLETA: transaccion confirmada.'
