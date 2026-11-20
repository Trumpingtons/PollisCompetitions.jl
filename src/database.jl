"""The metadata of the package: `datasets.toml`, `models.toml` and `benchmarks.toml`."""
const METADATA = joinpath(dirname(@__DIR__), "metadata")

"""The built-in datasets: one Parquet file for each, named by its `dataset_id`."""
const BUILTIN = joinpath(dirname(@__DIR__), "data", "builtin")

"""The five tables of the metadata, in the order they are filled: each after the tables its foreign keys name."""
const METADATA_TABLES = ("dataset_catalog", "dataset_references", "model_catalog", "model_references", "benchmarks")

"""
The vocabulary of the estimator of a model, in two levels: each estimator family, the model types of TabArena,
Statistical for the classical methods of forecasting and of survival analysis, Kernel Methods, Fuzzy System, and Hybrid
for a model that combines methods of different kinds, with its estimator methods; the method of a Hybrid model names the
methods it combines. A value is added when a model of the catalogue needs it.
"""
const ESTIMATOR_METHODS = (
	"Foundation Model" => ["Pretrained in-context learner", "Pretrained hypernetwork", "Fine-tuned pretrained transformer", "Pretrained time-series forecaster"],
	"Tree-based" => ["Gradient-boosted trees", "Randomized tree ensemble", "Generalized additive model", "Decision tree"],
	"Neural Network" => ["Multilayer perceptron", "Ensemble of multilayer perceptrons", "Neural nearest neighbours", "Recurrent neural network",
		"Convolutional neural network", "Transformer", "Functional network", "Adaptive logic network", "Autoencoder", "Other neural network"],
	"Baseline" => ["Nearest neighbours", "Penalized linear model", "Linear regression", "Polynomial regression", "Naive forecast",
		"Time series decomposition", "Nonparametric survival estimator"],
	"Statistical" => ["Exponential smoothing", "Theta method", "ARIMA", "Automatic model selection", "Other statistical method",
		"Proportional hazards model", "Accelerated failure time model", "Flexible parametric survival model"],
	"Kernel Methods" => ["Support vector machine", "Kernel adaptive filtering", "Feature-learning kernel machine"],
	"Fuzzy System" => ["Fuzzy rule-based system", "Neuro-fuzzy system", "Fuzzy time series", "Fuzzy transform", "Association rules"],
	"Hybrid" => ["Neural networks, Gaussian processes", "Neural networks, Gaussian processes, Linear models",
		"Time series decomposition, Neural networks, Theta method", "Self-organising maps, Empirical orthogonal functions",
		"Nearest neighbours, Support vector machines", "Neural networks, Model trees", "Neural networks, Nearest neighbours",
		"Neural networks, Nearest neighbours, Statistical methods", "Neural networks, Exponential smoothing",
		"Fuzzy time series, Exponential smoothing", "Fuzzy time series, ARIMA", "Self-organising maps, Multivariate adaptive regression splines",
		"Self-organising maps, Intervention analysis", "Neural networks, Fuzzy logic", "Statistical methods, Fuzzy logic"],
	"Other" => ["Piecewise linear regression", "Componentwise boosting"],
)

"""The SQL condition that the estimator method of a model is one of the methods of its estimator family."""
const ESTIMATOR_CHECK = join(("(estimator_family = '$(family)' AND estimator_method IN ($(join(("'$(method)'" for method in methods), ", "))))"
	for (family, methods) in ESTIMATOR_METHODS), "\n\t\tOR ")

