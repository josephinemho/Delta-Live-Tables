-- Databricks notebook source
-- MAGIC %md-sandbox
-- MAGIC # Simplify ETL with Delta Live Table
-- MAGIC
-- MAGIC DLT makes Data Engineering accessible for all. Just declare your transformations in SQL or Python, and DLT will handle the Data Engineering complexity for you.
-- MAGIC
-- MAGIC <img style="float:right" src="https://github.com/QuentinAmbard/databricks-demo/raw/main/product_demos/dlt-golden-demo-1.png" width="900"/>
-- MAGIC
-- MAGIC **Accelerate ETL development** <br/>
-- MAGIC Enable analysts and data engineers to innovate rapidly with simple pipeline development and maintenance 
-- MAGIC
-- MAGIC **Remove operational complexity** <br/>
-- MAGIC By automating complex administrative tasks and gaining broader visibility into pipeline operations
-- MAGIC
-- MAGIC **Trust your data** <br/>
-- MAGIC With built-in quality controls and quality monitoring to ensure accurate and useful BI, Data Science, and ML 
-- MAGIC
-- MAGIC **Simplify batch and streaming** <br/>
-- MAGIC With self-optimization and auto-scaling data pipelines for batch or streaming processing 
-- MAGIC
-- MAGIC ## Our Delta Live Table pipeline
-- MAGIC
-- MAGIC We'll be using as input a raw dataset containing information on our customers Loan and historical transactions. 
-- MAGIC
-- MAGIC Our goal is to ingest this data in near real time and build table for our Analyst team while ensuring data quality.
-- MAGIC
-- MAGIC <!-- do not remove -->
-- MAGIC <img width="1px" src="https://www.google-analytics.com/collect?v=1&gtm=GTM-NKQ8TT7&tid=UA-163989034-1&cid=555&aip=1&t=event&ec=field_demos&ea=display&dp=%2F42_field_demos%2Ffeatures%2Fdlt%2Fnotebook_dlt_sql&dt=DLT">
-- MAGIC <!-- [metadata={"description":"Full DLT demo, going into details. Use loan dataset",
-- MAGIC  "authors":["dillon.bostwick@databricks.com"],
-- MAGIC  "db_resources":{},
-- MAGIC   "search_tags":{"vertical": "retail", "step": "Data Engineering", "components": ["autoloader", "dlt"]}}] -->

-- COMMAND ----------

