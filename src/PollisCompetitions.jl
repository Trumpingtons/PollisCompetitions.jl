"""
	PollisCompetitions

Datasets on which models are scored and ranked, for Pollis: the Dataset Catalog, the Model Catalog and the Benchmarks
(the scores of each model on each dataset), kept as TOML in `metadata/` and loaded into five tables of DuckDB, and the
built-in datasets, Parquet files in `data/builtin/`, which DuckDB reads where they are. The data of a forecasting
dataset are read by `series` and `observations`, and forecasts of it scored by `score`, as its organisers scored them.

```julia
import PollisCompetitions as PC
datasets = PC.load_table("dataset_catalog")
comparisons = PC.load_table("model_comparisons")
data = PC.load_dataset("nab")
yearly = PC.series("m4"; frequency = "Yearly")
scores = PC.score("m4", (; series = [1, 1], h = [1, 2], value = [7300.0, 7350.0]))
```
"""
module PollisCompetitions

import DBInterface
import DuckDB
import TOML
import Tables
using Dates: Date, Day

include("m4benchmarks/M4Benchmarks.jl")
import .M4Benchmarks
include("monash.jl")
include("database.jl")
include("parquet.jl")
include("data.jl")
include("tables.jl")
include("measures.jl")
include("benchmarks.jl")

end