"""The SQL that creates the five tables."""
const METADATA_SCHEMA = """
CREATE TABLE dataset_catalog (
	dataset_id       VARCHAR PRIMARY KEY,
	dataset_name     VARCHAR NOT NULL,
	competition_name VARCHAR,
	competition_year INTEGER,
	topic            VARCHAR NOT NULL,
	data_structure   VARCHAR CHECK (data_structure IN ('Cross-section', 'Time-Series', 'Panel')),
	geometry         VARCHAR CHECK (geometry IN ('None', 'Spatial Weights Matrix', 'Coordinates', 'Polygons')),
	response_type    VARCHAR CHECK (response_type IN ('Binary', 'Multiclass', 'Ordered', 'Count', 'Survival', 'Continuous')),
	rows             BIGINT CHECK (rows > 0),
	features         INTEGER CHECK (features >= 0),
	size_mb          DOUBLE CHECK (size_mb >= 0),
	licence          VARCHAR,
	delivery         VARCHAR CHECK (delivery IN ('Built-in', 'Download')),
	source_url       VARCHAR,
	CHECK ((competition_name IS NULL) = (competition_year IS NULL))
);
CREATE TABLE dataset_references (
	dataset_id VARCHAR NOT NULL REFERENCES dataset_catalog (dataset_id),
	bibtex_key VARCHAR NOT NULL,
	role       VARCHAR CHECK (role IN ('Primary', 'Competition', 'Benchmark', 'Other')),
	PRIMARY KEY (dataset_id, bibtex_key)
);
CREATE TABLE model_catalog (
	model_id         VARCHAR PRIMARY KEY,
	model_name       VARCHAR NOT NULL,
	estimator_family VARCHAR NOT NULL,
	estimator_method VARCHAR NOT NULL,
	package          VARCHAR,
	language         VARCHAR CHECK (language IN ('Julia', 'Python', 'R', 'C/C++', 'Fortran')),
	CHECK ($(ESTIMATOR_CHECK))
);
CREATE TABLE model_references (
	model_id   VARCHAR NOT NULL REFERENCES model_catalog (model_id),
	bibtex_key VARCHAR NOT NULL,
	role       VARCHAR CHECK (role IN ('Methodology', 'Software', 'Other')),
	PRIMARY KEY (model_id, bibtex_key)
);
CREATE TABLE benchmarks (
	run_id         VARCHAR NOT NULL,
	model_id       VARCHAR NOT NULL REFERENCES model_catalog (model_id),
	dataset_id     VARCHAR NOT NULL REFERENCES dataset_catalog (dataset_id),
	split_protocol VARCHAR NOT NULL,
	metric         VARCHAR NOT NULL,
	score          DOUBLE NOT NULL,
	PRIMARY KEY (run_id, metric)
);
"""

"""The columns of each of the five tables, in the order of `METADATA_SCHEMA`."""
const METADATA_COLUMNS = Dict(
	"dataset_catalog" => ["dataset_id", "dataset_name", "competition_name", "competition_year", "topic", "data_structure", "geometry", "response_type", "rows", "features", "size_mb", "licence", "delivery", "source_url"],
	"dataset_references" => ["dataset_id", "bibtex_key", "role"],
	"model_catalog" => ["model_id", "model_name", "estimator_family", "estimator_method", "package", "language"],
	"model_references" => ["model_id", "bibtex_key", "role"],
	"benchmarks" => ["run_id", "model_id", "dataset_id", "split_protocol", "metric", "score"],
)

