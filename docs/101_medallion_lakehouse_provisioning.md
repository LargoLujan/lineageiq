# Bypass a base de datos: Lakehouse Bronze/Silver/Gold (Kimball) en paralelo

Ver el plan completo aprobado en la conversación que originó este documento para el contexto de diseño (modelo dimensional, decisiones de histórico, riesgos). Este documento es la guía práctica de puesta en marcha: qué hacer tú a mano (Fase 0) y qué ya está construido y listo para cuando termines esa parte.

Esto es un **bypass**, no una sustitución: el pipeline CSV/JSON actual (`scripts/03`…`21`, la web en `site/semantic-lineage/`) sigue funcionando exactamente igual. Nada de lo de aquí lo toca ni depende de él. Este Lakehouse es un destino nuevo y paralelo, y solo se alimenta si tú activas explícitamente el interruptor `-PublishBronze`.

## Qué NO toca esto

Los workspaces del tenant que este proyecto escanea siguen siendo de solo lectura, sin cambios. Lo único que se escribe es un **workspace nuevo y propio de este proyecto**, que tú creas y controlas — nunca ninguno de los workspaces escaneados.

## Fase 0 — Lo que tienes que hacer tú (una sola vez)

Esto se hace a mano desde el portal de Fabric, no por script (primera acción de escritura de todo el proyecto — se documenta aquí para que quede constancia de lo que se hizo y por qué).

1. **Crear un workspace nuevo** en el tenant `<tenant-id>`, dedicado a este proyecto. El nombre es tu elección — solo asegúrate de que no coincide con ninguno de los workspaces ya escaneados (puedes comprobarlo contra `index/workspaces.csv`).
2. **Asignarlo a una capacidad Fabric.** Antes de confirmar, comprueba que esa capacidad soporta **DirectLake** (lo usaremos para conectar Power BI directamente contra las tablas Gold sin pasos de importación).
3. Dentro de ese workspace, **crear un Lakehouse** (uno solo).
4. **Confirmar que tu misma identidad de `az login`** tiene permiso de Contributor sobre ese workspace — es el único sitio de todo Fabric donde esta identidad podrá escribir.
5. **Pásame estos datos** cuando los tengas: nombre y GUID del workspace, nombre y GUID del Lakehouse, nombre de la capacidad, y la cadena de conexión del SQL analytics endpoint del Lakehouse (la ves en el portal, en la configuración del Lakehouse — hace falta para la Fase 5, la validación de solo lectura contra las tablas Gold).

## Cómo se conecta, una vez tengas esos datos

Copia `config/lakehouse_target.example.json` a `config/lakehouse_target.json` (o simplemente rellena el que ya existe — está creado como plantilla vacía, ignorado por git) con los valores reales:

```json
{
  "tenant_id": "<tenant-id>",
  "workspace_name": "<nombre del workspace nuevo>",
  "workspace_id": "<GUID del workspace>",
  "lakehouse_name": "<nombre del Lakehouse>",
  "lakehouse_id": "<GUID del Lakehouse>",
  "capacity_name": "<nombre de la capacidad>",
  "sql_endpoint_connection_string": "<host del SQL analytics endpoint del Lakehouse>"
}
```

Nada más necesita tocarse — los scripts ya están escritos y probados contra esta configuración vacía; solo faltan estos seis valores.

## Qué ya está construido (listo, aunque el workspace todavía no exista)

- **`scripts/64_upload_bronze_to_onelake.py`** (+ `scripts/64_upload_bronze_to_onelake.ps1` como envoltorio): sube las ~19 CSV fuente del proyecto (workspaces, items, dependencias, ejecuciones, objetos/columnas, gobierno, pipelines de despliegue — cobertura completa, no solo tablas) a `Files/bronze/<entidad>/snapshot_date=<fecha>/` en el Lakehouse. Se puede probar hoy mismo, sin credenciales ni Lakehouse real:

  ```powershell
  pwsh -File scripts/64_upload_bronze_to_onelake.ps1 -DryRun
  ```

  Esto lista las 19 entidades, su tamaño real y la ruta de destino que tendrían, sin llamar a Azure. Cuando el Lakehouse exista y el config esté relleno, quita `-DryRun` y sube de verdad.

- **`requirements-lakehouse.txt`**: dependencias Python nuevas (`azure-identity`, `azure-storage-file-datalake`, `pandas`) — instalar con `pip install -r requirements-lakehouse.txt` antes de la primera subida real (no hace falta para `-DryRun`).

- **Interruptor `-PublishBronze`** (apagado por defecto, no cambia nada del comportamiento actual) añadido tanto a `scripts/scan_single_workspace.ps1` como a `scripts/99_refresh_lineage_project.ps1`. Cuando lo actives, el propio escaneo sube automáticamente las CSV recién generadas al final, como un paso más — de solo lectura contra Fabric excepto por esta subida final, que además se degrada sola (no aborta el escaneo) si el Lakehouse todavía no está configurado.

  ```powershell
  pwsh -File scripts/scan_single_workspace.ps1 -WorkspaceName "Nombre" -PublishBronze
  pwsh -File scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -PublishBronze
  ```

