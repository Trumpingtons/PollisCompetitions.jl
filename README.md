# PollisCompetitions.jl

The data of the M forecasting competitions, as their organisers gave them, for [Pollis](https://pollis.org): the series, split into the values the forecasters saw and those their forecasts were scored on, and, where they are published, the entries, their forecasts and their scores.

```julia
import PollisCompetitions as PC
PC.competitions()
PC.download("m4")
PC.download_forecasts("m4"; entries = ["118", "Theta"])
yearly = PC.series("m4"; frequency = "Yearly")
values = PC.observations("m4"; series = 1)
forecasts = PC.forecasts("m4"; entry = "118", frequency = "Yearly")
scores = PC.published_scores("m4"; measure = "OWA", breakdown = "frequency")
PC.tables("m5")
calendar = PC.table("m5", "calendar")
decisions = PC.table("m6", "submissions"; entry = 1, evaluation = 12)
```

Every function answers a table of columns (a NamedTuple of vectors, which Tables.jl reads).

## Competitions

| Id | Competition | Series | Frequencies | Entries | Source | Licence of the source | |
|---|---|---|---|---|---|---|---|
| `m1` | M1 (1982) | 1,001 | Yearly, Quarterly, Monthly | | Monash Time Series Forecasting Archive | CC BY 4.0 | Download |
| `m3` | M3 (2000) | 3,003 | Yearly, Quarterly, Monthly, Other | | Monash Time Series Forecasting Archive | CC BY 4.0 | Download |
| `m4` | M4 (2018) | 100,000 | Yearly, Quarterly, Monthly, Weekly, Daily, Hourly | 61 | Mcompetitions/M4-methods | None stated | Download |
| `m5` | M5 (2020) | 30,490 | Daily | 130 | The organisers' Google Drive and Mcompetitions/M5-methods | None stated | Download |
| `m6` | M6 (2022) | 100 assets | Daily | 251 teams | Mcompetitions/M6-methods | None stated | Download |

`data/catalogue.toml` describes each competition: its source, the revision of its repository, the licence, the papers (keys of PollisReferences), and each file with its address and SHA-256.

## Download

`download(id)` fetches the files of a competition from its source, checks each against the SHA-256 of the catalogue, and converts them on this computer into `~/.pollis/competitions/<id>`, a Parquet file for each table:

- `series`: series (a number), competition, name (as the source names it), frequency, period (the seasonal period), horizon, domain and start (as the source gives it);
- `observations`: series, t (from 1), value, and split, `train` for the values the forecasters saw and `test` for those their forecasts were scored on;
- `entries`: entry (a number), name, kind (submission, benchmark or standard), method, team, affiliation, rank, and forecasts (point, quantiles or rank probabilities);
- `published_scores`: entry, measure, breakdown, level and value, the scores the organisers published.

M4's entries come from `Submission Info.xlsx`, its scores (the sMAPE, MASE and OWA of each entry by frequency and by domain) from `Evaluation and Ranks.xlsx`.

M5 is that of the evaluation phase, its private leaderboard: 30,490 series of the unit sales of an item in a store, over 1,969 days, the last 28 to forecast. Its domain is the item's category. Its other tables are:

- `hierarchy`: series, item, department, category, store and state, the levels by which M5 adds its series up into 42,840;
- `calendar`: t, then the columns of `calendar.csv` (the date, the Walmart week `wm_yr_wk`, events and SNAP days);
- `prices`: series, wm_yr_wk and price, the sell prices of `sell_prices.csv`;
- `weights`: level (1 to 12), agg_level_1 and agg_level_2 (the names of a series at its level), dollar_sales and weight, from `weights_evaluation.csv`.

Its entries are the 24 benchmarks and the top 50 of M5 Accuracy, with point forecasts, and the 6 benchmarks and the top 50 of M5 Uncertainty, with quantile forecasts. Its scores come from `Scores and Ranks.xlsx`: the WRMSSE of Accuracy and the WSPL of Uncertainty by level (1 to 12, and Total), the WSPL and the coverage rate of Uncertainty by quantile.

M6 has no series to forecast but the monthly returns of 100 assets, of which each team gave the probabilities of ranking in each fifth, and in which it invested. Its tables are:

- `prices`: symbol, date and price, the adjusted close prices of `assets_m6.csv`;
- `entries`: the teams, by their id, with their names and their rank over the year (M6 Dummy, of equal probabilities and weights, is the benchmark);
- `submissions`: entry, submission and evaluation (the round of each, 0 for the trial run, then 1 to 12), symbol, decision (the weight invested), rank1 to rank5 (the probabilities of each fifth, from the lowest returns) and active (whether the team could win a prize), from `submissions.csv`; a submission is evaluated in every round until the team submits again;
- `published_scores`: the RPS, IR and OR of each team by month, quarter and over the year (Total), and of the trial run, from `summary_leaderboard.xlsx`.

`tables(id)` names the tables of a competition on this computer, and `table(id, name; filters...)` reads one, keeping the rows of the values given.

The files of the source are removed once converted. A file whose SHA-256 is not that of the catalogue stops the download: its source has changed.

`download_forecasts(id; entries)` adds the forecasts of the entries given, by number or by name, or of all of them when none are, in `forecasts/<entry>.parquet`, named by the entry's number: entry, series, h and value for point forecasts; entry, level, agg_level_1, agg_level_2, quantile, h and value for the quantile forecasts of M5, which are of its 42,840 series. Of M5, the forecasts of the evaluation phase are kept. M4's forecasts come as RAR archives, which bsdtar of libarchive (LibArchive_jll) reads; all of them take 460 MB to download. The forecasts of M5 take 2.1 GB to download for Accuracy, 16.5 GB for Uncertainty.

The tables are Parquet files, which Julia reads through DuckDB, filtered first: `query(sql)` runs any SQL on them.

## Scores

`scores(id; entries)` computes the scores of the entries whose forecasts are on this computer, as the organisers' code computes them, in the columns of `published_scores`. `score(id, forecasts)` scores a table of the user's own (series, h and value), each series forecast over its whole horizon. For M4: sMAPE and MASE, means over the series of each frequency, each domain and all of them, and OWA, which weighs them against those of Naive2 on the same series and needs its forecasts (`download_forecasts("m4"; entries = ["Naive2"])`). M1 and M3 are scored with the same measures, by frequency and in total, against Naive2 computed on this computer from the values the forecasters saw, since the package has no entries of theirs: `score` scores forecasts of your own, and `scores` has nothing to score. For M5, the WRMSSE of the point forecasts of M5 Accuracy: the forecasts of the 30,490 series are added up into the 42,840 series of its 12 levels, the RMSSE of each is scaled by the mean squared daily change of its training values from its first sale, and the WRMSSE of a level weighs them by `weights`; that of Total is the mean of the 12 levels. The quantile forecasts of M5 Uncertainty are not scored yet.

```julia
mine = PC.scores("m4"; entries = ["118", "Naive2"])
yearly = PC.forecasts("m4"; entry = "118", frequency = "Yearly")
PC.score("m4", (; series = yearly.series, h = yearly.h, value = yearly.value))
```

`benchmarks(id; methods, series)` computes on this computer the forecasts of M4's eight statistical benchmarks (Naive, sNaive, Naive2, SES, Holt, Damped, Theta and Com) from the values the forecasters saw, with [ForecastM4Benchmark.jl](https://github.com/Trumpingtons/ForecastM4Benchmark.jl), which computes them as the organisers did: method, series, h and value, so that `score` scores each method.

The scores of all 61 entries of M4 agree with `Evaluation and Ranks.xlsx`: sMAPE and MASE to the three decimals it gives. The sheet computes OWA from those rounded values, so that an OWA far above 1 can differ from the one computed here in the fourth significant digit (12.8399 for 12.8386).

In each series of the Monash archive, the values the forecasters saw come first, then the values of the horizon: so it is for the 23,000 series of M4 Yearly, which the archive and the files of M4's organisers give with the same values. The archive gives no domain.

`data/others.toml` holds competitions that are not M competitions, kept for a later group: the package does not read it.

## Licence

MIT, for the code. The data keep the terms of their source: the Monash archive puts CC BY 4.0 on its files; the organisers of M4, M5 and M6 state no licence.
