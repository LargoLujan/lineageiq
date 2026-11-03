# NB_Bronze_Silver_Gold_Build
#
# Fuente para un notebook PySpark de Fabric. Fabric no se puede crear/editar
# de forma remota desde este repositorio, así que este archivo se pega a
# mano en un notebook nuevo dentro del Lakehouse creado en la Fase 0 (ver
# docs/101_medallion_lakehouse_provisioning.md). Cada bloque delimitado por
# "# %%" es una celda independiente -- pégalas en el mismo orden.
#
# Qué hace, en tres pasadas sobre el mismo Lakehouse:
#   1. Bronze: lee Files/bronze/<entidad>/snapshot_date=<fecha>/<entidad>.csv
#      (subido por scripts/64_upload_bronze_to_onelake.py) y lo escribe como
#      tabla Delta gestionada bronze_<entidad>, particionada por snapshot_date.
#   2. Silver: deduplica, tipa, y asigna una clave surrogate UUID determinista
#      a cada dimensión.
#   3. Gold: construye el esquema en estrella Kimball (dim_*/fact_*) que
#      Power BI consumirá en DirectLake.
#
# Nota importante sobre "portar la lógica de clasificación": el CSV
# analysis/object_read_write_classification.csv que llega a Bronze YA es la
# salida final de scripts/23_build_object_read_write_classification.ps1 --
# ya trae usage_type_normalized, object_type_status, object_type_source y
# object_type_confidence resueltos. Por eso este notebook NO reimplementa
# esa clasificación en Spark (evita tener dos implementaciones
# independientes de la misma regla de negocio, que es justo el riesgo de
# deriva que el plan original quería evitar) -- Silver aquí solo conforma
# claves y tipos sobre columnas que ya vienen correctas desde el origen.

# %% [markdown]
# ## Configuración

# %%
from datetime import date
import uuid

RUN_DATE = date.today().isoformat()  # cambia esto si estás reprocesando un snapshot_date concreto
UUID_NAMESPACE = uuid.UUID("6f1a1f2e-9c3d-4e7a-8b2a-1d4c9e6f0a11")  # namespace fijo del proyecto -- no cambiar nunca

# entidad -> ruta relativa dentro de Files/bronze/ (debe coincidir exactamente
# con ENTITY_SOURCE_PATHS en scripts/64_upload_bronze_to_onelake.py)
BRONZE_ENTITIES = [
    "workspaces", "items", "item_analysis", "dependencies", "executions",
    "object_column_catalog", "object_impact_index", "object_read_write_classification",
    "notebook_super_lineage_objects", "notebook_super_lineage_flows",
    "semantic_model_datamart_dependencies", "semantic_model_report_dependencies",
    "workspace_governance_principals", "deployment_pipelines",
    "deployment_pipeline_stages", "deployment_pipeline_stage_items",
    "source_object_type_overrides", "manual_lineage_object_evidence",
    "source_object_type_metadata_evidence", "sql_endpoint_object_catalog",
]

# Columnas que SIEMPRE deben quedarse como string, nunca dejarse inferir como
# numéricas -- son GUID o identificadores, no cantidades.
ID_LIKE_COLUMN_SUFFIXES = ("_id", "_key")
ID_LIKE_COLUMN_NAMES = {
    "technical_id", "qualified_name", "object_key", "schedule_id", "job_instance_id",
    "root_activity_id", "domain_id", "capacity_id",
}

# %% [markdown]
# ## Funciones auxiliares

# %%
from pyspark.sql import functions as F
from pyspark.sql.types import StringType
from pyspark.sql.window import Window


def deterministic_uuid(business_key: str) -> str:
    """UUID5 estable: la misma clave de negocio siempre produce el mismo
    UUID, en cualquier carga -- no hace falta una tabla de keymap con
    contador para mantener claves surrogate consistentes entre snapshots."""
    if business_key is None:
        return None
    return str(uuid.uuid5(UUID_NAMESPACE, str(business_key).strip().lower()))


deterministic_uuid_udf = F.udf(deterministic_uuid, StringType())