## Lo que falta para completar el resto de fases (una vez exista el Lakehouse)

1. **Notebook Fabric `NB_Bronze_Silver_Gold_Build`** — código fuente completo ya escrito en `fabric_notebooks/NB_Bronze_Silver_Gold_Build.py` (Fabric no se puede crear/editar notebooks de forma remota desde aquí, así que se pega a mano: crea un notebook nuevo en el Lakehouse con ese mismo nombre y copia el contenido, cada bloque `# %%` es una celda). Hace la ingesta Bronze (lee lo que se subió a Files/), el conformado Silver (deduplicación de ejecuciones por `job_instance_id`, claves surrogate UUID deterministas), y construye las 8 dimensiones + 8 hechos del esquema Gold. Nota: `object_read_write_classification.csv` ya llega desde origen con el tipo de objeto y la clasificación de lectura/escritura resueltos por `scripts/23_build_object_read_write_classification.ps1` — el notebook no reimplementa esa lógica en Spark, solo la conforma, evitando tener dos versiones independientes de la misma regla de negocio.
2. **`scripts/65_validate_lakehouse_gold_parity.ps1`**: comprobación de solo lectura que compara recuentos de filas entre las CSV locales y las tablas Bronze/Gold del Lakehouse, usando el mismo patrón de autenticación SQL vía AAD ya probado en `scripts/34_extract_sql_endpoint_object_catalog.ps1`.
3. Primer informe Power BI en modo DirectLake contra las tablas Gold, como prueba de que el objetivo ("explotar en reports") se cumple.

## Lectura en vivo desde el Warehouse (servidor web, 2026-07-24)

Desde el panel admin, pestaña Lakehouse, con `item_type = Warehouse` y
`auth_mode = service_principal`, existen dos interruptores independientes:

- **Escritura** — "Copiar automáticamente después de cada escaneo" (ya
  existía): cada escaneo sube `index/workspaces.csv`, `index/items.csv`,
  `index/dependencies.csv` y el resto de CSV del proyecto a
  `dbo.bronze_<entidad>` en el Warehouse vía `scripts/67_upload_bronze_to_warehouse.ps1`
  (MERGE incremental, solo lo que cambió).
- **Lectura** — "Este servidor lee ... en vivo desde este almacén" (nuevo):
  hace que `backend/scripts/lineage_web/catalog.py` (búsqueda de items,
  linaje de un item, resolución de workspace/item para las URLs de Fabric)
  consulte `dbo.bronze_workspaces/items/dependencies` directamente en cada
  petición, en vez de leer los CSV locales de la máquina donde corre el
  servidor. Implementado en `backend/scripts/lineage_web/warehouse.py`:
  token de cuenta de servicio (`msal.ConfidentialClientApplication`,
  scope `https://database.windows.net/.default`) + `pyodbc` con
  `SQL_COPT_SS_ACCESS_TOKEN` (mismo patrón que ya usa
  `scripts/70_extract_control_framework_lineage.py`), con una caché de 30s
  por tabla para no saturar el endpoint SQL en búsquedas rápidas seguidas.

Apagado por defecto (`lakehouse.web_read_mode = "local_files"`); si la
consulta al Warehouse falla por cualquier motivo (no configurado, tabla
todavía no subida, endpoint caído), cae automáticamente al CSV local sin
romper la petición. Pensado para el caso "el servidor web corre en una
máquina/nube distinta de la que escanea": con ambos interruptores activos,
lo que ven los compañeros queda tan fresco como la última subida
automática, sin depender de que la máquina que escaneó siga encendida.

Fuera de alcance de este cambio (sigue leyendo del disco local siempre):
`object-impact.json` y `notebook-super-lineage.json`, los dos artefactos
JSON pre-construidos que `catalog.py` también sirve (búsqueda de impacto
por objeto, código de notebook) — su lógica de construcción cruza varios
CSV y el propio `lineage-explorer.json`, y llevarla a SQL en vivo sería un
cambio bastante más grande. Quedan como una extensión futura natural del
mismo patrón (publicar el JSON ya construido en OneLake y leerlo de ahí en
vez de reimplementar el cruce en SQL), no iniciada todavía.

## Escaneo disparado desde un Fabric Data Pipeline (servidor web, 2026-07-24)