"""
What each table of the metadata and the view `model_comparisons` hold, by their names, and what each of their columns
holds, by `<table>.<column>`; a column of `model_comparisons` is described as in the table it comes from.
"""
const METADATA_DESCRIPTIONS = Dict(
	"dataset_catalog" => "The Dataset Catalog: one row per dataset, with its competition, its subject, the structure of its data, its size, its licence and how it reaches the user",
	"dataset_catalog.dataset_id" => "The id of the dataset, and the schema of its views in this database when its data are here, built in or downloaded",
	"dataset_catalog.dataset_name" => "Its name",
	"dataset_catalog.competition_name" => "The competition it comes from; empty for a dataset of no competition",
	"dataset_catalog.competition_year" => "The year of that competition",
	"dataset_catalog.topic" => "Its subject, such as Finance, Energy or Health",
	"dataset_catalog.data_structure" => "Cross-section, Time-Series or Panel",
	"dataset_catalog.geometry" => "None, Spatial Weights Matrix, Coordinates or Polygons, from the poorest to the richest",
	"dataset_catalog.response_type" => "Binary, Multiclass, Ordered, Count, Survival or Continuous",
	"dataset_catalog.rows" => "The rows of its data as stored; for a panel, one for each unit and time",
	"dataset_catalog.features" => "The columns other than the response and the identifiers",
	"dataset_catalog.size_mb" => "The size in MB of its Parquet files for a Built-in dataset, or of the files the user downloads, compressed or not, for a Download dataset",
	"dataset_catalog.licence" => "The licence of its data",
	"dataset_catalog.delivery" => "Built-in, shipped with the package, or Download, fetched by the user from its source",
	"dataset_catalog.source_url" => "Where its data come from",
	"dataset_references" => "The works of each dataset: one row per dataset and work, a key of the references of Pollis (PollisReferences)",
	"dataset_references.dataset_id" => "The dataset; join dataset_catalog on dataset_id",
	"dataset_references.bibtex_key" => "The key of the work in PollisReferences",
	"dataset_references.role" => "What the work is to the dataset: Primary, Competition, Benchmark or Other",
	"model_catalog" => "The Model Catalog: one row per model, with its estimator in two levels, family and method, and the package that implements it",
	"model_catalog.model_id" => "The id of the model",
	"model_catalog.model_name" => "Its name",
	"model_catalog.estimator_family" => "The family of its estimator: the model types of TabArena, Statistical, Kernel Methods, Fuzzy System or Hybrid, for a model that combines methods of different kinds",
	"model_catalog.estimator_method" => "The method it estimates with, one of those of its family; that of a Hybrid model names the methods it combines",
	"model_catalog.package" => "The package that implements it",
	"model_catalog.language" => "The language of that package: Julia, Python, R, C/C++ or Fortran",
	"model_references" => "The works of each model: one row per model and work, a key of the references of Pollis (PollisReferences)",
	"model_references.model_id" => "The model; join model_catalog on model_id",
	"model_references.bibtex_key" => "The key of the work in PollisReferences",
	"model_references.role" => "What the work is to the model: Methodology, Software or Other",
	"benchmarks" => "The Benchmarks: one row per run of a model on a dataset and metric, with its score, as its paper or the organisers published it",
	"benchmarks.run_id" => "The id of the run, <model_id>.<dataset_id>, with a subset of the dataset after it when the run scores one",
	"benchmarks.model_id" => "The model; join model_catalog on model_id",
	"benchmarks.dataset_id" => "The dataset; join dataset_catalog on dataset_id",
	"benchmarks.split_protocol" => "How the data were split into training and test",
	"benchmarks.metric" => "The metric, such as rmse, roc_auc, mean_smape or mape",
	"benchmarks.score" => "The score of the run by that metric",
	"model_comparisons" => "Each score of benchmarks beside its model and its dataset",
)

"""What each kind of Parquet file of a dataset holds, by its name, and each of its columns, by `<file>.<column>`."""
const DATA_DESCRIPTIONS = Dict(
	"data" => "The data of a tabular dataset, a row per case, with its response and its features",
	"splits" => "The splits of the cross-validation of a tabular dataset: the fold each row is in the test set of, in each repeat; a dataset with one fixed split has one repeat and one fold, and lists only its test rows",
	"splits.row" => "The row of data, from 1",
	"splits.repeat" => "The repeat of the cross-validation, from 1",
	"splits.fold" => "The fold whose test set the row is in, in that repeat, from 1",
	"series" => "The series of a forecasting dataset, a row each: its number, its name in the source, its frequency, seasonal period and horizon, its domain and its start",
	"series.series" => "The number of the series",
	"series.competition" => "The id of the dataset",
	"series.name" => "The name of the series in the source",
	"series.frequency" => "Its frequency, such as Yearly or Monthly",
	"series.period" => "Its seasonal period: 12 for a monthly series, 1 for one without seasons",
	"series.horizon" => "The number of steps ahead its forecasts are scored on",
	"series.domain" => "Its domain, as the source gives it",
	"series.start" => "When it starts, as the source gives it",
	"observations" => "The values of the series of a forecasting dataset: those the forecasters saw, split train, and those their forecasts were scored on, split test",
	"observations.series" => "The number of the series; join series on series",
	"observations.t" => "The time, from 1",
	"observations.value" => "The value",
	"observations.split" => "train, a value the forecasters saw, or test, a value their forecasts were scored on",
)

