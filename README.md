# Territorial Information Retrieval from Heterogeneous Open Data through the Construction of a Data Warehouse for Water Management in Mexico City

Reproducible artefact of a paper accepted at the **5th International Conference
on Ontologies and Knowledge Graphs (ICOKG 2026)**, Benemérita Universidad Autónoma
de Puebla, 25 September 2026.

**Live demonstration → <https://gabrielhuav.github.io/Data_Warehouse_static/>**

The demonstration needs no server. It runs from static files, including a SPARQL
1.1 engine that queries an RDF knowledge graph entirely in the browser.

---

## What this repository contains

A water-consumption data warehouse for Mexico City built from open government
data, the declarative mapping that projects it onto an RDF knowledge graph, and
a static interface that queries both without a backend.

| | |
| --- | --- |
| `warehouse/` | The data warehouse: star schema, ETL, source data and container |
| `mapping.r2rml.ttl` | R2RML mapping from the relational schema to RDF |
| `schema.ttl` | Data Cube structures, property ranges, ordinal SKOS scale and proximity vocabulary |
| `index.html`, `mapa.html` | Dashboard and choropleth map |
| `grafo.html` | SPARQL 1.1 explorer, running client-side |
| `vecindad.html` | Territorial adjacency as interactive graph traversal |
| `assets/mapa-teselas.js`, `assets/mapa-base/` | Base-map provider chain shared by both maps, and its offline OpenStreetMap copy |
| `scripts/` | Reproduction, export and benchmark scripts |
| `paper/` | Manuscript sources |
| `evaluacion-ml/` | Anomaly-detection evaluation protocol |

## Reproducing the figures reported in the paper

Every quantity in the article can be recomputed from the two source files
distributed here. No database required:

```bash
python scripts/reproducir_cifras.py \
    --consumo warehouse/data/consumo_agua_historico_2019.csv \
    --clima   warehouse/data/open-meteo-19.44N99.11W2233m.csv
```

```
Source records read: 71,102
Unmatched territorial label            216    0.30%
Total discarded                        216    0.30%
Loaded into the fact table          70,886   99.70%

fact_consumo_agua   70,886      dim_ubicacion    1,553
dim_tiempo             181      dim_indice_des       4
```

To rebuild the warehouse itself:

```bash
cd warehouse && docker compose up -d --build
```

The container loads both CSV files, runs the ETL and exposes PostgreSQL on port
5433. The four cardinalities above are printed during start-up.

## The knowledge graph

`mapping.r2rml.ttl` declares seven triples maps over the real schema, reusing
**RDF Data Cube** for observations, **GeoSPARQL** for territory,
**SKOS** for the ordinal development index and **OWL-Time** for periods.
`schema.ttl` supplies the consumption and climate Data Cube structures, the
unit attribute for cubic metres, and an explicit ordinal rank for the four
development-index concepts. The index concepts use their textual notations
(POPULAR, BAJO, MEDIO and ALTO) in their IRIs, so ordinal meaning does not
depend on warehouse SERIAL identifiers.
The materialisation script reports the exact triple count for a configured
warehouse instance and loads schema.ttl into the RDF graph before querying it:

```bash
python scripts/materializar_grafo.py \
    --dsn "postgresql://postgres:postgres@localhost:5433/data_warehouse"
```

`grafo.html` and `vecindad.html` query `kg_demo.ttl`, a browser-sized subset of
**140,499 triples**: every location with its centroid geometry, proximity
limited to the six nearest neighbours within 1.5 km, and observations aggregated
to the neighbourhood-period grain. Its aggregated observations use the distinct
`agua:aggobs/` namespace and `agua:consumoCDMXDemo`, linked to the full dataset
with `prov:wasDerivedFrom`; they therefore cannot collide with raw observations.
The proximity predicate is `agua:nearbyWithin1500m`: it is centroid proximity
within 1.5 km, not a GeoSPARQL Simple Features topological relation.

All JavaScript libraries are vendored under `assets/vendor/` (N3.js 1.17.2,
Comunica Browser v3, Plotly-basic 3.0.1 and Leaflet 1.9.4, including Leaflet
marker images). No third-party library is loaded from a CDN.

The browser demo and schema can be checked without Docker:

    py -3.12 scripts/validar_datacube.py

evidencia_datacube.txt stores the complete run. The script loads both Turtle
files, runs Data Cube IC-1, IC-2, IC-3 and IC-11 plus component/unit checks,
prints sample violations if present, and exits non-zero on failure.
The reproducible validator is `scripts/validar_datacube.py`.

## Reproducing the anomaly evaluation

assets/atipicos.js aggregates filtered records by alcaldía--colonia, calculates
the population mean and standard deviation of those totals inside each
alcaldía, and ranks A_g = abs(total - media_alcaldía) /
(desviación_alcaldía + 1e-9). The evaluation implements that exact operation at
the same territorial grain: it derives 1,553 real territorial identities from
kg_demo.ttl, generates three 2019 bimesters for the 16 alcaldías, and injects
labelled anomalies by colonia.

    py -3.12 evaluacion-ml/eval_anomalias.py --seed-start 42 --seeds 20

