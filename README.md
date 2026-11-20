# PollisCompetitions.jl

Datasets on which models are scored and ranked, for [Pollis](https://pollis.org): the Dataset Catalog, the Model Catalog and the Benchmarks, the scores of each model on each dataset.

```julia
import PollisCompetitions as PC
datasets = PC.load_table("dataset_catalog")
comparisons = PC.load_table("model_comparisons")
data = PC.load_dataset("german_credit")
yearly = PC.series("m4"; frequency = "Yearly")
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
| `model_catalog` | model_id | model_name, estimator_family, estimator_method, package, language |
| `model_references` | model_id, bibtex_key | role |
| `benchmarks` | run_id, metric | model_id, dataset_id, split_protocol, score |

The estimator of a model has two levels: its estimator family, one of the model types of TabArena (Foundation Model, Tree-based, Neural Network, Baseline, Other), and its estimator method, one of the methods of its family; the header of `models.toml` lists both. The database checks each value against its vocabulary and each foreign key. The view `model_comparisons` joins each score to its model and dataset. `load_table(name)` reads one of the five tables or the view.

## Built-in datasets

A dataset whose delivery is Built-in ships with the package, as a folder named by its `dataset_id` in `data/builtin/`, with its data in `data.parquet`. `connect_db` reads each in place, as the view `builtin."<dataset_id>"`, and `load_dataset(dataset_id)` reads one. A dataset whose delivery is Download is fetched by the user from its `source_url`.

## Data and scores

The data of a forecasting dataset are a folder of Parquet files: in `data/builtin/<dataset_id>` when it is built in, else in `~/.pollis/competitions/<dataset_id>`, with an `info.toml` that says what is there. A dataset of your own is any folder holding `series.parquet` and `observations.parquet`: every function below takes its absolute path in place of an id.

- `series(id)`: series (a number), competition, name, frequency, period (the seasonal period), horizon, domain and start;
- `observations(id)`: series, t (from 1), value, and split, `train` for the values the forecasters saw and `test` for those their forecasts were scored on;
- `entries(id)`, `forecasts(id; entry)` and `published_scores(id)`: the entries of a competition, their forecasts and the scores the organisers published, where they are on this computer;
- `tables(id)` names the tables of a dataset, and `table(id, name; filters...)` reads one; `query(sql)` runs any SQL on them.

`score(id, forecasts)` scores forecasts of your own (series, h and value), each series forecast over its whole horizon, and `scores(id; entries)` scores the published entries: sMAPE, MASE and OWA against Naive2 for M1, M3, M4, Tourism and datasets of your own; the WRMSSE of the point forecasts of M5; the RPS and IR of M6. `step_errors(id, forecasts)` gives the errors at each step ahead, series by series. `benchmarks(id; methods, series)` computes M4's eight statistical benchmarks from the values the forecasters saw.

```julia
mine = PC.score("m4", (; series = [1, 1], h = [1, 2], value = [7300.0, 7350.0]))
theirs = PC.scores("m4"; entries = ["118", "Naive2"])
```

## Other code

- `read_tsf(path)` reads a file of the Monash Time Series Forecasting Archive (.tsf).
- The submodule `M4Benchmarks` computes the eight statistical benchmarks of the M4 forecasting competition (Naive, sNaive, Naive2, SES, Holt, Damped, Theta and Com), as its organisers computed them in `Benchmarks and Evaluation.R` (Mcompetitions/M4-methods), with simple exponential smoothing and Holt's method fitted as R's forecast 8.2 fits them. `M4Benchmarks.benchmarks(y; period, horizon)` gives the eight for one series, and `is_seasonal`, `seasonal_index`, `ses`, `holt` and `theta` each part. On the series of M4 they give the published forecasts of the benchmarks.

## Licence

MIT, for the code. The data keep the terms of their source, which `licence` gives for each dataset.