-- MAGIC %md-sandbox 
-- MAGIC
-- MAGIC ## Bronze layer: incrementally ingest data leveraging Databricks Autoloader
-- MAGIC
-- MAGIC <img style="float: right; padding-left: 10px" src="https://github.com/QuentinAmbard/databricks-demo/raw/main/product_demos/dlt-golden-demo-2.png" width="900"/>
-- MAGIC
-- MAGIC Our raw data is being sent to a blob storage. 
-- MAGIC
-- MAGIC Autoloader simplify this ingestion, including schema inference, schema evolution while being able to scale to millions of incoming files. 
-- MAGIC
-- MAGIC Autoloader is available in SQL using the `cloud_files` function and can be used with a variety of format (json, csv, avro...):
-- MAGIC
-- MAGIC
-- MAGIC #### STREAMING LIVE TABLE 
-- MAGIC
-- MAGIC Defining tables as `STREAMING` will guarantee that you only consume new incoming data. Without `STREAMING`, you will scan and ingest all the data available at once. See the [documentation](https://docs.databricks.com/data-engineering/delta-live-tables/delta-live-tables-incremental-data.html) for more details

-- COMMAND ----------

CREATE STREAMING LIVE TABLE raw_txs2
  COMMENT "New raw loan data incrementally ingested from cloud object storage landing zone"
AS SELECT * FROM cloud_files('/demos/dlt/loans/raw_transactions', 'json', map("cloudFiles.inferColumnTypes", "true"))

-- COMMAND ----------

CREATE LIVE TABLE ref_accounting_treatment
  COMMENT "Lookup mapping for accounting codes"
AS SELECT * FROM delta.`/demos/dlt/loans/ref_accounting_treatment`

-- COMMAND ----------

-- CREATE STREAMING LIVE TABLE reference_loan_stats
--   COMMENT "Raw historical transactions"
-- AS SELECT * FROM cloud_files('/databricks-datasets/lending-club-loan-stats/LoanStats_*', 'csv')

-- COMMAND ----------

-- MAGIC %md-sandbox 
-- MAGIC
-- MAGIC ## Silver layer: joining tables while ensuring data quality
-- MAGIC
-- MAGIC <img style="float: right; padding-left: 10px" src="https://github.com/QuentinAmbard/databricks-demo/raw/main/product_demos/dlt-golden-demo-3.png" width="900"/>
-- MAGIC
-- MAGIC Once the bronze layer is defined, we'll create the sliver layers by Joining data. Note that bronze tables are referenced using the `LIVE` spacename. 
-- MAGIC
-- MAGIC To consume only increment from the Bronze layer like `BZ_raw_txs`, we'll be using the `stream` keyworkd: `stream(LIVE.BZ_raw_txs)`
-- MAGIC
-- MAGIC Note that we don't have to worry about compactions, DLT handles that for us.
-- MAGIC
-- MAGIC #### Expectations
-- MAGIC By defining expectations (`CONSTRAINT <name> EXPECT <condition>`), you can enforce and track your data quality. See the [documentation](https://docs.databricks.com/data-engineering/delta-live-tables/delta-live-tables-expectations.html) for more details

-- COMMAND ----------

CREATE STREAMING LIVE TABLE cleaned_new_txs (
  CONSTRAINT `Payments should be this year`  EXPECT (next_payment_date > date('2020-12-31')),
  CONSTRAINT `Balance should be positive`    EXPECT (balance > 0 AND arrears_balance > 0) ON VIOLATION DROP ROW,
  CONSTRAINT `Cost center must be specified` EXPECT (cost_center_code IS NOT NULL) ON VIOLATION FAIL UPDATE
)
  COMMENT "Livestream of new transactions, cleaned and compliant"
AS SELECT txs.*, ref.id as accounting_treatment FROM stream(LIVE.raw_txs2) txs
  INNER JOIN LIVE.ref_accounting_treatment ref ON txs.accounting_treatment_id = ref.id

-- COMMAND ----------

-- CREATE STREAMING LIVE TABLE historical_txs (
--   CONSTRAINT `Grade should be valid`  EXPECT (grade in ('A', 'B', 'C', 'D', 'E', 'F', 'G')),
--   CONSTRAINT `Recoveries shoud be int`  EXPECT (CAST(recoveries as INT) IS NOT NULL)
-- )
--   COMMENT "Historical loan transactions, cleaned"
-- AS SELECT l.* FROM stream(LIVE.reference_loan_stats) l

-- COMMAND ----------

-- MAGIC %md-sandbox 
-- MAGIC
-- MAGIC ## Gold layer
-- MAGIC
-- MAGIC <img style="float: right; padding-left: 10px" src="https://github.com/QuentinAmbard/databricks-demo/raw/main/product_demos/dlt-golden-demo-4.png" width="900"/>
-- MAGIC
-- MAGIC Our last step is to materialize the Gold Layer.
-- MAGIC
-- MAGIC Because these tables will be requested at scale using a SQL Endpoint, we'll add Zorder at the table level to ensure faster queries using `pipelines.autoOptimize.zOrderCols`, and DLT will handle the rest.

-- COMMAND ----------

-- CREATE LIVE TABLE total_loan_balances
--   COMMENT "Combines historical and new loan data for unified rollup of loan balances"
--   TBLPROPERTIES ("pipelines.autoOptimize.zOrderCols" = "location_code")
-- AS SELECT sum(revol_bal)  AS bal, addr_state   AS location_code FROM live.historical_txs  GROUP BY addr_state
--   UNION SELECT sum(balance) AS bal, country_code AS location_code FROM live.cleaned_new_txs GROUP BY country_code

-- COMMAND ----------

CREATE LIVE TABLE new_loan_balances_by_cost_center
  COMMENT "Live tabl of new loan balances for consumption by different cost centers"
AS SELECT sum(balance) AS bal, cost_center_code FROM live.cleaned_new_txs
  GROUP BY cost_center_code

-- COMMAND ----------

-- CREATE LIVE TABLE new_loan_balances_by_country
--   COMMENT "Live table of new loan balances per country"
-- AS SELECT sum(count) AS count, country_code FROM live.cleaned_new_txs GROUP BY country_code

-- COMMAND ----------

-- MAGIC %md ## Next steps
-- MAGIC
-- MAGIC Your DLT pipeline is ready to be started.
-- MAGIC
-- MAGIC Open the DLT menu, create a pipeline and select this notebook to run it. To generate sample data, please run the [companion notebook]($./00-Loan-Data-Generator) (make sure the path where you read and write the data are the same!)
-- MAGIC
-- MAGIC Data Analyst can start using DBSQL to analyze data and track our Loan metrics.  Data Scientist can also access the data to start building models to predict payment default or other more advanced use-cases.
