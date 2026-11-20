"""The metadata of the package: `datasets.toml`, `models.toml` and `benchmarks.toml`."""
const METADATA = joinpath(dirname(@__DIR__), "metadata")

"""The built-in datasets: one Parquet file for each, named by its `dataset_id`."""
const BUILTIN = joinpath(dirname(@__DIR__), "data", "builtin")

"""The five tables of the metadata, in the order they are filled: each after the tables its foreign keys name."""
const METADATA_TABLES = ("dataset_catalog", "dataset_references", "model_catalog", "model_references", "benchmarks")

"""
The vocabulary of the estimator of a model, in two levels: each estimator family, the model types of TabArena, with its
estimator methods. A value is added when a model of the catalogue needs it.
"""
const ESTIMATOR_METHODS = (
	"Foundation Model" => ["Pretrained in-context learner", "Pretrained hypernetwork", "Fine-tuned pretrained transformer"],
	"Tree-based" => ["Gradient-boosted trees", "Randomized tree ensemble", "Generalized additive model"],
	"Neural Network" => ["Multilayer perceptron", "Ensemble of multilayer perceptrons", "Neural nearest neighbours"],
	"Baseline" => ["Nearest neighbours", "Penalized linear model"],
	"Other" => ["Kernel machine", "Piecewise linear regression"],
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
	response_type    VARCHAR CHECK (response_type IN ('Binary', 'Multiclass', 'Ordered', 'Count', 'Survival', 'Regression')),
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
	package          VARCHAR NOT NULL,
	language         VARCHAR NOT NULL CHECK (language IN ('Julia', 'Python', 'R', 'C/C++', 'Fortran')),
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
	connect_db(path = ":memory:"; metadata = METADATA, builtin = BUILTIN)

A DuckDB database at `path` with the five tables of the metadata (`dataset_catalog`, `dataset_references`,
`model_catalog`, `model_references` and `benchmarks`) filled from the TOML files in the folder `metadata`, the view `model_comparisons`, which
joins each score to its model and dataset, and, in the schema `builtin`, a view of each built-in dataset, a folder of the
folder `builtin`, `builtin."<dataset_id>"`, which reads its `data.parquet` where it is. Close it with `DBInterface.close!`.
"""
function connect_db(path::AbstractString = ":memory:"; metadata = METADATA, builtin = BUILTIN)
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
		DBInterface.execute(db, "CREATE SCHEMA builtin")
		for dataset_id in (isdir(builtin) ? readdir(builtin) : String[])
			data = joinpath(builtin, dataset_id, "data.parquet")
			isfile(data) || continue
			DBInterface.execute(db, "CREATE VIEW builtin.\"$(dataset_id)\" AS SELECT * FROM read_parquet($(sql_text(data)))")
		end
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
