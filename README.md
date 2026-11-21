# PollisCompetitions.jl

Datasets on which models are scored and ranked, for [Pollis](https://pollis.org): the Dataset Catalog, the Model Catalog and the Benchmarks, the scores of each model on each dataset.

```julia
import PollisCompetitions as PC
datasets = PC.load_table("dataset_catalog")
comparisons = PC.load_table("model_comparisons")
data = PC.load_dataset("german_credit")
monthly = PC.series("tourism_2011"; frequency = "Monthly")
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

The estimator of a model has two levels: its estimator family, one of the model types of TabArena (Foundation Model, Tree-based, Neural Network, Baseline, Other), Statistical, for the classical methods of forecasting and of survival analysis, Kernel Methods, Fuzzy System, or Hybrid, for a model that combines methods of different kinds, and its estimator method, one of the methods of its family (that of a Hybrid model names the methods it combines); the header of `models.toml` lists both. The database checks each value against its vocabulary and each foreign key. The view `model_comparisons` joins each score to its model and dataset. `load_table(name)` reads one of the five tables or the view.

## Built-in datasets

A dataset whose delivery is Built-in ships with the package, as a folder named by its `dataset_id` in `data/builtin/`, with its data in Parquet files: `data.parquet` and `splits.parquet` for a tabular dataset, `series.parquet` and `observations.parquet` for a forecasting one. `connect_db` reads each in place, as a schema named by its `dataset_id` with a view of each file, named by the file (`heloc.data`, `nn5.observations`), and `load_dataset(dataset_id)` reads the `data.parquet` of a tabular one. A dataset whose delivery is Download is fetched by the user from its `source_url`, and its reader writes it to `~/.pollis/competitions/<dataset_id>`, where `connect_db` reads it the same way once its `info.toml` is there.

## Data and scores

The data of a forecasting dataset are a folder of Parquet files: in `data/builtin/<dataset_id>` when it is built in, else in `~/.pollis/competitions/<dataset_id>`, with an `info.toml` that says what is there. A dataset of your own is any folder holding `series.parquet` and `observations.parquet`: every function below takes its absolute path in place of an id.

- `series(id)`: series (a number), competition, name, frequency, period (the seasonal period), horizon, domain and start;
- `observations(id)`: series, t (from 1), value, and split, `train` for the values the forecasters saw and `test` for those their forecasts were scored on;
- `tables(id)` names the tables of a dataset, and `table(id, name; filters...)` reads one; `query(sql)` runs any SQL on them.

`score(id, forecasts)` scores forecasts of your own (series, h and value) of any forecasting dataset, each series forecast over its whole horizon: sMAPE, MASE and OWA against Naive2, computed on this computer, by frequency, by domain when the dataset gives domains, and in total. `step_errors(id, forecasts)` gives the errors at each step ahead, series by series. `benchmarks(id; methods, series)` computes the eight statistical benchmarks of `Benchmarks` from the values the forecasters saw.

```julia
theta = PC.benchmarks("nn3"; methods = ["Theta"])
PC.score("nn3", theta)
```

A tabular dataset's `info.toml` names its `target` (its time, for survival), its `event` (for survival), and the `repeats` and `folds` of its outer splits; a survival dataset's `[factors]` gives the columns read as factors, each with its levels in order. `outer_splits(id)` gives each split: its repeat, its fold, its training rows and its test rows. Its Response Type in the Dataset Catalog decides how predictions are scored, as its benchmark scores them, by the measures of [ModelZoo.jl](https://github.com/Trumpingtons/ModelZoo.jl), which this package makes available under the same names:

- Continuous and Count by `rmse`, Binary by `roc_auc` (the probability of the second of its classes, sorted), Multiclass by `log_loss` (`TABULAR_MEASURES`), with `tabular_scores(response_type, truth, prediction)`;
- Survival by the eight measures of the Low-Dimensional Survival Benchmark (`SURVIVAL_MEASURES`), with `survival_scores(train_time, train_event, test_time, test_event, times, survival)`, where `survival` holds each test row's probability of surviving past each of `times`.

`published_scores(ids)` gives the published runs on those datasets, and `measure_loss(measure, value)` turns a score into a number of which lower is better, to rank by.

## Other code

- `read_tsf(path)` reads a file of the Monash Time Series Forecasting Archive (.tsf).
- The submodule `Benchmarks` computes eight statistical benchmarks of forecasting (Naive, sNaive, Naive2, SES, Holt, Damped, Theta and Com): a series that passes a seasonality test is adjusted by its classical multiplicative seasonal index, and simple exponential smoothing and Holt's method are fitted as R's forecast 8.2 fits them. `Benchmarks.benchmarks(y; period, horizon)` gives the eight for one series, and `is_seasonal`, `seasonal_index`, `ses`, `holt` and `theta` each part.

## Licence

MIT, for the code. The data keep the terms of their source, which `licence` gives for each dataset.