def cast_id_like_columns_to_string(df):
    """Después de leer con inferSchema, fuerza a string cualquier columna
    que por nombre sea claramente un identificador (GUID, clave, etc.) --
    evita que Spark infiera un ID como numérico solo porque parece serlo."""
    for column_name in df.columns:
        lower_name = column_name.lower()
        if lower_name in ID_LIKE_COLUMN_NAMES or lower_name.endswith(ID_LIKE_COLUMN_SUFFIXES):
            df = df.withColumn(column_name, F.col(column_name).cast(StringType()))
    return df


def normalize_key(column):
    """Replica Normalize-Key de PowerShell: minúsculas, trim, colapsar
    espacios -- se usa igual en cualquier columna que sirva de clave de
    negocio, en cualquier tabla."""
    return F.regexp_replace(F.trim(F.lower(column)), r"\s+", " ")


# %% [markdown]
# ## Fase Bronze: aterrizaje

# %%
for entity in BRONZE_ENTITIES:
    source_path = f"Files/bronze/{entity}/snapshot_date={RUN_DATE}/{entity}.csv"
    try:
        raw_df = spark.read.csv(source_path, header=True, inferSchema=True)
    except Exception as exc:  # noqa: BLE001 - una entidad que falte no debe frenar las demás
        print(f"[bronze][skip] {entity}: no se pudo leer {source_path} ({exc})")
        continue

    typed_df = cast_id_like_columns_to_string(raw_df)
    bronze_df = (
        typed_df
        .withColumn("snapshot_date", F.lit(RUN_DATE))
        .withColumn("_ingested_at", F.current_timestamp())
        .withColumn("_source_file", F.lit(source_path))
    )

    table_name = f"bronze_{entity}"
    # Idempotente: si ya existe una carga para este snapshot_date, se
    # reemplaza solo esa partición en vez de duplicar filas.
    if spark.catalog.tableExists(table_name):
        bronze_df.write.format("delta").mode("overwrite") \
            .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'") \
            .partitionBy("snapshot_date").saveAsTable(table_name)
    else:
        bronze_df.write.format("delta").mode("overwrite") \
            .partitionBy("snapshot_date").saveAsTable(table_name)

    print(f"[bronze][ok] {table_name}: {bronze_df.count()} filas para snapshot_date={RUN_DATE}")

# %% [markdown]
# ## Fase Silver: conformado
#
# Cada bloque de aquí en adelante depende de que la celda Bronze anterior
# ya haya corrido (lee las tablas bronze_* recién escritas).

# %%
# --- Dimensión: workspace ---
silver_workspace = (
    spark.table("bronze_workspaces")
    .withColumn("workspace_bk", F.col("technical_id"))
    .withColumn("workspace_sk", deterministic_uuid_udf(F.col("technical_id")))
)

# --- Dimensión: capacidad (propia, no solo un atributo del workspace) ---
silver_capacity = (
    silver_workspace
    .select("capacity_id", "capacity_name", "capacity_region")
    .filter(F.col("capacity_id").isNotNull())
    .dropDuplicates(["capacity_id"])
    .withColumn("capacity_sk", deterministic_uuid_udf(F.col("capacity_id")))
)

# --- Dimensión: item (notebooks, copyjobs, pipelines, modelos semánticos,
#     informes -- todos conviven aquí, item_type como atributo, es la
#     práctica Kimball correcta) ---
silver_item = (
    spark.table("bronze_items")
    .withColumn("item_bk", F.coalesce(F.col("technical_id"), F.col("qualified_name")))
    .withColumn("item_sk", deterministic_uuid_udf(F.col("item_bk")))
)

# --- Dimensión: objeto fuente (tabla/vista/SP/columna) ---
# object_read_write_classification.csv ya trae object_type/object_type_source/
# object_type_confidence resueltos -- no se re-deriva nada aquí, solo se
# conforma una fila por object_key.
silver_source_object = (
    spark.table("bronze_object_read_write_classification")
    .select(
        "object_key", "source_type", "source_server", "source_database", "schema_name",
        "object_name", "object_display_name", "object_type", "object_type_source",
        "object_type_confidence",
    )
    .filter(F.col("object_key").isNotNull())
    .dropDuplicates(["object_key"])
    .withColumn("object_sk", deterministic_uuid_udf(F.col("object_key")))
)

