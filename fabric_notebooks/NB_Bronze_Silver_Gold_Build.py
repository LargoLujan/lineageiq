# NB_Bronze_Silver_Gold_Build
#
# Source for a Fabric PySpark notebook. Fabric cannot be created/edited
# remotely from this repository, so this file is pasted by hand into a new
# notebook inside the Lakehouse created beforehand (see
# docs/101_medallion_lakehouse_provisioning.md). Each block delimited by
# "# %%" is an independent cell -- paste them in the same order.
#
# What it does, in three passes over the same Lakehouse:
#   1. Bronze: reads Files/bronze/<entity>/snapshot_date=<date>/<entity>.csv
#      (uploaded by scripts/64_upload_bronze_to_onelake.py) and writes it as
#      a managed Delta table bronze_<entity>, partitioned by snapshot_date.
#   2. Silver: deduplicates, types, and assigns a deterministic UUID
#      surrogate key to each dimension.
#   3. Gold: builds the Kimball star schema (dim_*/fact_*) that Power BI
#      will consume in DirectLake.
#
# Important note on "porting the classification logic": the CSV
# analysis/object_read_write_classification.csv that lands in Bronze is
# ALREADY the final output of scripts/23_build_object_read_write_classification.ps1
# -- it already carries usage_type_normalized, object_type_status,
# object_type_source and object_type_confidence resolved. That is why this
# notebook does NOT reimplement that classification in Spark (it avoids
# having two independent implementations of the same business rule, which
# is exactly the drift risk to avoid) -- Silver here only conforms keys and
# types on columns that already arrive correct from the source.

# %% [markdown]
# ## Configuration

# %%
from datetime import date
import uuid

RUN_DATE = date.today().isoformat()  # change this if you are reprocessing a specific snapshot_date
UUID_NAMESPACE = uuid.UUID("6f1a1f2e-9c3d-4e7a-8b2a-1d4c9e6f0a11")  # fixed project namespace -- never change

# entity -> relative path inside Files/bronze/ (must match exactly
# ENTITY_SOURCE_PATHS in scripts/64_upload_bronze_to_onelake.py)
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

# Columns that must ALWAYS stay as strings, never be left to numeric
# inference -- they are GUIDs or identifiers, not quantities.
ID_LIKE_COLUMN_SUFFIXES = ("_id", "_key")
ID_LIKE_COLUMN_NAMES = {
    "technical_id", "qualified_name", "object_key", "schedule_id", "job_instance_id",
    "root_activity_id", "domain_id", "capacity_id",
}

# %% [markdown]
# ## Helper functions

# %%
from pyspark.sql import functions as F
from pyspark.sql.types import StringType
from pyspark.sql.window import Window


def deterministic_uuid(business_key: str) -> str:
    """Stable UUID5: the same business key always produces the same
    UUID, on any load -- no need for a keymap table with a counter to keep
    surrogate keys consistent across snapshots."""
    if business_key is None:
        return None
    return str(uuid.uuid5(UUID_NAMESPACE, str(business_key).strip().lower()))


deterministic_uuid_udf = F.udf(deterministic_uuid, StringType())


def cast_id_like_columns_to_string(df):
    """After reading with inferSchema, force to string any column whose
    name clearly marks it as an identifier (GUID, key, etc.) -- prevents
    Spark from inferring an ID as numeric just because it looks like one."""
    for column_name in df.columns:
        lower_name = column_name.lower()
        if lower_name in ID_LIKE_COLUMN_NAMES or lower_name.endswith(ID_LIKE_COLUMN_SUFFIXES):
            df = df.withColumn(column_name, F.col(column_name).cast(StringType()))
    return df


def normalize_key(column):
    """Replicates PowerShell's Normalize-Key: lowercase, trim, collapse
    whitespace -- applied the same way to any column that serves as a
    business key, in any table."""
    return F.regexp_replace(F.trim(F.lower(column)), r"\s+", " ")


# %% [markdown]
# ## Bronze layer: landing

# %%
for entity in BRONZE_ENTITIES:
    source_path = f"Files/bronze/{entity}/snapshot_date={RUN_DATE}/{entity}.csv"
    try:
        raw_df = spark.read.csv(source_path, header=True, inferSchema=True)
    except Exception as exc:  # noqa: BLE001 - a missing entity must not stop the others
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
    # Idempotent: if a load already exists for this snapshot_date, only
    # that partition is replaced instead of duplicating rows.
    if spark.catalog.tableExists(table_name):
        bronze_df.write.format("delta").mode("overwrite") \
            .option("replaceWhere", f"snapshot_date = '{RUN_DATE}'") \
            .partitionBy("snapshot_date").saveAsTable(table_name)
    else:
        bronze_df.write.format("delta").mode("overwrite") \
            .partitionBy("snapshot_date").saveAsTable(table_name)

    print(f"[bronze][ok] {table_name}: {bronze_df.count()} filas para snapshot_date={RUN_DATE}")