"""
	describe_db(db, catalog, folders)

The descriptions of the tables and views of `db`, and of their columns, as `connect_db` makes them: those of the
metadata, and those of the views of each dataset whose data are here, `folders` giving the folder of each by its id,
with its name and licence from `catalog`, the rows of `dataset_catalog`.
"""
function describe_db(db, catalog, folders)
	execute(sql) = DBInterface.execute(db, sql)
	for table in (METADATA_TABLES..., "model_comparisons")
		execute("COMMENT ON $(table == "model_comparisons" ? "VIEW" : "TABLE") $(table) IS $(sql_text(METADATA_DESCRIPTIONS[table]))")
	end
	columns = Tables.columntable(execute("SELECT schema_name, table_name, column_name FROM duckdb_columns() WHERE database_name = current_database() AND NOT internal"))
	for (schema, table, column) in zip(columns.schema_name, columns.table_name, columns.column_name)
		if schema == "main"
			keys = ["$(source).$(column)" for source in (table == "model_comparisons" ? ("benchmarks", "model_catalog", "dataset_catalog") : (table,))]
			key = findfirst(key -> haskey(METADATA_DESCRIPTIONS, key), keys)
			description = key === nothing ? nothing : METADATA_DESCRIPTIONS[keys[key]]
		else
			info = joinpath(folders[schema], "info.toml")
			fields = isfile(info) ? TOML.parsefile(info) : Dict{String, Any}()
			description = table != "data" ? get(DATA_DESCRIPTIONS, "$(table).$(column)", nothing) :
				column == get(fields, "target", nothing) ? (haskey(fields, "event") ? "The response, which the models predict: the time to the event, or to censoring" : "The response, which the models predict") :
				column == get(fields, "event", nothing) ? "Whether the time of the response is that of the event (1) or a censored time (0)" : nothing
		end
		description === nothing || execute("COMMENT ON COLUMN \"$(schema)\".\"$(table)\".\"$(column)\" IS $(sql_text(description))")
	end
	field(name) = findfirst(==(name), METADATA_COLUMNS["dataset_catalog"])
	datasets = Dict(row[field("dataset_id")] => (row[field("dataset_name")], row[field("licence")]) for row in catalog)
	for schema in unique(filter(!=("main"), columns.schema_name)), table in unique(columns.table_name[columns.schema_name .== schema])
		name, licence = get(datasets, schema, (schema, missing))
		text = "$(name): $(get(DATA_DESCRIPTIONS, table, table)). Licence: $(coalesce(licence, "none recorded"))"
		execute("COMMENT ON VIEW \"$(schema)\".\"$(table)\" IS $(sql_text(text))")
	end
end

"""The tables under `key` of the TOML file `name` in the folder `metadata` (an empty list when there are none)."""
metadata_entries(metadata, name, key) = get(TOML.parsefile(joinpath(metadata, name)), key, [])

"""
	metadata_rows(metadata = METADATA)

The rows of each of the five tables, as the TOML files in the folder `metadata` give them: a Dict from the name of a table to
its rows, each a vector of values in the order of its columns, `missing` for a field the file leaves out. The nested
references of a dataset or model become rows of its references table, and each score of a run a row of `benchmarks`.
"""
function metadata_rows(metadata = METADATA)
	rows = Dict(table => Vector{Vector{Any}}() for table in METADATA_TABLES)
	values(entry, table) = Any[get(entry, column, missing) for column in METADATA_COLUMNS[table]]
	for (file, key, table, references, id) in (("datasets.toml", "datasets", "dataset_catalog", "dataset_references", "dataset_id"),
	                                           ("models.toml", "models", "model_catalog", "model_references", "model_id"))
		for entry in metadata_entries(metadata, file, key)
			push!(rows[table], values(entry, table))
			for reference in get(entry, "references", [])
				push!(rows[references], values(merge(reference, Dict(id => entry[id])), references))
			end
		end
	end
	for run in metadata_entries(metadata, "benchmarks.toml", "runs")
		for (metric, score) in sort!(collect(get(run, "scores", Dict())); by = first)
			push!(rows["benchmarks"], values(merge(run, Dict("metric" => metric, "score" => score)), "benchmarks"))
		end
	end
	rows
end