# --- Dimensión: principal/propietario ---
silver_principal = (
    spark.table("bronze_workspace_governance_principals")
    .withColumn("principal_bk", F.coalesce(F.col("principal_email"), F.col("principal_name")))
    .withColumn("principal_sk", deterministic_uuid_udf(F.col("principal_bk")))
)

# --- Dimensión: pipeline de despliegue + etapa ---
silver_deployment_pipeline = (
    spark.table("bronze_deployment_pipelines")
    .withColumn("deployment_pipeline_sk", deterministic_uuid_udf(F.col("deployment_pipeline_id")))
)
silver_pipeline_stage = (
    spark.table("bronze_deployment_pipeline_stages")
    .withColumn(
        "pipeline_stage_bk",
        F.concat_ws("~", F.col("deployment_pipeline_id"), F.col("stage_id")),
    )
    .withColumn("pipeline_stage_sk", deterministic_uuid_udf(F.col("pipeline_stage_bk")))
    .withColumn("workspace_sk", deterministic_uuid_udf(F.col("workspace_id")))
)

print("Silver: dimensiones conformadas.")

# %%
# --- Deduplicación de ejecuciones (grano mixto: schedule vs job_instance) ---
executions_bronze = spark.table("bronze_executions")

silver_schedule = executions_bronze.filter(F.col("record_type") == "schedule")

silver_job_run = (
    executions_bronze
    .filter(F.col("record_type") == "job_instance")
    .withColumn(
        "_row_rank",
        F.row_number().over(
            Window.partitionBy("job_instance_id").orderBy(F.col("snapshot_date").desc())
        ),
    )
    .filter(F.col("_row_rank") == 1)
    .drop("_row_rank")
)

print(f"Silver: {silver_schedule.count()} schedules, {silver_job_run.count()} job runs (deduplicados por job_instance_id).")

# %% [markdown]
# ## Fase Gold: dimensiones (SCD2 en workspace/item/source_object, Tipo 1 en el resto)

# %%
def upsert_scd2(silver_df, gold_table_name, business_key_col, surrogate_key_col, tracked_columns):
    """SCD Tipo 2 sencillo: si la fila más reciente en Silver difiere de la
    versión vigente en Gold en alguna columna vigilada, cierra la versión
    anterior (effective_to/is_current=false) y abre una nueva."""
    from delta.tables import DeltaTable

    incoming = silver_df.withColumn("effective_from", F.current_timestamp()) \
        .withColumn("effective_to", F.lit(None).cast("timestamp")) \
        .withColumn("is_current", F.lit(True))

    if not spark.catalog.tableExists(gold_table_name):
        incoming.write.format("delta").mode("overwrite").saveAsTable(gold_table_name)
        print(f"[gold][created] {gold_table_name}: {incoming.count()} filas")
        return

    gold_table = DeltaTable.forName(spark, gold_table_name)
    current_gold = gold_table.toDF().filter(F.col("is_current"))

    change_condition = " OR ".join([f"src.{c} <> tgt.{c}" for c in tracked_columns])
    changed = (
        incoming.alias("src")
        .join(current_gold.alias("tgt"), business_key_col, "inner")
        .where(change_condition)
        .select(f"src.{business_key_col}")
    )
    new_keys = incoming.join(current_gold, business_key_col, "left_anti").select(business_key_col)
    keys_to_expire = changed.union(new_keys.join(changed, business_key_col, "left_anti").select(business_key_col))

    gold_table.alias("tgt").merge(
        keys_to_expire.alias("src"), f"tgt.{business_key_col} = src.{business_key_col} AND tgt.is_current = true"
    ).whenMatchedUpdate(set={"is_current": F.lit(False), "effective_to": F.current_timestamp()}).execute()

    to_insert = incoming.join(keys_to_expire, business_key_col, "inner")
    to_insert.write.format("delta").mode("append").saveAsTable(gold_table_name)
    print(f"[gold][scd2] {gold_table_name}: {to_insert.count()} versiones nuevas/actualizadas")


