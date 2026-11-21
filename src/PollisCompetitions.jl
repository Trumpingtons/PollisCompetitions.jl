"""
	PollisCompetitions

Datasets on which models are scored and ranked, for Pollis: the Dataset Catalog, the Model Catalog and the Benchmarks
(the scores of each model on each dataset), kept as TOML in `metadata/` and loaded into five tables of DuckDB, and the
built-in datasets, Parquet files in `data/builtin/`, which DuckDB reads where they are. The data of a forecasting
dataset are read by `series` and `observations`, and forecasts of it scored by `score`.

```julia
import PollisCompetitions as PC
datasets = PC.load_table("dataset_catalog")
comparisons = PC.load_table("model_comparisons")
data = PC.load_dataset("german_credit")
monthly = PC.series("tourism_2011"; frequency = "Monthly")
scores = PC.score("nn3", PC.benchmarks("nn3"; methods = ["Theta"]))
```
"""
module PollisCompetitions

import DBInterface
import DuckDB
import Printf
import TOML
import Tables

include("benchmarks/Benchmarks.jl")
import .Benchmarks
include("monash.jl")
include("database.jl")
include("parquet.jl")
include("data.jl")
include("tables.jl")
include("measures.jl")
include("survival.jl")
include("tabular.jl")
include("scoring.jl")
include("dataset_benchmarks.jl")

end