"""
	connect_db(path = ":memory:"; metadata = METADATA, builtin = BUILTIN, downloaded = HOME)

A DuckDB database at `path` with the five tables of the metadata (`dataset_catalog`, `dataset_references`,
`model_catalog`, `model_references` and `benchmarks`) filled from the TOML files in the folder `metadata`, the view `model_comparisons`, which
joins each score to its model and dataset, and, for each dataset of the catalogue whose data are here, a schema named
by its id with a view of each of its Parquet files, named by the file, which reads it where it is: `nn5.series` and
`nn5.observations` for a forecasting dataset, `heloc.data` and `heloc.splits` for a tabular one. The data of a dataset
are its folder in `builtin` when it is built in, else its folder in `downloaded` once its `info.toml` is there; a
folder named by no dataset of the catalogue is left out. Each table, view and column has its description
(`describe_db`). Close it with `DBInterface.close!`.
"""
function connect_db(path::AbstractString = ":memory:"; metadata = METADATA, builtin = BUILTIN, downloaded = HOME)
	db = DuckDB.DB(path)
	try
		for statement in split(METADATA_SCHEMA, ";"; keepempty = false)
			isempty(strip(statement)) || DBInterface.execute(db, statement)
		end
		rows = metadata_rows(metadata)
		for table in METADATA_TABLES
			isempty(rows[table]) && continue
			columns = METADATA_COLUMNS[table]
			statement = DBInterface.prepare(db, "INSERT INTO $(table) ($(join(columns, ", "))) VALUES ($(join(fill("?", length(columns)), ", ")))")
			try
				foreach(row -> DBInterface.execute(statement, row), rows[table])
			finally
				DBInterface.close!(statement)
			end
		end
		DBInterface.execute(db, """
			CREATE VIEW model_comparisons AS
			SELECT b.run_id, b.model_id, m.model_name, m.estimator_family, m.estimator_method, m.package, m.language,
				b.dataset_id, d.dataset_name, d.data_structure, d.geometry, d.response_type,
				b.split_protocol, b.metric, b.score
			FROM benchmarks b
			JOIN model_catalog m USING (model_id)
			JOIN dataset_catalog d USING (dataset_id)""")
		taken = Set(Tables.columntable(DBInterface.execute(db, "SELECT DISTINCT schema_name FROM duckdb_schemas()")).schema_name)
		folders = Dict{String, String}()
		for dataset_id in (row[1] for row in rows["dataset_catalog"])
			here = joinpath(builtin, dataset_id)
			away = joinpath(downloaded, dataset_id)
			folder = isdir(here) ? here : isfile(joinpath(away, "info.toml")) ? away : nothing
			folder === nothing && continue
			files = filter(endswith(".parquet"), readdir(folder))
			isempty(files) && continue
			dataset_id in taken && error("The dataset $(dataset_id) has the name of a schema of DuckDB: rename it.")
			folders[dataset_id] = folder
			DBInterface.execute(db, "CREATE SCHEMA \"$(dataset_id)\"")
			for file in files
				DBInterface.execute(db, "CREATE VIEW \"$(dataset_id)\".\"$(chopsuffix(file, ".parquet"))\" AS SELECT * FROM read_parquet($(sql_text(joinpath(folder, file))))")
			end
		end
		describe_db(db, rows["dataset_catalog"], folders)
	catch
		DBInterface.close!(db)
		rethrow()
	end
	db
end

"""
	load_table(name)

The table `name` of the metadata, one of `dataset_catalog`, `dataset_references`, `model_catalog`,
`model_references`, `benchmarks` and `model_comparisons`, as a table of columns (a NamedTuple of vectors).
"""
function load_table(name::AbstractString)
	name in (METADATA_TABLES..., "model_comparisons") || error("No table $(name): one of $(join((METADATA_TABLES..., "model_comparisons"), ", ")).")
	db = connect_db()
	try
		Tables.columntable(DBInterface.execute(db, "SELECT * FROM $(name)"))
	finally
		DBInterface.close!(db)
	end
end

"""
	load_dataset(dataset_id)

The data of the built-in dataset `dataset_id`, as a table of columns (a NamedTuple of vectors), read from `data.parquet`
in its folder, `data/builtin/<dataset_id>`.
"""
function load_dataset(dataset_id::AbstractString)
	datasets = metadata_entries(METADATA, "datasets.toml", "datasets")
	entry = findfirst(entry -> entry["dataset_id"] == dataset_id, datasets)
	entry === nothing && error("No dataset $(dataset_id) in the Dataset Catalog.")
	delivery = get(datasets[entry], "delivery", missing)
	delivery == "Built-in" || error("$(dataset_id) is not built in: its delivery is $(coalesce(delivery, "unknown")).")
	path = joinpath(BUILTIN, dataset_id, "data.parquet")
	isfile(path) || error("The data of $(dataset_id) are not on this computer: $(path) is missing.")
	with_database(db -> Tables.columntable(DBInterface.execute(db, "SELECT * FROM read_parquet($(sql_text(path)))")))
end