upsert_scd2(
    silver_workspace, "gold_dim_workspace", "workspace_bk", "workspace_sk",
    tracked_columns=["workspace_name", "capacity_id", "domain_id", "owner", "status"],
)
upsert_scd2(
    silver_item, "gold_dim_item", "item_bk", "item_sk",
    tracked_columns=["item_name", "folder_id", "description", "sensitivity_label", "status"],
)
upsert_scd2(
    silver_source_object, "gold_dim_source_object", "object_key", "object_sk",
    tracked_columns=["object_type", "object_type_source", "object_type_confidence"],
)

# %%
# --- Dimensiones Tipo 1 (sobrescribir, sin histórico de versión) ---
silver_capacity.write.format("delta").mode("overwrite").saveAsTable("gold_dim_capacity")
silver_principal.write.format("delta").mode("overwrite").saveAsTable("gold_dim_principal")
silver_deployment_pipeline.write.format("delta").mode("overwrite").saveAsTable("gold_dim_deployment_pipeline")
silver_pipeline_stage.write.format("delta").mode("overwrite").saveAsTable("gold_dim_pipeline_stage")

# --- Dimensión calendario (generada, no viene de ninguna CSV) ---
gold_dim_date = (
    spark.sql("SELECT explode(sequence(to_date('2024-01-01'), to_date('2030-12-31'), interval 1 day)) AS date")
    .withColumn("date_sk", F.date_format("date", "yyyyMMdd").cast("int"))
    .withColumn("year", F.year("date"))
    .withColumn("quarter", F.quarter("date"))
    .withColumn("month", F.month("date"))
    .withColumn("month_name", F.date_format("date", "MMMM"))
    .withColumn("week", F.weekofyear("date"))
    .withColumn("day_of_week", F.dayofweek("date"))
    .withColumn("day_name", F.date_format("date", "EEEE"))
    .withColumn("is_weekend", F.col("day_of_week").isin(1, 7))
)
gold_dim_date.write.format("delta").mode("overwrite").saveAsTable("gold_dim_date")

print("Gold: dimensiones Tipo 1 + calendario listas.")

# %% [markdown]
# ## Fase Gold: hechos (todos con snapshot_date, salvo el evento inmutable job_run)

# %%
workspace_lookup = spark.table("gold_dim_workspace").filter(F.col("is_current")).select("workspace_bk", "workspace_sk")
item_lookup = spark.table("gold_dim_item").filter(F.col("is_current")).select(
    F.col("item_bk"), F.col("item_sk"), F.col("qualified_name").alias("item_qualified_name_lookup")
)
object_lookup = spark.table("gold_dim_source_object").filter(F.col("is_current")).select("object_key", "object_sk")
date_lookup = spark.table("gold_dim_date").select("date", "date_sk")

# %%
# --- gold_fact_schedule: snapshot periódico, un schedule_id por fecha ---
gold_fact_schedule = (
    silver_schedule
    .join(item_lookup, silver_schedule.qualified_name == item_lookup.item_qualified_name_lookup, "left")
    .join(workspace_lookup, silver_schedule.workspace_name == workspace_lookup.workspace_bk, "left")
    .join(date_lookup, silver_schedule.snapshot_date == date_lookup.date, "left")
    .select(
        "workspace_sk", "item_sk", "date_sk", "schedule_id", "schedule_enabled",
        "scheduled_time", "schedule_timezone", "schedule_frequency", "job_type", "trigger_type",
        "snapshot_date",
    )
)
gold_fact_schedule.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_schedule")

# %%
# --- gold_fact_job_run: transacción, evento inmutable ya deduplicado ---
gold_fact_job_run = (
    silver_job_run
    .join(item_lookup, silver_job_run.qualified_name == item_lookup.item_qualified_name_lookup, "left")
    .join(workspace_lookup, silver_job_run.workspace_name == workspace_lookup.workspace_bk, "left")
    .withColumn("start_date", F.to_date("start_time"))
    .join(date_lookup, F.col("start_date") == date_lookup.date, "left")
    .select(
        "workspace_sk", "item_sk", "date_sk", "job_instance_id", "root_activity_id",
        "start_time", "end_time", "duration_seconds", "status", "failure_reason",
        "job_type", "trigger_type",
    )
)
if spark.catalog.tableExists("gold_fact_job_run"):
    # Solo se añaden job_instance_id que todavía no existan -- un job_run ya
    # registrado es un evento pasado, no debe cambiar entre snapshots.
    existing_ids = spark.table("gold_fact_job_run").select("job_instance_id")
    gold_fact_job_run = gold_fact_job_run.join(existing_ids, "job_instance_id", "left_anti")
    gold_fact_job_run.write.format("delta").mode("append").saveAsTable("gold_fact_job_run")