Each run injects 3.03% anomalies (33 spikes and 14 drops among 1,553 units),
uses seeds 42--61 by default, and gives the deployed ranking, Isolation Forest,
and LOF exactly the same number of alerts. evidencia_anomalias.txt stores the
full run; evaluacion-ml/curvas_precision_recall.csv stores every point of every
precision--recall curve.
`evaluacion-ml/evidencia_anomalias.txt` records the aggregate run and
`evaluacion-ml/curvas_precision_recall.csv` records all precision--recall points.

## Base map

Both maps, `mapa.html` and `vecindad.html`, take their base map from
`assets/mapa-teselas.js`, one module shared by the two pages. Until October
2026 they asked OpenStreetMap for tiles and nobody else. A sister artefact with
the same design lost its map during a talk when its only provider, CARTO, began
answering keyless requests with an "API KEY REQUIRED" image served as `200 OK`:
Leaflet does not treat that as an error, so nothing switched provider. The
module replaces the single dependency with a chain of free providers that need
no key:

1. OpenStreetMap, the provider used in the paper;
2. Esri Canvas (light or dark grey), Esri World Street Map, OpenStreetMap HOT,
   OpenTopoMap and Esri World Imagery;
3. CARTO, last, and only if it passes the watermark check;
4. a **local copy** served from this same site, so if the page loaded, the
   copy loads too: an OpenStreetMap extract of Mexico City
   (`assets/mapa-base/cdmx.json`, about 1 MB: motorways to tertiary roads,
   rivers and canals, bodies of water, large parks, the airport, the limits
   between alcaldías and place names), drawn in the browser;
5. and if even that file cannot be fetched, the outline of the city and its
   alcaldías, embedded in the module itself.

Each provider is checked before it is used: two adjacent tiles from the centre
of the city must arrive, be images and differ, because a watermark is the same
image at every coordinate. The provider in use is watched; if its tiles fail
or stall, the map moves to the next one on its own and says so, and when the
network comes back it returns to a remote provider. If the map has had nothing
to show for 1.5 s, the local copy is drawn underneath in the meantime, so it
never waits blank. In dark mode, providers without a dark version are inverted
with CSS.

A control at the bottom right of each map, *Map not loading? Try another
provider*, lists every provider with its live status; the choice made there is
remembered, like the theme and the language. `?teselas=<id>` pins one provider
for a single visit: `osm`, `esri-gris`, `esri-calles`, `osm-hot`, `topo`,
`esri-satelite`, `carto` or `local`. For example,
`mapa.html?teselas=local` uses no external server at all. Published links
without the parameter behave as before, starting from OpenStreetMap.

The local copy is rebuilt with

```bash
python scripts/generar_mapa_base.py
```

which downloads the extract from Overpass, derives the city outline and the
alcaldía limits from `alcaldias.geojson`, and rewrites the embedded fallback in
`assets/mapa-teselas.js`.

## Scope of the data

The source publishes the **first three bimesters of 2019** and no more; this
bounds every result reported in the article. The limitation belongs to the portal
rather than to the design, and is itself an instance of the fragmentation the
article studies. The climate series covers the 181 days from 1 January to 30 June
2019 at daily grain, which is why the time dimension is larger than the number of
reading dates.

## Provenance

This repository is a **fork**; the fork relationship is preserved on GitHub so
that authorship of the original static demonstration stays visible.

| Component | Author | Status |
| --- | --- | --- |
| Original static demonstration | see fork parent | as published |
| `warehouse/` | **Omar Fernando Pulido Morales** | the implementation that produced the reported results, imported unmodified from [`omarpulidom/data_warehouse_cdmx`](https://github.com/omarpulidom/data_warehouse_cdmx) (MIT) |
| `warehouse/etl/2_geo.sql` | added for the camera-ready | restores the coordinates the original schema discarded |
| `mapping.r2rml.ttl`, `grafo.html`, `vecindad.html`, `scripts/` | added for the camera-ready | — |
| `evaluacion-ml/eval_anomalias.py` | added for the camera-ready | **reconstruction**: the original script was not preserved |

## Data sources and licences

- **Consumption**: [SACMEX](https://datos.cdmx.gob.mx/dataset/consumo-agua),
  Mexico City Open Data Portal. Accessed May 2026.
- **Climate**: [Open-Meteo](https://open-meteo.com/), CC BY 4.0.
- **Base map**: © [OpenStreetMap](https://www.openstreetmap.org/copyright)
  contributors, ODbL, served by the provider credited on the map (see
  [Base map](#base-map)); the local copy is an OpenStreetMap extract under the
  same licence.

Code in this repository is released under the MIT licence; see `LICENSE`. The redistributed data
files keep the licences of their publishers.

## Status

This repository is the reproducible artefact of a paper accepted at ICOKG 2026
and currently undergoing final review. Full publication details will be added
once the proceedings are published.

The version cited by the manuscript is frozen as release
[`v1.5-icokg2026`](https://github.com/gabrielhuav/Data_Warehouse_static/releases/tag/v1.5-icokg2026).
The repository head may evolve; the release will not.
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
