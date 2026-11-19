"""
	PollisCompetitions

Datasets on which models are scored and ranked, for Pollis: the Dataset Catalog, the Model Catalog and the Benchmarks
(the scores of each model on each dataset), kept as TOML in `metadata/` and loaded into five tables of DuckDB, and the
built-in datasets, one Parquet file each in `data/builtin/`, which DuckDB reads where they are.

```julia
import PollisCompetitions as PC
datasets = PC.load_table("dataset_catalog")
comparisons = PC.load_table("model_comparisons")
data = PC.load_dataset("nab")
db = PC.connect_db()
```
"""
module PollisCompetitions

import DBInterface
import DuckDB
import TOML
import Tables

include("m4benchmarks/M4Benchmarks.jl")
import .M4Benchmarks
include("monash.jl")
include("database.jl")

end