else:
    gold_fact_job_run.write.format("delta").mode("overwrite").saveAsTable("gold_fact_job_run")

# %%
# --- gold_fact_dependency_edge: snapshot periódico ---
dependencies_bronze = spark.table("bronze_dependencies").filter(F.col("snapshot_date") == RUN_DATE)
gold_fact_dependency_edge = (
    dependencies_bronze
    .join(item_lookup.alias("from_item"), dependencies_bronze.from_qualified_name == F.col("from_item.item_qualified_name_lookup"), "left")
    .withColumnRenamed("item_sk", "from_item_sk")
    .join(item_lookup.alias("to_item"), dependencies_bronze.to_qualified_name == F.col("to_item.item_qualified_name_lookup"), "left")
    .withColumnRenamed("item_sk", "to_item_sk")
    .join(date_lookup, F.lit(RUN_DATE) == date_lookup.date, "left")
    .select("from_item_sk", "to_item_sk", "relationship_type", "confidence", "evidence", "date_sk", dependencies_bronze.snapshot_date)
)
gold_fact_dependency_edge.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_dependency_edge")

# %%
# --- gold_fact_object_usage: snapshot periódico -- ya viene clasificado
#     desde origen (ver nota al principio del notebook), solo se conforma ---
usage_bronze = spark.table("bronze_object_read_write_classification").filter(F.col("snapshot_date") == RUN_DATE)
gold_fact_object_usage = (
    usage_bronze
    .join(item_lookup, usage_bronze.item_qualified_name == item_lookup.item_qualified_name_lookup, "left")
    .join(object_lookup, "object_key", "left")
    .join(date_lookup, F.lit(RUN_DATE) == date_lookup.date, "left")
    .select(
        "item_sk", "object_sk",
        F.col("usage_type_normalized").alias("usage_type"),
        "operation_type", F.col("lineage_confidence").alias("confidence"), "evidence",
        "date_sk", usage_bronze.snapshot_date,
    )
)
gold_fact_object_usage.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_object_usage")

print("Gold: hechos principales (schedule/job_run/dependency_edge/object_usage) listos para snapshot_date=" + RUN_DATE)

# %%
# --- gold_fact_semantic_model_source: snapshot periódico ---
sm_source_bronze = spark.table("bronze_semantic_model_datamart_dependencies").filter(F.col("snapshot_date") == RUN_DATE)
model_item_lookup = item_lookup.withColumnRenamed("item_sk", "semantic_model_item_sk")
gold_fact_semantic_model_source = (
    sm_source_bronze
    .join(model_item_lookup, sm_source_bronze.semantic_model_qualified_name == model_item_lookup.item_qualified_name_lookup, "left")
    .join(date_lookup, F.lit(RUN_DATE) == date_lookup.date, "left")
    .select(
        "semantic_model_item_sk", "source_qualified_name", "confidence", "evidence", "connection_label",
        "refresh_runs", "refresh_failed", "refresh_latest_status", "enabled_schedules", "disabled_schedules",
        "date_sk", sm_source_bronze.snapshot_date,
    )
)
gold_fact_semantic_model_source.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_semantic_model_source")

# %%
# --- gold_fact_semantic_model_report: snapshot periódico ---
sm_report_bronze = spark.table("bronze_semantic_model_report_dependencies").filter(F.col("snapshot_date") == RUN_DATE)
report_item_lookup = item_lookup.withColumnRenamed("item_sk", "report_item_sk")
gold_fact_semantic_model_report = (
    sm_report_bronze
    .join(model_item_lookup, sm_report_bronze.semantic_model_qualified_name == model_item_lookup.item_qualified_name_lookup, "left")
    .join(
        report_item_lookup,
        sm_report_bronze.report_qualified_name == report_item_lookup.item_qualified_name_lookup,
        "left",
    )
    .join(date_lookup, F.lit(RUN_DATE) == date_lookup.date, "left")
    .select("semantic_model_item_sk", "report_item_sk", "confidence", "evidence", "date_sk", sm_report_bronze.snapshot_date)
)
gold_fact_semantic_model_report.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_semantic_model_report")