# %% [markdown]
# ## Silver layer: conforming
#
# Every block from here on depends on the previous Bronze cell having
# already run (it reads the freshly written bronze_* tables).

# %%
# --- Dimension: workspace ---
silver_workspace = (
    spark.table("bronze_workspaces")
    .withColumn("workspace_bk", F.col("technical_id"))
    .withColumn("workspace_sk", deterministic_uuid_udf(F.col("technical_id")))
)

# --- Dimension: capacity (its own dimension, not just a workspace attribute) ---
silver_capacity = (
    silver_workspace
    .select("capacity_id", "capacity_name", "capacity_region")
    .filter(F.col("capacity_id").isNotNull())
    .dropDuplicates(["capacity_id"])
    .withColumn("capacity_sk", deterministic_uuid_udf(F.col("capacity_id")))
)

# --- Dimension: item (notebooks, copyjobs, pipelines, semantic models,
#     reports -- all live together here, with item_type as an attribute,
#     which is the correct Kimball practice) ---
silver_item = (
    spark.table("bronze_items")
    .withColumn("item_bk", F.coalesce(F.col("technical_id"), F.col("qualified_name")))
    .withColumn("item_sk", deterministic_uuid_udf(F.col("item_bk")))
)

# --- Dimension: source object (table/view/SP/column) ---
# object_read_write_classification.csv already carries object_type/object_type_source/
# object_type_confidence resolved -- nothing is re-derived here, it only
# conforms one row per object_key.
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

# --- Dimension: principal/owner ---
silver_principal = (
    spark.table("bronze_workspace_governance_principals")
    .withColumn("principal_bk", F.coalesce(F.col("principal_email"), F.col("principal_name")))
    .withColumn("principal_sk", deterministic_uuid_udf(F.col("principal_bk")))
)

# --- Dimension: deployment pipeline + stage ---
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
# --- Run deduplication (mixed grain: schedule vs job_instance) ---
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
# ## Gold layer: dimensions (SCD2 on workspace/item/source_object, Type 1 for the rest)

# %%
def upsert_scd2(silver_df, gold_table_name, business_key_col, surrogate_key_col, tracked_columns):
    """Simple SCD Type 2: if the most recent row in Silver differs from the
    current version in Gold in any tracked column, close the previous
    version (effective_to/is_current=false) and open a new one."""
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
# --- Type 1 dimensions (overwrite, no version history) ---
silver_capacity.write.format("delta").mode("overwrite").saveAsTable("gold_dim_capacity")
silver_principal.write.format("delta").mode("overwrite").saveAsTable("gold_dim_principal")
silver_deployment_pipeline.write.format("delta").mode("overwrite").saveAsTable("gold_dim_deployment_pipeline")
silver_pipeline_stage.write.format("delta").mode("overwrite").saveAsTable("gold_dim_pipeline_stage")

# --- Calendar dimension (generated, does not come from any CSV) ---
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
# ## Gold layer: facts (all with snapshot_date, except the immutable job_run event)

# %%
workspace_lookup = spark.table("gold_dim_workspace").filter(F.col("is_current")).select("workspace_bk", "workspace_sk")
item_lookup = spark.table("gold_dim_item").filter(F.col("is_current")).select(
    F.col("item_bk"), F.col("item_sk"), F.col("qualified_name").alias("item_qualified_name_lookup")
)
object_lookup = spark.table("gold_dim_source_object").filter(F.col("is_current")).select("object_key", "object_sk")
date_lookup = spark.table("gold_dim_date").select("date", "date_sk")

# %%
# --- gold_fact_schedule: periodic snapshot, one schedule_id per date ---
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
# --- gold_fact_job_run: transaction, immutable event already deduplicated ---
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
    # Only job_instance_id values that do not exist yet are added -- a job_run
    # already recorded is a past event and must not change between snapshots.
    existing_ids = spark.table("gold_fact_job_run").select("job_instance_id")
    gold_fact_job_run = gold_fact_job_run.join(existing_ids, "job_instance_id", "left_anti")
    gold_fact_job_run.write.format("delta").mode("append").saveAsTable("gold_fact_job_run")
else:
    gold_fact_job_run.write.format("delta").mode("overwrite").saveAsTable("gold_fact_job_run")

# %%
# --- gold_fact_dependency_edge: periodic snapshot ---
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
# --- gold_fact_object_usage: periodic snapshot -- already classified at
#     the source (see the note at the top of the notebook), only conformed ---
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
# --- gold_fact_semantic_model_source: periodic snapshot ---
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
# --- gold_fact_semantic_model_report: periodic snapshot ---
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
# --- gold_fact_workspace_principal_role: periodic snapshot ---
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
# --- gold_fact_deployment_stage_item: periodic snapshot ---
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
# ## Quick validation inside the notebook itself (before the external check)

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
