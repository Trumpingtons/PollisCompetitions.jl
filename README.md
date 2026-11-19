# PollisCompetitions.jl

Datasets on which models are scored and ranked, for [Pollis](https://pollis.org): the Dataset Catalog, the Model Catalog and the Benchmarks, the scores of each model on each dataset.

```julia
import PollisCompetitions as PC
datasets = PC.load_table("dataset_catalog")
comparisons = PC.load_table("model_comparisons")
data = PC.load_dataset("nab")
```

Every function answers a table of columns (a NamedTuple of vectors, which Tables.jl reads).

## Metadata

The metadata are TOML files in `metadata/`:

- `datasets.toml`: one `[[datasets]]` table for each dataset, with its `[[datasets.references]]`;
- `models.toml`: one `[[models]]` table for each model, with its `[[models.references]]`;
- `benchmarks.toml`: one `[[runs]]` table for each run of a model on a dataset, with its `[runs.scores]`.

The header of each file describes its fields. A field left out is unknown, and loads as NULL (`missing` in Julia). A reference is a key of [PollisReferences](https://github.com/Trumpingtons/PollisReferences.jl), from which its DOI and address come; the tests check that every key is there.

`connect_db(path = ":memory:")` loads the metadata into a DuckDB database of five tables:

| Table | Key | Columns |
|---|---|---|
| `dataset_catalog` | dataset_id | dataset_name, competition_name, competition_year, topic, data_structure, geometry, response_type, rows, features, size_mb, licence, delivery, source_url |
| `dataset_references` | dataset_id, bibtex_key | role |
| `model_catalog` | model_id | model_name, estimator_method, package, language |
| `model_references` | model_id, bibtex_key | role |
| `benchmarks` | run_id, metric | model_id, dataset_id, split_protocol, score |

The database checks each value against its vocabulary and each foreign key. The view `model_comparisons` joins each score to its model and dataset. `load_table(name)` reads one of the five tables or the view.

## Built-in datasets

A dataset whose delivery is Built-in ships with the package, as a Parquet file named by its `dataset_id` in `data/builtin/`. `connect_db` reads each in place, as the view `builtin."<dataset_id>"`, and `load_dataset(dataset_id)` reads one. A dataset whose delivery is Download is fetched by the user from its `source_url`.

## Other code

- `read_tsf(path)` reads a file of the Monash Time Series Forecasting Archive (.tsf).
- The submodule `M4Benchmarks` computes the eight statistical benchmarks of the M4 forecasting competition (Naive, sNaive, Naive2, SES, Holt, Damped, Theta and Com), as its organisers computed them in `Benchmarks and Evaluation.R` (Mcompetitions/M4-methods), with simple exponential smoothing and Holt's method fitted as R's forecast 8.2 fits them. `M4Benchmarks.benchmarks(y; period, horizon)` gives the eight for one series, and `is_seasonal`, `seasonal_index`, `ses`, `holt` and `theta` each part. On the series of M4 they give the published forecasts of the benchmarks.

## Licence

MIT, for the code. The data keep the terms of their source, which `licence` gives for each dataset.