# %%
# --- gold_fact_workspace_principal_role: snapshot periódico ---
principal_lookup = spark.table("gold_dim_principal").select(
    F.col("principal_bk"), F.col("principal_sk")
)
governance_bronze = spark.table("bronze_workspace_governance_principals").filter(F.col("snapshot_date") == RUN_DATE)
gold_fact_workspace_principal_role = (
    governance_bronze
    .withColumn("principal_bk", F.coalesce(F.col("principal_email"), F.col("principal_name")))
    .join(workspace_lookup, governance_bronze.workspace_name == workspace_lookup.workspace_bk, "left")
    .join(principal_lookup, "principal_bk", "left")
    .join(date_lookup, F.lit(RUN_DATE) == date_lookup.date, "left")
    .select("workspace_sk", "principal_sk", "role", "source_field", "confidence", "evidence", "date_sk", governance_bronze.snapshot_date)
)
gold_fact_workspace_principal_role.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_workspace_principal_role")

# %%
# --- gold_fact_deployment_stage_item: snapshot periódico ---
deploy_stage_item_bronze = spark.table("bronze_deployment_pipeline_stage_items").filter(F.col("snapshot_date") == RUN_DATE)
deployment_pipeline_lookup = spark.table("gold_dim_deployment_pipeline").select(
    F.col("deployment_pipeline_id"), F.col("deployment_pipeline_sk")
)
pipeline_stage_lookup = spark.table("gold_dim_pipeline_stage").select(
    F.col("pipeline_stage_bk"), F.col("pipeline_stage_sk")
)
source_item_lookup = item_lookup.withColumnRenamed("item_sk", "source_item_sk")
target_item_lookup = item_lookup.withColumnRenamed("item_sk", "target_item_sk")
gold_fact_deployment_stage_item = (
    deploy_stage_item_bronze
    .withColumn(
        "pipeline_stage_bk",
        F.concat_ws("~", F.col("deployment_pipeline_id"), F.col("stage_id")),
    )
    .join(deployment_pipeline_lookup, "deployment_pipeline_id", "left")
    .join(pipeline_stage_lookup, "pipeline_stage_bk", "left")
    .join(item_lookup, deploy_stage_item_bronze.item_id == item_lookup.item_bk, "left")
    .join(
        source_item_lookup,
        deploy_stage_item_bronze.source_item_id == source_item_lookup.item_bk,
        "left",
    )
    .join(
        target_item_lookup,
        deploy_stage_item_bronze.target_item_id == target_item_lookup.item_bk,
        "left",
    )
    .join(date_lookup, F.lit(RUN_DATE) == date_lookup.date, "left")
    .select(
        "deployment_pipeline_sk", "pipeline_stage_sk", "item_sk", "last_deployment_time",
        "source_item_sk", "target_item_sk", "date_sk", deploy_stage_item_bronze.snapshot_date,
    )
)
gold_fact_deployment_stage_item.write.format("delta").mode("overwrite") \
    .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'").partitionBy("snapshot_date").saveAsTable("gold_fact_deployment_stage_item")

print("Gold: hechos restantes (semantic_model_source/report, workspace_principal_role, deployment_stage_item) listos.")

# %% [markdown]
# ## Validación rápida dentro del propio notebook (antes de la Fase 5 externa)

# %%
for table_name in [
    "gold_dim_workspace", "gold_dim_capacity", "gold_dim_item", "gold_dim_source_object",
    "gold_dim_principal", "gold_dim_deployment_pipeline", "gold_dim_pipeline_stage", "gold_dim_date",
    "gold_fact_schedule", "gold_fact_job_run", "gold_fact_dependency_edge", "gold_fact_object_usage",
    "gold_fact_semantic_model_source", "gold_fact_semantic_model_report",
    "gold_fact_workspace_principal_role", "gold_fact_deployment_stage_item",
]:
    count = spark.table(table_name).count() if spark.catalog.tableExists(table_name) else -1
    print(f"{table_name}: {count} filas")