Segunda pieza de "que el cómputo se genere en Fabric, no en Render ni en la
máquina local": el panel admin, pestaña **Escaneo en Fabric**, deja elegir
entre `local` (por defecto, sin cambios: `scan_manager.py` sigue lanzando
`pwsh`/`az-cli` en esta máquina) y `fabric_pipeline` — en cuyo caso
`_start_scan`/`_start_full_scan`/`_stop_scan` disparan, sondean y cancelan
un Data Pipeline de Fabric ya existente vía la Job Scheduler REST API en
vez de un subproceso local. Implementado en
`backend/scripts/lineage_web/fabric_pipeline.py`, mismo patrón de token de
cuenta de servicio que `warehouse.py` (`msal.ConfidentialClientApplication`,
scope `https://api.fabric.microsoft.com/.default`).

Endpoints usados (confirmados contra la documentación de Microsoft Learn,
"Job Scheduler (Core)", 2026-07-24):

- Disparar: `POST /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances?jobType=Pipeline`, con `{"executionData": {"parameters": {"WorkspaceNameFilter": "..."}}}` — el id de la nueva ejecución viene en la cabecera `Location` de la respuesta, no en el cuerpo.
- Sondear: `GET /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances/{jobInstanceId}`.
- Cancelar: `POST /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances/{jobInstanceId}/cancel`.

**Por qué esto resuelve lo de Render/cuotas:** en cuanto un escaneo ya no
necesita `pwsh`/`az-cli` en la máquina que aloja la web, esa máquina puede
volver a ser el **plan gratuito** de un servicio como Render — es
justo lo que antes forzaba a un plan de pago o a mantener la máquina local
encendida. El trabajo pesado (descubrimiento vía la API de Fabric,
extracción de metadatos SQL, etc.) pasa a correr dentro de Fabric, sobre la
capacidad F-SKU que ya está pagada.

**Notebooks de descubrimiento: seis ya escritos, pendientes de pegarlos en
Fabric.** Cubren workspaces/items, dependencias item↔item (`04`), linaje
item→objeto externo desde código/JSON de items (`18`) y de actividades de
pipeline (`19`), TMDL de modelos semánticos (`09`), y opcionalmente
confirmar el tipo exacto de un objeto contra un catálogo SQL externo real
(`20`) — lista completa, columnas, orden de ejecución y advertencias en
`docs/105_fabric_native_discovery_setup.md` (fuente única de verdad, no
duplicada aquí). Todos escriben las mismas tablas `dbo.bronze_*` que
`67_upload_bronze_to_warehouse.ps1` ya sube desde local. `catalog.py`'s
`_get_item_lineage` y `_get_object_impact` ya saben leer estas tablas en
vivo (el segundo con dos límites documentados: sin columnas, sin cadena de
informes aguas abajo). Igual que `NB_Bronze_Silver_Gold_Build.py`, el
código se puede escribir aquí pero pegarlo dentro de Fabric (más el Key
Vault, la cuenta de servicio, y el propio Data Pipeline) es un paso
manual. Un notebook ejecutado por un pipeline puede correr bajo una cuenta
de servicio (no solo bajo un usuario interactivo) — confirmado vía el
blog oficial "Run Notebooks in Pipelines with Service Principal or
Workspace Identity" — pero el helper nativo `notebookutils.credentials.
getToken` tiene alcance limitado bajo cuenta de servicio; los notebooks
hacen su propio login MSAL con la cuenta de servicio (mismo patrón que
`warehouse.py`/`67_upload_bronze_to_warehouse.ps1`), no dependen de ese
helper.

**Los JSON grandes del explorador (`lineage-explorer.json` y los otros 4
que el frontend carga) ya pueden servirse en vivo desde OneLake** en vez
del disco local del servidor — `docs/106_onelake_web_data_publish.md`.
Aclarado explícitamente: esto NO mueve la construcción de esos JSON a
Fabric (siguen construyéndose local, igual que siempre); solo cambia
dónde aterriza el archivo ya construido y desde dónde lo lee la web.
Necesita un Lakehouse dedicado (un Warehouse no tiene área de Files en
OneLake, confirmado contra la documentación oficial) — puede vivir en el
mismo workspace que el Warehouse de escritura, es un elemento de Fabric
aparte.

**Qué SÍ queda listo y probado hoy:** el mecanismo de disparo/sondeo/
cancelación completo, con su propia cobertura de tests
(`tests/python/test_fabric_pipeline_scan.py`) y su botón "Probar conexión"
en el panel (verifica IDs + acceso de la cuenta de servicio leyendo los
metadatos del pipeline, sin arrancar una ejecución real). Sin diff de
items para este camino (a diferencia de un escaneo local): el pipeline
escribe directo en el Warehouse, no en `index/items.csv` de esta máquina
— comparar snapshots del Warehouse antes/después es trabajo futuro, no
inventado aquí con una comparación local que siempre saldría vacía.

## Fase futura (no diseñada todavía, solo anotada)

Cuando decidas explícitamente "desconectamos de la parte actual", se hará un volcado histórico completo de todo lo acumulado hasta ese momento y se dejará de mantener el pipeline CSV/JSON. Esa fase se diseñará aparte cuando llegue el momento — no forma parte de este trabajo.
